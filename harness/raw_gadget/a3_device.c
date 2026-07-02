// SPDX-License-Identifier: GPL-2.0
//
// A3 -- Adversarial USB device over /dev/raw-gadget.
//
// Emulates a deliberately hostile device bound to the dummy_udc software UDC
// (dummy_hcd must be loaded). A fault mode selected on the command line makes
// enumeration go wrong in one specific, observable way. Every fault is visible
// on the host side purely through standard enumeration (reading descriptors via
// usbfs / lsusb / sysfs), so A3 needs nothing from Part B.
//
// Usage: a3_device <fault> [udc_driver] [udc_device]
//   fault defaults to $FAULT or "none".
//   udc_driver/udc_device default to dummy_udc / dummy_udc.0.
//   $RUN_SECONDS (default 8) bounds the lifetime so the harness never hangs.
//   $SLOW_MS (default 400) is the delay used by the "slow" fault.
//
// Fault catalog (maps to PROJECT.md A3):
//   none               fully functional reference device
//   bad-device-blength device descriptor with a wrong bLength
//   short-device       device descriptor returned as a short packet (8 bytes)
//   config-truncated   config descriptor sent shorter than its wTotalLength
//   config-oversized   config wTotalLength claims far more than exists
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

struct full_config {
	struct usb_config_descriptor config;
	struct usb_interface_descriptor intf;
	struct usb_endpoint_descriptor ep_in;
	struct usb_endpoint_descriptor ep_out;
} __attribute__((packed));

static struct full_config cfg = {
	.config = {
		.bLength = USB_DT_CONFIG_SIZE,
		.bDescriptorType = USB_DT_CONFIG,
		.wTotalLength = sizeof(struct full_config),
		.bNumInterfaces = 1,
		.bConfigurationValue = 1,
		.iConfiguration = 0,
		.bmAttributes = USB_CONFIG_ATT_ONE,
		.bMaxPower = 60, // 120 mA
	},
	.intf = {
		.bLength = USB_DT_INTERFACE_SIZE,
		.bDescriptorType = USB_DT_INTERFACE,
		.bInterfaceNumber = 0,
		.bNumEndpoints = 2,
		.bInterfaceClass = 0xff, // vendor specific
		.bInterfaceSubClass = 0,
		.bInterfaceProtocol = 0,
		.iInterface = 0,
	},
	.ep_in = {
		.bLength = USB_DT_ENDPOINT_SIZE,
		.bDescriptorType = USB_DT_ENDPOINT,
		.bEndpointAddress = 0x81,
		.bmAttributes = USB_ENDPOINT_XFER_BULK,
		.wMaxPacketSize = 512,
		.bInterval = 0,
	},
	.ep_out = {
		.bLength = USB_DT_ENDPOINT_SIZE,
		.bDescriptorType = USB_DT_ENDPOINT,
		.bEndpointAddress = 0x01,
		.bmAttributes = USB_ENDPOINT_XFER_BULK,
		.wMaxPacketSize = 512,
		.bInterval = 0,
	},
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
	int rv = ioctl(fd, USB_RAW_IOCTL_EP0_WRITE, io);
	if (rv < 0) a3log("EP0_WRITE(%u) failed: %s", len, strerror(errno));
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
		struct full_config c = cfg;
		int len = sizeof(c);
		if (fault_is("config-oversized")) {
			c.config.wTotalLength = 0xffff; // claims far more than exists
			a3log("config-oversized: wTotalLength=0xffff");
		}
		if (fault_is("config-truncated")) {
			// wTotalLength stays honest but we send fewer bytes than
			// the host asked for -> truncated descriptor set.
			if (wlen > (int)sizeof(c)) wlen = sizeof(c);
			len = (int)sizeof(struct usb_config_descriptor) + 2;
			a3log("config-truncated: sending %d of %zu bytes", len, sizeof(c));
		}
		if (len > wlen) len = wlen;
		ep0_write(fd, &c, len);
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
		ep0_write(fd, NULL, 0);
		break;
	case USB_REQ_SET_INTERFACE:
		ep0_write(fd, NULL, 0);
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

	g_fd = raw_init(driver, device, USB_SPEED_HIGH);
	if (g_fd < 0) return 1;
	a3log("raw-gadget bound and running");

	event_loop(g_fd);

	if (g_fd >= 0) close(g_fd);
	return 0;
}
