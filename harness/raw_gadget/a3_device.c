// SPDX-License-Identifier: GPL-2.0
//
// A3 -- Adversarial USB device over /dev/raw-gadget.
//
// Emulates a deliberately hostile device bound to the dummy_udc software UDC
// (dummy_hcd must be loaded). A fault mode selected on the command line makes
// enumeration go wrong in one specific, observable way. Every fault is visible
// on the host side purely through standard enumeration (reading descriptors via
// usbfs / lsusb / sysfs), so it needs nothing from the library.
//
// Usage: a3_device <fault> [udc_driver] [udc_device]
//   fault defaults to $FAULT or "none".
//   udc_driver/udc_device default to dummy_udc / dummy_udc.0.
//   $RUN_SECONDS (default 8) bounds the lifetime so the harness never hangs.
//   $SLOW_MS (default 400) is the delay used by the "slow" fault.
//
// Fault catalog:
//   none               fully functional reference device
//   bad-device-blength device descriptor with an over-large bLength (Linux
//                      ignores it and enumerates; the library rejects it)
//   short-device       device descriptor returned as a short packet (8 bytes)
//   config-truncated   config descriptor sent shorter than its wTotalLength
//   config-oversized   config wTotalLength claims far more than exists
//   overflow           returns more bytes than wLength (wrong wLength / babble)
//   stall-config       STALL the GET_DESCRIPTOR(config) request
//   stall-string       STALL string descriptor requests
//   nak-forever        never answer GET_DESCRIPTOR(device); host times out
//   slow               delay every descriptor response by SLOW_MS
//   disconnect-mid     disconnect (close UDC) mid-enumeration

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/ioctl.h>

#include <linux/usb/ch9.h>
#include <linux/usb/raw_gadget.h>

#define EP0_MAX 64

static int g_fd = -1;
static const char *g_fault = "none";

static void a3log(const char *fmt, ...) {
	va_list ap;
	va_start(ap, fmt);
	fprintf(stderr, "[a3] ");
	vfprintf(stderr, fmt, ap);
	fprintf(stderr, "\n");
	va_end(ap);
	fflush(stderr);
}

static void on_alarm(int sig) {
	(void)sig;
	a3log("run time elapsed, exiting");
	if (g_fd >= 0)
		close(g_fd);
	_exit(0);
}

// ---- ep0 I/O watchdog ------------------------------------------------------
//
// The host may abandon an in-flight control transfer (URB unlink on timeout or
// cancel). raw-gadget then blocks the pending EP0_WRITE/EP0_READ indefinitely,
// which would wedge ep0 and fail every later request on the device. A watchdog
// SIGUSR1 EINTRs the stuck ioctl (raw-gadget dequeues the ep0 request when the
// wait is interrupted), so the device abandons the dead exchange and returns to
// the event loop -- like real silicon, where a new SETUP supersedes any stale
// transaction. Legitimate ep0 I/O completes in microseconds and never sees it.

#define EP0_IO_TIMEOUT_MS 500

static timer_t ep0_watchdog;

static void on_ep0_watchdog(int sig) { (void)sig; } // exists only to EINTR the ioctl

static void ep0_watchdog_init(void) {
	struct sigaction sa;
	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = on_ep0_watchdog; // deliberately no SA_RESTART
	sigaction(SIGUSR1, &sa, NULL);

	struct sigevent sev;
	memset(&sev, 0, sizeof(sev));
	sev.sigev_notify = SIGEV_SIGNAL;
	sev.sigev_signo = SIGUSR1;
	if (timer_create(CLOCK_MONOTONIC, &sev, &ep0_watchdog) < 0) {
		perror("timer_create");
		exit(1);
	}
}

static void ep0_watchdog_arm(void) {
	struct itimerspec its;
	memset(&its, 0, sizeof(its));
	its.it_value.tv_sec = EP0_IO_TIMEOUT_MS / 1000;
	its.it_value.tv_nsec = (long)(EP0_IO_TIMEOUT_MS % 1000) * 1000000L;
	timer_settime(ep0_watchdog, 0, &its, NULL);
}

static void ep0_watchdog_disarm(void) {
	struct itimerspec zero;
	memset(&zero, 0, sizeof(zero));
	timer_settime(ep0_watchdog, 0, &zero, NULL);
}

// ---- descriptor templates ------------------------------------------------

static struct usb_device_descriptor dev_desc = {
	.bLength = USB_DT_DEVICE_SIZE,
	.bDescriptorType = USB_DT_DEVICE,
	.bcdUSB = 0x0200,
	.bDeviceClass = 0,
	.bDeviceSubClass = 0,
	.bDeviceProtocol = 0,
	.bMaxPacketSize0 = EP0_MAX,
	.idVendor = 0xdead,
	.idProduct = 0xbeef,
	.bcdDevice = 0x0001,
	.iManufacturer = 1,
	.iProduct = 2,
	.iSerialNumber = 3,
	.bNumConfigurations = 1,
};

// Configuration descriptor set, laid out byte-exact (32 bytes). We deliberately
// do NOT build this from struct usb_endpoint_descriptor: that struct is 9 bytes
// in the kernel headers (it carries the audio-only bRefresh/bSynchAddress
// fields), so sizeof() would append two stray zero bytes after each 7-byte
// endpoint. The kernel tolerates the padding, but a strict host parser reads
// those zeros as a bLength==0 (zero-length) descriptor -- so a `none` device
// would spuriously fail a real client. Keep the wire exactly wTotalLength bytes.
#define CFG_TOTAL 32
static const unsigned char cfg_bytes[CFG_TOTAL] = {
	// configuration (9): 1 interface, 120 mA, self/bus per USB_CONFIG_ATT_ONE
	9, USB_DT_CONFIG, CFG_TOTAL, 0x00, 1, 1, 0, USB_CONFIG_ATT_ONE, 60,
	// interface 0 (9): vendor-specific class, 2 bulk endpoints
	9, USB_DT_INTERFACE, 0, 0, 2, 0xff, 0, 0, 0,
	// endpoint IN 0x81 (7): bulk, 512-byte max packet (0x0200 LE)
	7, USB_DT_ENDPOINT, 0x81, USB_ENDPOINT_XFER_BULK, 0x00, 0x02, 0,
	// endpoint OUT 0x01 (7): bulk, 512-byte max packet (0x0200 LE)
	7, USB_DT_ENDPOINT, 0x01, USB_ENDPOINT_XFER_BULK, 0x00, 0x02, 0,
};

// A minimal string descriptor set: index 0 (lang), 1/2/3 text.
static int build_string(int index, unsigned char *buf) {
	if (index == 0) {
		buf[0] = 4; buf[1] = USB_DT_STRING;
		buf[2] = 0x09; buf[3] = 0x04; // en-US
		return 4;
	}
	const char *s = "circuits-usb-a3";
	if (index == 2) s = "Adversarial Device";
	if (index == 3) s = "A3-SERIAL";
	int n = (int)strlen(s);
	int len = 2 + n * 2;
	buf[0] = len; buf[1] = USB_DT_STRING;
	for (int i = 0; i < n; i++) { buf[2 + i*2] = (unsigned char)s[i]; buf[3 + i*2] = 0; }
	return len;
}

// ---- raw-gadget helpers --------------------------------------------------

static int raw_init(const char *driver, const char *device, __u8 speed) {
	int fd = open("/dev/raw-gadget", O_RDWR);
	if (fd < 0) { perror("open /dev/raw-gadget"); return -1; }
	struct usb_raw_init arg;
	memset(&arg, 0, sizeof(arg));
	arg.speed = speed;
	strncpy((char *)arg.driver_name, driver, sizeof(arg.driver_name) - 1);
	strncpy((char *)arg.device_name, device, sizeof(arg.device_name) - 1);
	if (ioctl(fd, USB_RAW_IOCTL_INIT, &arg) < 0) {
		perror("USB_RAW_IOCTL_INIT"); close(fd); return -1;
	}
	if (ioctl(fd, USB_RAW_IOCTL_RUN, 0) < 0) {
		perror("USB_RAW_IOCTL_RUN"); close(fd); return -1;
	}
	return fd;
}

static int ep0_write(int fd, const void *data, __u32 len) {
	unsigned char buf[sizeof(struct usb_raw_ep_io) + EP0_MAX * 8];
	struct usb_raw_ep_io *io = (struct usb_raw_ep_io *)buf;
	if (len > EP0_MAX * 8) len = EP0_MAX * 8;
	io->ep = 0; io->flags = 0; io->length = len;
	if (len) memcpy(io->data, data, len);
	ep0_watchdog_arm();
	int rv = ioctl(fd, USB_RAW_IOCTL_EP0_WRITE, io);
	int e = errno;
	ep0_watchdog_disarm();
	if (rv < 0 && e == EINTR)
		a3log("EP0_WRITE(%u) abandoned: host cancelled the request", len);
	else if (rv < 0)
		a3log("EP0_WRITE(%u) failed: %s", len, strerror(e));
	return rv;
}

// Complete a no-data OUT control request (SET_CONFIGURATION, SET_INTERFACE).
// raw-gadget classifies the whole request by bmRequestType direction: an OUT
// request leaves ep0_out_pending set, so the ack is an EP0_READ of length 0 (the
// UDC core drives the IN status ZLP). Using EP0_WRITE here returns EBUSY and
// wedges ep0, breaking every later control transfer on the device.
static int ep0_ack_out(int fd) {
	struct usb_raw_ep_io io;
	io.ep = 0; io.flags = 0; io.length = 0;
	ep0_watchdog_arm();
	int rv = ioctl(fd, USB_RAW_IOCTL_EP0_READ, &io);
	int e = errno;
	ep0_watchdog_disarm();
	if (rv < 0 && e == EINTR)
		a3log("EP0_READ(0) ack abandoned: host cancelled the request");
	else if (rv < 0)
		a3log("EP0_READ(0) ack failed: %s", strerror(e));
	return rv;
}

static void ep0_stall(int fd) {
	if (ioctl(fd, USB_RAW_IOCTL_EP0_STALL, 0) < 0)
		a3log("EP0_STALL failed: %s", strerror(errno));
}

static void maybe_slow(void) {
	if (strcmp(g_fault, "slow") == 0) {
		const char *ms = getenv("SLOW_MS");
		int delay = ms ? atoi(ms) : 400;
		a3log("slow fault: sleeping %d ms", delay);
		usleep((useconds_t)delay * 1000);
	}
}

// ---- control request dispatch --------------------------------------------

static int fault_is(const char *f) { return strcmp(g_fault, f) == 0; }

static void handle_get_descriptor(int fd, struct usb_ctrlrequest *ctrl) {
	int type = ctrl->wValue >> 8;
	int index = ctrl->wValue & 0xff;
	int wlen = ctrl->wLength;
	unsigned char sbuf[256];

	maybe_slow();

	switch (type) {
	case USB_DT_DEVICE: {
		if (fault_is("nak-forever")) {
			a3log("nak-forever: ignoring GET_DESCRIPTOR(device)");
			return; // never answer -> host times out (NAK)
		}
		if (fault_is("disconnect-mid")) {
			a3log("disconnect-mid: closing UDC during enumeration");
			close(fd); g_fd = -1; _exit(0);
		}
		struct usb_device_descriptor d = dev_desc;
		if (fault_is("bad-device-blength")) {
			d.bLength = 0x40; // wrong: must be 18
			a3log("bad-device-blength: bLength=0x40");
		}
		int len = sizeof(d);
		if (fault_is("short-device")) {
			len = 8; // short packet: fewer bytes than the 18 requested
			a3log("short-device: returning only 8 bytes");
		}
		if (len > wlen) len = wlen;
		ep0_write(fd, &d, len);
		break;
	}
	case USB_DT_CONFIG: {
		if (fault_is("stall-config")) {
			a3log("stall-config: stalling GET_DESCRIPTOR(config)");
			ep0_stall(fd);
			break;
		}
		unsigned char c[CFG_TOTAL];
		memcpy(c, cfg_bytes, CFG_TOTAL);
		int len = CFG_TOTAL;
		int cap_to_wlen = 1;
		if (fault_is("config-oversized")) {
			c[2] = 0xff; c[3] = 0xff; // wTotalLength claims far more than exists
			a3log("config-oversized: wTotalLength=0xffff");
		}
		if (fault_is("config-truncated")) {
			// wTotalLength stays honest but we send fewer bytes than
			// the host asked for -> truncated descriptor set.
			if (wlen > CFG_TOTAL) wlen = CFG_TOTAL;
			len = USB_DT_CONFIG_SIZE + 2;
			a3log("config-truncated: sending %d of %d bytes", len, CFG_TOTAL);
		}
		if (fault_is("overflow")) {
			// Wrong wLength: send the whole config even when the host asked
			// for only the 9-byte header -> more data than requested (babble
			// / EOVERFLOW on the host).
			cap_to_wlen = 0;
			a3log("overflow: sending %d bytes for a %d-byte request", len, wlen);
		}
		if (cap_to_wlen && len > wlen) len = wlen;
		ep0_write(fd, c, len);
		break;
	}
	case USB_DT_STRING: {
		if (fault_is("stall-string")) {
			a3log("stall-string: stalling string descriptor %d", index);
			ep0_stall(fd);
			break;
		}
		int len = build_string(index, sbuf);
		if (len > wlen) len = wlen;
		ep0_write(fd, sbuf, len);
		break;
	}
	default:
		a3log("unsupported descriptor type %d -> stall", type);
		ep0_stall(fd);
		break;
	}
}

static void handle_control(int fd, struct usb_ctrlrequest *ctrl) {
	a3log("ctrl: bmRequestType=0x%02x bRequest=0x%02x wValue=0x%04x wIndex=0x%04x wLength=%u",
	     ctrl->bRequestType, ctrl->bRequest, ctrl->wValue, ctrl->wIndex, ctrl->wLength);

	if ((ctrl->bRequestType & USB_TYPE_MASK) != USB_TYPE_STANDARD) {
		ep0_stall(fd);
		return;
	}

	switch (ctrl->bRequest) {
	case USB_REQ_GET_DESCRIPTOR:
		handle_get_descriptor(fd, ctrl);
		break;
	case USB_REQ_SET_CONFIGURATION:
		// Move the UDC to configured state (best effort), then ack.
		ioctl(fd, USB_RAW_IOCTL_VBUS_DRAW, 60);
		ioctl(fd, USB_RAW_IOCTL_CONFIGURE, 0);
		a3log("set configuration %u", ctrl->wValue);
		ep0_ack_out(fd);
		break;
	case USB_REQ_SET_INTERFACE:
		ep0_ack_out(fd);
		break;
	case USB_REQ_GET_STATUS: {
		unsigned char status[2] = {0, 0};
		ep0_write(fd, status, 2);
		break;
	}
	default:
		a3log("unhandled standard request 0x%02x -> stall", ctrl->bRequest);
		ep0_stall(fd);
		break;
	}
}

// ---- event loop ----------------------------------------------------------

static void event_loop(int fd) {
	unsigned char ebuf[sizeof(struct usb_raw_event) + sizeof(struct usb_ctrlrequest)];
	struct usb_raw_event *event = (struct usb_raw_event *)ebuf;

	for (;;) {
		event->type = 0;
		event->length = sizeof(struct usb_ctrlrequest);
		if (ioctl(fd, USB_RAW_IOCTL_EVENT_FETCH, event) < 0) {
			if (errno == EINTR) continue;
			a3log("EVENT_FETCH failed: %s", strerror(errno));
			return;
		}
		switch (event->type) {
		case USB_RAW_EVENT_CONNECT:
			a3log("event: CONNECT");
			break;
		case USB_RAW_EVENT_CONTROL:
			handle_control(fd, (struct usb_ctrlrequest *)event->data);
			break;
		case USB_RAW_EVENT_RESET:
			a3log("event: RESET");
			break;
		case USB_RAW_EVENT_SUSPEND:
			a3log("event: SUSPEND");
			break;
		case USB_RAW_EVENT_RESUME:
			a3log("event: RESUME");
			break;
		case USB_RAW_EVENT_DISCONNECT:
			a3log("event: DISCONNECT");
			return;
		default:
			a3log("event: unknown type %u", event->type);
			break;
		}
	}
}

int main(int argc, char **argv) {
	const char *driver = "dummy_udc";
	const char *device = "dummy_udc.0";

	g_fault = getenv("FAULT");
	if (!g_fault) g_fault = "none";
	if (argc > 1) g_fault = argv[1];
	if (argc > 2) driver = argv[2];
	if (argc > 3) device = argv[3];

	int run_secs = getenv("RUN_SECONDS") ? atoi(getenv("RUN_SECONDS")) : 8;

	a3log("starting: fault=%s udc=%s/%s run=%ds", g_fault, driver, device, run_secs);

	signal(SIGALRM, on_alarm);
	alarm((unsigned)run_secs);
	ep0_watchdog_init();

	g_fd = raw_init(driver, device, USB_SPEED_HIGH);
	if (g_fd < 0) return 1;
	a3log("raw-gadget bound and running");

	event_loop(g_fd);

	if (g_fd >= 0) close(g_fd);
	return 0;
}
