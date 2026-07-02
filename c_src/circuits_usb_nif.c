// SPDX-License-Identifier: Apache-2.0
//
// circuits_usb syscall shim NIF (Part B1).
//
// A deliberately narrow shim over a single file descriptor: open, close, read,
// write. The fd lives in an ErlNifResource whose destructor closes it, so a
// dropped/GC'd handle never leaks an fd. errno is captured immediately after
// each syscall and mapped to an atom. No transfers/ioctls yet -- those arrive in
// B2 and will carry usbfs request codes as 64-bit unsigned values (helpers for
// that live here already).
//
// Linux only. usbfs descriptor reads are fast and non-blocking, so B1 runs
// inline on a normal scheduler; blocking transfer paths (B4+) move to dirty
// schedulers / enif_select and must not hold fd_lock across a blocking call.

#define _GNU_SOURCE // O_CLOEXEC and friends under -std=c11

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <unistd.h>

#include <linux/netlink.h>
#include <linux/usbdevice_fs.h>

#include <erl_nif.h>

// ---- resource type -------------------------------------------------------

// An in-flight async URB. `kurb` is the LAST member so an isochronous URB's
// trailing iso_frame_desc[] array can be over-allocated right after it. We
// recover the Urb from a reaped `struct usbdevfs_urb *` via kurb.usercontext
// (set to the owning Urb at submit). The kurb and its buffer must stay put until
// the URB is reaped or the fd is closed, so they live in enif_alloc memory
// tracked on the owning fd.
typedef struct Urb {
    unsigned char *buffer;
    size_t buffer_len;
    int is_in;
    int num_packets; // 0 for bulk/interrupt; >0 for isochronous
    ErlNifUInt64 tag; // caller correlation id
    struct Urb *next;
    struct Urb *prev;
    struct usbdevfs_urb kurb;
} Urb;

typedef struct {
    int fd;             // -1 once closed
    ErlNifMutex *lock;  // serializes fd use vs close (no double-close/UAF)
    Urb *inflight;      // doubly-linked list of submitted-but-unreaped URBs
    int select_active;  // enif_select(WRITE) currently armed
    int closing;        // close requested; fd torn down in the stop callback
} UsbFd;

static ErlNifResourceType *usb_fd_type = NULL;

// Atoms, initialized in load().
static ERL_NIF_TERM am_ok;
static ERL_NIF_TERM am_error;
static ERL_NIF_TERM am_ebadf;

// ---- URB registry helpers (call with r->lock held) ---------------------

static void urb_link(UsbFd *r, Urb *u) {
    u->prev = NULL;
    u->next = r->inflight;
    if (r->inflight)
        r->inflight->prev = u;
    r->inflight = u;
}

static void urb_unlink(UsbFd *r, Urb *u) {
    if (u->prev)
        u->prev->next = u->next;
    else
        r->inflight = u->next;
    if (u->next)
        u->next->prev = u->prev;
}

static void urb_free(Urb *u) {
    if (u->buffer)
        enif_free(u->buffer);
    enif_free(u);
}

// Close the fd and drop all tracked URBs. Closing the usbfs fd cancels every
// kernel URB, so the kernel no longer references our Urb memory afterward and it
// is safe to free. Call with r->lock held.
static void teardown_fd(UsbFd *r) {
    if (r->fd >= 0) {
        close(r->fd);
        r->fd = -1;
    }
    Urb *u = r->inflight;
    while (u) {
        Urb *n = u->next;
        urb_free(u);
        u = n;
    }
    r->inflight = NULL;
}

static ERL_NIF_TERM mk_atom(ErlNifEnv *env, const char *s) {
    ERL_NIF_TERM a;
    if (enif_make_existing_atom(env, s, &a, ERL_NIF_LATIN1))
        return a;
    return enif_make_atom(env, s);
}

// Map errno -> atom. Common cases get a name; anything else becomes :eNNN so the
// caller always receives an atom and never loses information.
static ERL_NIF_TERM errno_atom(ErlNifEnv *env, int e) {
    const char *name = NULL;
    switch (e) {
    case EPERM:      name = "eperm"; break;
    case ENOENT:     name = "enoent"; break;
    case EINTR:      name = "eintr"; break;
    case EIO:        name = "eio"; break;
    case ENXIO:      name = "enxio"; break;
    case EBADF:      name = "ebadf"; break;
    case EAGAIN:     name = "eagain"; break;
    case ENOMEM:     name = "enomem"; break;
    case EACCES:     name = "eacces"; break;
    case EFAULT:     name = "efault"; break;
    case EBUSY:      name = "ebusy"; break;
    case ENODEV:     name = "enodev"; break;
    case EINVAL:     name = "einval"; break;
    case ENOTTY:     name = "enotty"; break;
    case EPIPE:      name = "epipe"; break;
    case ENOSPC:     name = "enospc"; break;
    case EOVERFLOW:  name = "eoverflow"; break;
    case ETIMEDOUT:  name = "etimedout"; break;
    case ECONNRESET: name = "econnreset"; break;
    case ESHUTDOWN:  name = "eshutdown"; break;
    case EPROTO:     name = "eproto"; break;
    case EILSEQ:     name = "eilseq"; break;
    case ENODATA:    name = "enodata"; break;   // GETDRIVER: no driver bound
    case ETIME:      name = "etime"; break;      // USB isoc/interrupt timeout
    case EREMOTEIO:  name = "eremoteio"; break;  // USB short read
    case ENOSYS:     name = "enosys"; break;
    case EMFILE:     name = "emfile"; break;
    case ENFILE:     name = "enfile"; break;
    default: break;
    }
    if (name)
        return mk_atom(env, name);
    char buf[16];
    snprintf(buf, sizeof(buf), "e%d", e);
    return enif_make_atom(env, buf);
}

static ERL_NIF_TERM err_tuple(ErlNifEnv *env, int e) {
    return enif_make_tuple2(env, am_error, errno_atom(env, e));
}

// enif_select stop callback: runs when it is safe to close the fd (no in-flight
// select). This is where an fd that was ever selected upon is actually closed.
static void usb_fd_stop(ErlNifEnv *env, void *obj, ErlNifEvent event, int is_direct_call) {
    (void)env;
    (void)event;
    (void)is_direct_call;
    UsbFd *r = (UsbFd *)obj;
    enif_mutex_lock(r->lock);
    r->select_active = 0;
    teardown_fd(r);
    enif_mutex_unlock(r->lock);
}

static void usb_fd_dtor(ErlNifEnv *env, void *obj) {
    (void)env;
    UsbFd *r = (UsbFd *)obj;
    // If the fd was ever selected upon, the stop callback already tore it down
    // (enif_select keeps the resource alive until STOP completes, so stop runs
    // before dtor). Otherwise close it here. No other references remain.
    if (r->fd >= 0)
        teardown_fd(r);
    if (r->lock) {
        enif_mutex_destroy(r->lock);
        r->lock = NULL;
    }
}

// ---- open flags ----------------------------------------------------------

// Translate a list of flag atoms to open(2) flags. O_CLOEXEC is always set so
// descriptors never leak across an exec. Returns -1 on a bad flag.
static int parse_open_flags(ErlNifEnv *env, ERL_NIF_TERM list, int *out) {
    int flags = O_CLOEXEC;
    int have_access = 0;
    ERL_NIF_TERM head, tail = list;
    char name[16];

    while (enif_get_list_cell(env, tail, &head, &tail)) {
        if (enif_get_atom(env, head, name, sizeof(name), ERL_NIF_LATIN1) <= 0)
            return -1;
        if (strcmp(name, "rdonly") == 0)      { flags |= O_RDONLY; have_access = 1; }
        else if (strcmp(name, "wronly") == 0) { flags |= O_WRONLY; have_access = 1; }
        else if (strcmp(name, "rdwr") == 0)   { flags |= O_RDWR;   have_access = 1; }
        else if (strcmp(name, "nonblock") == 0) flags |= O_NONBLOCK;
        else if (strcmp(name, "cloexec") == 0)  flags |= O_CLOEXEC;
        else if (strcmp(name, "sync") == 0)     flags |= O_SYNC;
        else return -1;
    }
    if (!have_access)
        flags |= O_RDWR; // sensible default for usbfs
    *out = flags;
    return 0;
}

// Bounded unsigned getters: reject out-of-range values as badarg so a caller
// can never overflow a usbfs struct field.
static int get_bounded(ErlNifEnv *env, ERL_NIF_TERM t, unsigned max, unsigned *out) {
    unsigned v;
    if (!enif_get_uint(env, t, &v) || v > max)
        return 0;
    *out = v;
    return 1;
}

// Wrap an already-open fd (usbfs node or netlink socket) in a UsbFd resource and
// return {:ok, handle}. Takes ownership of fd: it is closed on error.
static ERL_NIF_TERM wrap_fd(ErlNifEnv *env, int fd) {
    UsbFd *r = enif_alloc_resource(usb_fd_type, sizeof(UsbFd));
    if (!r) {
        close(fd);
        return err_tuple(env, ENOMEM);
    }
    r->fd = fd;
    r->inflight = NULL;
    r->select_active = 0;
    r->closing = 0;
    r->lock = enif_mutex_create("circuits_usb_fd");
    if (!r->lock) {
        close(fd);
        r->fd = -1;
        enif_release_resource(r);
        return err_tuple(env, ENOMEM);
    }
    ERL_NIF_TERM term = enif_make_resource(env, r);
    enif_release_resource(r); // the term now owns the only reference
    return enif_make_tuple2(env, am_ok, term);
}

// ---- NIFs ----------------------------------------------------------------

// open(path :: binary, flags :: [atom]) -> {:ok, handle} | {:error, atom}
static ERL_NIF_TERM nif_open(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    ErlNifBinary path;
    if (!enif_inspect_binary(env, argv[0], &path) &&
        !enif_inspect_iolist_as_binary(env, argv[0], &path))
        return enif_make_badarg(env);
    if (path.size == 0 || path.size > 4095)
        return enif_make_badarg(env);

    int flags;
    if (parse_open_flags(env, argv[1], &flags) != 0)
        return enif_make_badarg(env);

    // NUL-terminate the path.
    char cpath[4096];
    memcpy(cpath, path.data, path.size);
    cpath[path.size] = '\0';

    int fd = open(cpath, flags);
    if (fd < 0)
        return err_tuple(env, errno);

    return wrap_fd(env, fd);
}

// close(handle) -> :ok | {:error, atom}   (idempotent)
//
// If the fd was ever armed for select, tear it down via ERL_NIF_SELECT_STOP so
// the fd is removed from the poller before close() -- an in-flight select over a
// closed fd is a bug class. The actual close + URB cleanup happens in the stop
// callback. Otherwise close inline.
static ERL_NIF_TERM nif_close(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    UsbFd *r;
    if (!enif_get_resource(env, argv[0], usb_fd_type, (void **)&r))
        return enif_make_badarg(env);

    enif_mutex_lock(r->lock);
    if (r->closing || r->fd < 0) {
        enif_mutex_unlock(r->lock);
        return am_ok;
    }
    r->closing = 1;
    int select_active = r->select_active;
    int fd = r->fd;

    if (select_active) {
        // Release the lock BEFORE enif_select(STOP): the stop callback may run
        // synchronously in this thread and it takes r->lock -- holding it here
        // would deadlock. `closing` already blocks any concurrent re-entry, and
        // usb_fd_stop() does the actual close + URB teardown under the lock.
        enif_mutex_unlock(r->lock);
        enif_select(env, (ErlNifEvent)fd, ERL_NIF_SELECT_STOP, r, NULL,
                    enif_make_atom(env, "undefined"));
        return am_ok;
    }

    int rc = close(fd);
    int e = errno;
    r->fd = -1;
    Urb *u = r->inflight;
    while (u) {
        Urb *n = u->next;
        urb_free(u);
        u = n;
    }
    r->inflight = NULL;
    enif_mutex_unlock(r->lock);

    if (rc != 0)
        return err_tuple(env, e);
    return am_ok;
}

// read(handle, count :: non_neg_integer) -> {:ok, binary} | {:error, atom}
static ERL_NIF_TERM nif_read(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    UsbFd *r;
    unsigned long count;
    if (!enif_get_resource(env, argv[0], usb_fd_type, (void **)&r))
        return enif_make_badarg(env);
    if (!enif_get_ulong(env, argv[1], &count))
        return enif_make_badarg(env);
    if (count > (16u * 1024 * 1024))
        return enif_make_badarg(env); // sanity cap; descriptors are tiny

    ErlNifBinary bin;
    if (!enif_alloc_binary((size_t)count, &bin))
        return err_tuple(env, ENOMEM);

    ssize_t n;
    int e = 0;
    enif_mutex_lock(r->lock);
    if (r->fd < 0) {
        enif_mutex_unlock(r->lock);
        enif_release_binary(&bin);
        return enif_make_tuple2(env, am_error, am_ebadf);
    }
    n = read(r->fd, bin.data, (size_t)count);
    e = errno;
    enif_mutex_unlock(r->lock);

    if (n < 0) {
        enif_release_binary(&bin);
        return err_tuple(env, e);
    }
    if ((size_t)n != bin.size) {
        if (!enif_realloc_binary(&bin, (size_t)n)) {
            enif_release_binary(&bin);
            return err_tuple(env, ENOMEM);
        }
    }
    return enif_make_tuple2(env, am_ok, enif_make_binary(env, &bin));
}

// write(handle, data :: iodata) -> {:ok, bytes_written} | {:error, atom}
static ERL_NIF_TERM nif_write(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    UsbFd *r;
    ErlNifBinary data;
    if (!enif_get_resource(env, argv[0], usb_fd_type, (void **)&r))
        return enif_make_badarg(env);
    if (!enif_inspect_iolist_as_binary(env, argv[1], &data))
        return enif_make_badarg(env);

    ssize_t n;
    int e = 0;
    enif_mutex_lock(r->lock);
    if (r->fd < 0) {
        enif_mutex_unlock(r->lock);
        return enif_make_tuple2(env, am_error, am_ebadf);
    }
    n = write(r->fd, data.data, data.size);
    e = errno;
    enif_mutex_unlock(r->lock);

    if (n < 0)
        return err_tuple(env, e);
    return enif_make_tuple2(env, am_ok, enif_make_ulong(env, (unsigned long)n));
}

// USBDEVFS_CONTROL wLength is a __u16, so transfers are bounded at 65535 bytes.
#define CTRL_MAX_LEN 0xFFFF

// control_transfer(handle, bmRequestType, bRequest, wValue, wIndex,
//                  data_or_length, timeout_ms)
//   IN  (bmRequestType band 0x80 != 0): data_or_length is the length to read;
//       returns {:ok, binary} with the bytes the device returned.
//   OUT: data_or_length is the payload (iodata); returns {:ok, bytes_written}.
//
// This is the B2 marshalling + pointer fixup: we build struct
// usbdevfs_ctrltransfer ourselves (so the layout and _IOC_SIZE are ours, never
// caller-supplied), allocate one stable buffer of exactly wLength, embed its
// address in ctrl.data, run the ioctl, then read the buffer back. Over/undersized
// requests are rejected here, before the syscall. USBDEVFS_CONTROL blocks until
// the transfer completes or times out, so this runs on a dirty I/O scheduler.
static ERL_NIF_TERM nif_control_transfer(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    UsbFd *r;
    unsigned rtype, req, wvalue, windex, timeout;
    if (!enif_get_resource(env, argv[0], usb_fd_type, (void **)&r) ||
        !get_bounded(env, argv[1], 0xFF, &rtype) ||
        !get_bounded(env, argv[2], 0xFF, &req) ||
        !get_bounded(env, argv[3], 0xFFFF, &wvalue) ||
        !get_bounded(env, argv[4], 0xFFFF, &windex) ||
        !enif_get_uint(env, argv[6], &timeout))
        return enif_make_badarg(env);

    int is_in = (rtype & 0x80) != 0;

    // Determine wLength and, for OUT, the payload, validating size up front.
    ErlNifBinary out_data = {0};
    size_t wlen;
    if (is_in) {
        unsigned long len;
        if (!enif_get_ulong(env, argv[5], &len) || len > CTRL_MAX_LEN)
            return enif_make_badarg(env);
        wlen = (size_t)len;
    } else {
        if (!enif_inspect_iolist_as_binary(env, argv[5], &out_data) ||
            out_data.size > CTRL_MAX_LEN)
            return enif_make_badarg(env);
        wlen = out_data.size;
    }

    // One stable buffer, exactly wLength; the kernel never writes past it.
    unsigned char *buf = NULL;
    if (wlen) {
        buf = enif_alloc(wlen);
        if (!buf)
            return err_tuple(env, ENOMEM);
        if (!is_in)
            memcpy(buf, out_data.data, wlen);
    }

    struct usbdevfs_ctrltransfer ctrl;
    memset(&ctrl, 0, sizeof(ctrl));
    ctrl.bRequestType = (uint8_t)rtype;
    ctrl.bRequest = (uint8_t)req;
    ctrl.wValue = (uint16_t)wvalue;
    ctrl.wIndex = (uint16_t)windex;
    ctrl.wLength = (uint16_t)wlen;
    ctrl.timeout = timeout;
    ctrl.data = buf; // pointer fixup: real address at the known offset

    int n, e = 0;
    enif_mutex_lock(r->lock);
    if (r->fd < 0) {
        enif_mutex_unlock(r->lock);
        enif_free(buf);
        return enif_make_tuple2(env, am_error, am_ebadf);
    }
    n = ioctl(r->fd, USBDEVFS_CONTROL, &ctrl);
    e = errno;
    enif_mutex_unlock(r->lock);

    if (n < 0) {
        enif_free(buf);
        return err_tuple(env, e);
    }

    ERL_NIF_TERM result;
    if (is_in) {
        ErlNifBinary rb;
        if (!enif_alloc_binary((size_t)n, &rb)) {
            enif_free(buf);
            return err_tuple(env, ENOMEM);
        }
        if (n > 0)
            memcpy(rb.data, buf, (size_t)n);
        result = enif_make_tuple2(env, am_ok, enif_make_binary(env, &rb));
    } else {
        result = enif_make_tuple2(env, am_ok, enif_make_ulong(env, (unsigned long)n));
    }
    enif_free(buf);
    return result;
}

// set_interface(handle, interface, altsetting) -> :ok | {:error, atom}
// USBDEVFS_SETINTERFACE; no data buffer, but it drives a SET_INTERFACE request
// to the device, so it can block -> dirty I/O scheduler.
static ERL_NIF_TERM nif_set_interface(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    UsbFd *r;
    unsigned iface, alt;
    if (!enif_get_resource(env, argv[0], usb_fd_type, (void **)&r) ||
        !enif_get_uint(env, argv[1], &iface) ||
        !enif_get_uint(env, argv[2], &alt))
        return enif_make_badarg(env);

    struct usbdevfs_setinterface si;
    memset(&si, 0, sizeof(si));
    si.interface = iface;
    si.altsetting = alt;

    int rc, e = 0;
    enif_mutex_lock(r->lock);
    if (r->fd < 0) {
        enif_mutex_unlock(r->lock);
        return enif_make_tuple2(env, am_error, am_ebadf);
    }
    rc = ioctl(r->fd, USBDEVFS_SETINTERFACE, &si);
    e = errno;
    enif_mutex_unlock(r->lock);

    if (rc < 0)
        return err_tuple(env, e);
    return am_ok;
}

// Bulk transfers can be large; cap allocations at a sane ceiling.
#define BULK_MAX_LEN (16u * 1024 * 1024)

// bulk_transfer(handle, endpoint, data_or_length, timeout_ms)
//   IN  (endpoint band 0x80 != 0): data_or_length is the length to read;
//       returns {:ok, binary} of what the device sent.
//   OUT: data_or_length is the payload (iodata); returns {:ok, bytes_written}.
//
// Same marshalling + pointer-fixup pattern as control_transfer, over struct
// usbdevfs_bulktransfer. The interface owning the endpoint must be claimed
// first. Blocks until the transfer completes or times out -> dirty I/O.
static ERL_NIF_TERM nif_bulk_transfer(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    UsbFd *r;
    unsigned ep, timeout;
    if (!enif_get_resource(env, argv[0], usb_fd_type, (void **)&r) ||
        !get_bounded(env, argv[1], 0xFF, &ep) ||
        !enif_get_uint(env, argv[3], &timeout))
        return enif_make_badarg(env);

    int is_in = (ep & 0x80) != 0;

    ErlNifBinary out_data = {0};
    size_t len;
    if (is_in) {
        unsigned long n;
        if (!enif_get_ulong(env, argv[2], &n) || n > BULK_MAX_LEN)
            return enif_make_badarg(env);
        len = (size_t)n;
    } else {
        if (!enif_inspect_iolist_as_binary(env, argv[2], &out_data) ||
            out_data.size > BULK_MAX_LEN)
            return enif_make_badarg(env);
        len = out_data.size;
    }

    unsigned char *buf = NULL;
    if (len) {
        buf = enif_alloc(len);
        if (!buf)
            return err_tuple(env, ENOMEM);
        if (!is_in)
            memcpy(buf, out_data.data, len);
    }

    struct usbdevfs_bulktransfer bt;
    memset(&bt, 0, sizeof(bt));
    bt.ep = ep;
    bt.len = (unsigned int)len;
    bt.timeout = timeout;
    bt.data = buf; // pointer fixup

    int n, e = 0;
    enif_mutex_lock(r->lock);
    if (r->fd < 0) {
        enif_mutex_unlock(r->lock);
        enif_free(buf);
        return enif_make_tuple2(env, am_error, am_ebadf);
    }
    n = ioctl(r->fd, USBDEVFS_BULK, &bt);
    e = errno;
    enif_mutex_unlock(r->lock);

    if (n < 0) {
        enif_free(buf);
        return err_tuple(env, e);
    }

    ERL_NIF_TERM result;
    if (is_in) {
        ErlNifBinary rb;
        if (!enif_alloc_binary((size_t)n, &rb)) {
            enif_free(buf);
            return err_tuple(env, ENOMEM);
        }
        if (n > 0)
            memcpy(rb.data, buf, (size_t)n);
        result = enif_make_tuple2(env, am_ok, enif_make_binary(env, &rb));
    } else {
        result = enif_make_tuple2(env, am_ok, enif_make_ulong(env, (unsigned long)n));
    }
    enif_free(buf);
    return result;
}

// A fast fd bookkeeping ioctl whose only argument is an unsigned int passed by
// reference (claim/release interface, clear halt). Runs inline.
static ERL_NIF_TERM uint_ioctl(ErlNifEnv *env, const ERL_NIF_TERM argv[],
                               unsigned long request) {
    UsbFd *r;
    unsigned value;
    if (!enif_get_resource(env, argv[0], usb_fd_type, (void **)&r) ||
        !enif_get_uint(env, argv[1], &value))
        return enif_make_badarg(env);

    unsigned int arg = value;
    int rc, e = 0;
    enif_mutex_lock(r->lock);
    if (r->fd < 0) {
        enif_mutex_unlock(r->lock);
        return enif_make_tuple2(env, am_error, am_ebadf);
    }
    rc = ioctl(r->fd, request, &arg);
    e = errno;
    enif_mutex_unlock(r->lock);

    if (rc < 0)
        return err_tuple(env, e);
    return am_ok;
}

// claim_interface(handle, interface) -> :ok | {:error, atom}
static ERL_NIF_TERM nif_claim_interface(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    return uint_ioctl(env, argv, USBDEVFS_CLAIMINTERFACE);
}

// release_interface(handle, interface) -> :ok | {:error, atom}
static ERL_NIF_TERM nif_release_interface(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    return uint_ioctl(env, argv, USBDEVFS_RELEASEINTERFACE);
}

// ---- kernel driver detach/reattach (B6) --------------------------------

// get_driver(handle, interface) -> {:ok, name} | {:error, atom}
// Name of the kernel driver bound to the interface, or :enodata if none.
static ERL_NIF_TERM nif_get_driver(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    UsbFd *r;
    unsigned iface;
    if (!enif_get_resource(env, argv[0], usb_fd_type, (void **)&r) ||
        !enif_get_uint(env, argv[1], &iface))
        return enif_make_badarg(env);

    struct usbdevfs_getdriver gd;
    memset(&gd, 0, sizeof(gd));
    gd.interface = iface;

    int rc, e = 0;
    enif_mutex_lock(r->lock);
    if (r->fd < 0) {
        enif_mutex_unlock(r->lock);
        return enif_make_tuple2(env, am_error, am_ebadf);
    }
    rc = ioctl(r->fd, USBDEVFS_GETDRIVER, &gd);
    e = errno;
    enif_mutex_unlock(r->lock);

    if (rc < 0)
        return err_tuple(env, e);

    gd.driver[USBDEVFS_MAXDRIVERNAME] = '\0';
    ERL_NIF_TERM name;
    size_t len = strlen(gd.driver);
    unsigned char *buf = enif_make_new_binary(env, len, &name);
    memcpy(buf, gd.driver, len);
    return enif_make_tuple2(env, am_ok, name);
}

// Wrap a nested usbfs ioctl (DISCONNECT/CONNECT) targeting an interface, sent
// via USBDEVFS_IOCTL. Detach/attach drive the kernel driver's disconnect/probe,
// so they can block -> dirty I/O.
static ERL_NIF_TERM driver_ioctl(ErlNifEnv *env, const ERL_NIF_TERM argv[], int nested_code) {
    UsbFd *r;
    unsigned iface;
    if (!enif_get_resource(env, argv[0], usb_fd_type, (void **)&r) ||
        !enif_get_uint(env, argv[1], &iface))
        return enif_make_badarg(env);

    struct usbdevfs_ioctl cmd;
    memset(&cmd, 0, sizeof(cmd));
    cmd.ifno = (int)iface;
    cmd.ioctl_code = nested_code;
    cmd.data = NULL;

    int rc, e = 0;
    enif_mutex_lock(r->lock);
    if (r->fd < 0) {
        enif_mutex_unlock(r->lock);
        return enif_make_tuple2(env, am_error, am_ebadf);
    }
    rc = ioctl(r->fd, USBDEVFS_IOCTL, &cmd);
    e = errno;
    enif_mutex_unlock(r->lock);

    if (rc < 0)
        return err_tuple(env, e);
    return am_ok;
}

// detach_driver(handle, interface) -> :ok | {:error, atom}
static ERL_NIF_TERM nif_detach_driver(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    return driver_ioctl(env, argv, USBDEVFS_DISCONNECT);
}

// clear_halt(handle, endpoint) -> :ok | {:error, atom}
// Clear an endpoint's halt/stall (USBDEVFS_CLEAR_HALT sends CLEAR_FEATURE
// ENDPOINT_HALT). Drives a control request, so dirty I/O.
static ERL_NIF_TERM nif_clear_halt(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    return uint_ioctl(env, argv, USBDEVFS_CLEAR_HALT);
}

// reset(handle) -> :ok | {:error, atom}
// Reset the device (USBDEVFS_RESET). Re-enumerates, so dirty I/O; the device may
// come back with a new address, invalidating this handle.
static ERL_NIF_TERM nif_reset(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    UsbFd *r;
    if (!enif_get_resource(env, argv[0], usb_fd_type, (void **)&r))
        return enif_make_badarg(env);

    int rc, e = 0;
    enif_mutex_lock(r->lock);
    if (r->fd < 0) {
        enif_mutex_unlock(r->lock);
        return enif_make_tuple2(env, am_error, am_ebadf);
    }
    rc = ioctl(r->fd, USBDEVFS_RESET);
    e = errno;
    enif_mutex_unlock(r->lock);

    if (rc < 0)
        return err_tuple(env, e);
    return am_ok;
}

// attach_driver(handle, interface) -> :ok | {:error, atom}
static ERL_NIF_TERM nif_attach_driver(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    return driver_ioctl(env, argv, USBDEVFS_CONNECT);
}

// ---- async engine: submit / select / reap / discard (B5) ---------------

// A completed URB's status: 0 -> :ok, negative -> errno atom of its magnitude.
static ERL_NIF_TERM urb_status_term(ErlNifEnv *env, int status) {
    if (status == 0)
        return am_ok;
    return errno_atom(env, status < 0 ? -status : status);
}

// submit_urb(handle, tag :: u64, urb_type, endpoint, data_or_length, flags)
//   -> :ok | {:error, atom}
// Fast, non-blocking SUBMITURB: hands a URB (bulk or interrupt) to the kernel
// and returns immediately. urb_type is USBDEVFS_URB_TYPE_BULK/INTERRUPT. flags is
// a subset of {USBDEVFS_URB_ZERO_PACKET} -- a terminating zero-length packet for
// OUT transfers. The URB (and its buffer) are tracked on the fd until reaped.
static ERL_NIF_TERM nif_submit(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    UsbFd *r;
    ErlNifUInt64 tag;
    unsigned urb_type, ep, flags;
    if (!enif_get_resource(env, argv[0], usb_fd_type, (void **)&r) ||
        !enif_get_uint64(env, argv[1], &tag) ||
        !get_bounded(env, argv[2], 0xFF, &urb_type) ||
        !get_bounded(env, argv[3], 0xFF, &ep) ||
        !enif_get_uint(env, argv[5], &flags))
        return enif_make_badarg(env);

    if (urb_type != USBDEVFS_URB_TYPE_BULK && urb_type != USBDEVFS_URB_TYPE_INTERRUPT)
        return enif_make_badarg(env);
    if (flags & ~(unsigned)USBDEVFS_URB_ZERO_PACKET)
        return enif_make_badarg(env);

    int is_in = (ep & 0x80) != 0;

    ErlNifBinary out_data = {0};
    size_t len;
    if (is_in) {
        unsigned long n;
        if (!enif_get_ulong(env, argv[4], &n) || n > BULK_MAX_LEN)
            return enif_make_badarg(env);
        len = (size_t)n;
    } else {
        if (!enif_inspect_iolist_as_binary(env, argv[4], &out_data) ||
            out_data.size > BULK_MAX_LEN)
            return enif_make_badarg(env);
        len = out_data.size;
    }

    Urb *u = enif_alloc(sizeof(Urb));
    if (!u)
        return err_tuple(env, ENOMEM);
    memset(u, 0, sizeof(*u));
    u->buffer_len = len;
    u->is_in = is_in;
    u->tag = tag;
    if (len) {
        u->buffer = enif_alloc(len);
        if (!u->buffer) {
            enif_free(u);
            return err_tuple(env, ENOMEM);
        }
        if (!is_in)
            memcpy(u->buffer, out_data.data, len);
    }
    u->kurb.type = (unsigned char)urb_type;
    u->kurb.endpoint = (unsigned char)ep;
    u->kurb.flags = flags;
    u->kurb.buffer = u->buffer;
    u->kurb.buffer_length = (int)len;
    u->kurb.usercontext = u;

    enif_mutex_lock(r->lock);
    if (r->fd < 0) {
        enif_mutex_unlock(r->lock);
        urb_free(u);
        return enif_make_tuple2(env, am_error, am_ebadf);
    }
    int rc = ioctl(r->fd, USBDEVFS_SUBMITURB, &u->kurb);
    int e = errno;
    if (rc < 0) {
        enif_mutex_unlock(r->lock);
        urb_free(u);
        return err_tuple(env, e);
    }
    urb_link(r, u);
    enif_mutex_unlock(r->lock);
    return am_ok;
}

// Max isochronous packets per URB (usbfs caps at 128; keep a bit of headroom).
#define ISO_MAX_PACKETS 128

// submit_iso(handle, tag :: u64, endpoint, packet_lengths :: [uint], out_data)
//   -> :ok | {:error, atom}
// Isochronous URB. packet_lengths gives the per-packet byte counts (and thus the
// packet count and total buffer size). For IN, out_data is ignored and each
// packet reads up to its length; for OUT, out_data must be exactly the total.
// Scheduled ASAP. Reaped by reap/1 with per-packet {actual_length, status}.
static ERL_NIF_TERM nif_submit_iso(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    UsbFd *r;
    ErlNifUInt64 tag;
    unsigned ep, count;
    if (!enif_get_resource(env, argv[0], usb_fd_type, (void **)&r) ||
        !enif_get_uint64(env, argv[1], &tag) ||
        !get_bounded(env, argv[2], 0xFF, &ep) ||
        !enif_get_list_length(env, argv[3], &count) ||
        count == 0 || count > ISO_MAX_PACKETS)
        return enif_make_badarg(env);

    // Read the per-packet lengths and total.
    unsigned lengths[ISO_MAX_PACKETS];
    size_t total = 0;
    ERL_NIF_TERM head, tail = argv[3];
    for (unsigned i = 0; i < count; i++) {
        unsigned l;
        if (!enif_get_list_cell(env, tail, &head, &tail) || !enif_get_uint(env, head, &l) ||
            l > 0xFFFF)
            return enif_make_badarg(env);
        lengths[i] = l;
        total += l;
    }
    if (total > BULK_MAX_LEN)
        return enif_make_badarg(env);

    int is_in = (ep & 0x80) != 0;
    ErlNifBinary out_data = {0};
    if (!is_in) {
        if (!enif_inspect_iolist_as_binary(env, argv[4], &out_data) || out_data.size != total)
            return enif_make_badarg(env);
    }

    // Over-allocate the Urb so kurb's trailing iso_frame_desc[count] fits.
    size_t urb_size = sizeof(Urb) + (size_t)count * sizeof(struct usbdevfs_iso_packet_desc);
    Urb *u = enif_alloc(urb_size);
    if (!u)
        return err_tuple(env, ENOMEM);
    memset(u, 0, urb_size);
    u->buffer_len = total;
    u->is_in = is_in;
    u->num_packets = (int)count;
    u->tag = tag;
    if (total) {
        u->buffer = enif_alloc(total);
        if (!u->buffer) {
            enif_free(u);
            return err_tuple(env, ENOMEM);
        }
        if (!is_in)
            memcpy(u->buffer, out_data.data, total);
    }
    u->kurb.type = USBDEVFS_URB_TYPE_ISO;
    u->kurb.endpoint = (unsigned char)ep;
    u->kurb.flags = USBDEVFS_URB_ISO_ASAP;
    u->kurb.buffer = u->buffer;
    u->kurb.buffer_length = (int)total;
    u->kurb.number_of_packets = (int)count;
    u->kurb.usercontext = u;
    for (unsigned i = 0; i < count; i++)
        u->kurb.iso_frame_desc[i].length = lengths[i];

    enif_mutex_lock(r->lock);
    if (r->fd < 0) {
        enif_mutex_unlock(r->lock);
        urb_free(u);
        return enif_make_tuple2(env, am_error, am_ebadf);
    }
    int rc = ioctl(r->fd, USBDEVFS_SUBMITURB, &u->kurb);
    int e = errno;
    if (rc < 0) {
        enif_mutex_unlock(r->lock);
        urb_free(u);
        return err_tuple(env, e);
    }
    urb_link(r, u);
    enif_mutex_unlock(r->lock);
    return am_ok;
}

// select(handle, ref) -> :ok | {:error, atom}
// Arm enif_select for write-readiness: usbfs reports POLLOUT when a URB is
// reapable. The calling process gets `{:select, handle, ref, :ready_output}`.
static ERL_NIF_TERM nif_select(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    UsbFd *r;
    if (!enif_get_resource(env, argv[0], usb_fd_type, (void **)&r))
        return enif_make_badarg(env);

    enif_mutex_lock(r->lock);
    if (r->fd < 0 || r->closing) {
        enif_mutex_unlock(r->lock);
        return enif_make_tuple2(env, am_error, am_ebadf);
    }
    int rc = enif_select(env, (ErlNifEvent)r->fd, ERL_NIF_SELECT_WRITE, r, NULL, argv[1]);
    if (rc >= 0)
        r->select_active = 1;
    enif_mutex_unlock(r->lock);

    if (rc < 0)
        return enif_make_tuple2(env, am_error, enif_make_atom(env, "eselect"));
    return am_ok;
}

// select_read(handle, ref) -> :ok | {:error, atom}
// Arm enif_select for read-readiness (POLLIN). Used for the hotplug netlink
// socket. The caller gets `{:select, handle, ref, :ready_input}`.
static ERL_NIF_TERM nif_select_read(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    UsbFd *r;
    if (!enif_get_resource(env, argv[0], usb_fd_type, (void **)&r))
        return enif_make_badarg(env);

    enif_mutex_lock(r->lock);
    if (r->fd < 0 || r->closing) {
        enif_mutex_unlock(r->lock);
        return enif_make_tuple2(env, am_error, am_ebadf);
    }
    int rc = enif_select(env, (ErlNifEvent)r->fd, ERL_NIF_SELECT_READ, r, NULL, argv[1]);
    if (rc >= 0)
        r->select_active = 1;
    enif_mutex_unlock(r->lock);

    if (rc < 0)
        return enif_make_tuple2(env, am_error, enif_make_atom(env, "eselect"));
    return am_ok;
}

// netlink_uevent_open() -> {:ok, handle} | {:error, atom}
// Open a NETLINK_KOBJECT_UEVENT socket bound to the kernel uevent broadcast
// group. read/1 returns one uevent datagram; select_read/2 signals readiness.
// Non-blocking + cloexec. Usually needs root / CAP_NET_ADMIN.
static ERL_NIF_TERM nif_netlink_uevent_open(ErlNifEnv *env, int argc,
                                            const ERL_NIF_TERM argv[]) {
    (void)argc;
    (void)argv;
    int fd = socket(AF_NETLINK, SOCK_DGRAM | SOCK_CLOEXEC | SOCK_NONBLOCK, NETLINK_KOBJECT_UEVENT);
    if (fd < 0)
        return err_tuple(env, errno);

    struct sockaddr_nl addr;
    memset(&addr, 0, sizeof(addr));
    addr.nl_family = AF_NETLINK;
    addr.nl_pid = 0;      // let the kernel assign a unique pid
    addr.nl_groups = 1;   // group 1 == the uevent multicast group
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        int e = errno;
        close(fd);
        return err_tuple(env, e);
    }
    return wrap_fd(env, fd);
}

// reap(handle) -> [{tag :: u64, status :: :ok | atom, data_or_actual_length}]
// Drains all currently-completed URBs with the non-blocking REAPURBNDELAY. For
// IN URBs the third element is the received binary; for OUT it is the actual
// length written. Runs inline (each reap is non-blocking).
static ERL_NIF_TERM nif_reap(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    UsbFd *r;
    if (!enif_get_resource(env, argv[0], usb_fd_type, (void **)&r))
        return enif_make_badarg(env);

    ERL_NIF_TERM list = enif_make_list(env, 0);

    enif_mutex_lock(r->lock);
    if (r->fd < 0) {
        enif_mutex_unlock(r->lock);
        return list;
    }
    for (;;) {
        struct usbdevfs_urb *ku = NULL;
        int rc = ioctl(r->fd, USBDEVFS_REAPURBNDELAY, &ku);
        if (rc < 0)
            break; // EAGAIN (none ready) or a terminal error; stop draining
        Urb *u = (Urb *)ku->usercontext;

        ERL_NIF_TERM payload;
        if (u->num_packets > 0) {
            // Isochronous: {:iso, data_or_actual, [{actual_length, status}, ...]}.
            ERL_NIF_TERM plist = enif_make_list(env, 0);
            for (int i = u->num_packets - 1; i >= 0; i--) {
                struct usbdevfs_iso_packet_desc *pd = &u->kurb.iso_frame_desc[i];
                ERL_NIF_TERM pe = enif_make_tuple2(env, enif_make_uint(env, pd->actual_length),
                                                   urb_status_term(env, (int)pd->status));
                plist = enif_make_list_cell(env, pe, plist);
            }
            ERL_NIF_TERM data;
            if (u->is_in) {
                ErlNifBinary b;
                if (!enif_alloc_binary(u->buffer_len, &b)) {
                    data = enif_make_int(env, u->kurb.actual_length);
                } else {
                    if (u->buffer_len)
                        memcpy(b.data, u->buffer, u->buffer_len);
                    data = enif_make_binary(env, &b);
                }
            } else {
                data = enif_make_int(env, u->kurb.actual_length);
            }
            payload = enif_make_tuple3(env, mk_atom(env, "iso"), data, plist);
        } else if (u->is_in) {
            size_t got = u->kurb.actual_length > 0 ? (size_t)u->kurb.actual_length : 0;
            ErlNifBinary b;
            if (!enif_alloc_binary(got, &b)) {
                // Drop this completion's data but keep draining/cleanup.
                payload = enif_make_int(env, u->kurb.actual_length);
            } else {
                if (got)
                    memcpy(b.data, u->buffer, got);
                payload = enif_make_binary(env, &b);
            }
        } else {
            payload = enif_make_int(env, u->kurb.actual_length);
        }

        ERL_NIF_TERM entry = enif_make_tuple3(
            env, enif_make_uint64(env, u->tag), urb_status_term(env, u->kurb.status), payload);
        list = enif_make_list_cell(env, entry, list);

        urb_unlink(r, u);
        urb_free(u);
    }
    enif_mutex_unlock(r->lock);
    return list;
}

// discard(handle, tag) -> :ok | {:error, :enoent} | {:error, atom}
// Cancel an in-flight URB. It still completes (with an ECONNRESET status) and is
// delivered by the next reap, which is where its memory is reclaimed.
static ERL_NIF_TERM nif_discard(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    UsbFd *r;
    ErlNifUInt64 tag;
    if (!enif_get_resource(env, argv[0], usb_fd_type, (void **)&r) ||
        !enif_get_uint64(env, argv[1], &tag))
        return enif_make_badarg(env);

    enif_mutex_lock(r->lock);
    if (r->fd < 0) {
        enif_mutex_unlock(r->lock);
        return enif_make_tuple2(env, am_error, am_ebadf);
    }
    Urb *u = r->inflight;
    while (u && u->tag != tag)
        u = u->next;
    if (!u) {
        enif_mutex_unlock(r->lock);
        return enif_make_tuple2(env, am_error, enif_make_atom(env, "enoent"));
    }
    int rc = ioctl(r->fd, USBDEVFS_DISCARDURB, &u->kurb);
    int e = errno;
    enif_mutex_unlock(r->lock);

    // ENOENT/EINVAL here just means it already completed; treat as success.
    if (rc < 0 && e != ENOENT && e != EINVAL)
        return err_tuple(env, e);
    return am_ok;
}

// fileno(handle) -> integer | {:error, :ebadf}   (debug aid; verifies no leak)
static ERL_NIF_TERM nif_fileno(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    UsbFd *r;
    if (!enif_get_resource(env, argv[0], usb_fd_type, (void **)&r))
        return enif_make_badarg(env);
    int fd;
    enif_mutex_lock(r->lock);
    fd = r->fd;
    enif_mutex_unlock(r->lock);
    if (fd < 0)
        return enif_make_tuple2(env, am_error, am_ebadf);
    return enif_make_int(env, fd);
}

// ---- load ----------------------------------------------------------------

static int load(ErlNifEnv *env, void **priv_data, ERL_NIF_TERM load_info) {
    (void)priv_data;
    (void)load_info;
    ErlNifResourceFlags tried;
    ErlNifResourceTypeInit init = {0};
    init.dtor = usb_fd_dtor;
    init.stop = usb_fd_stop; // needed for enif_select teardown (B5)
    usb_fd_type = enif_open_resource_type_x(env, "circuits_usb_fd", &init,
                                            ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER,
                                            &tried);
    if (!usb_fd_type)
        return -1;

    am_ok = mk_atom(env, "ok");
    am_error = mk_atom(env, "error");
    am_ebadf = mk_atom(env, "ebadf");
    return 0;
}

static ErlNifFunc nif_funcs[] = {
    {"open", 2, nif_open, 0},
    {"close", 1, nif_close, 0},
    {"read", 2, nif_read, 0},
    {"write", 2, nif_write, 0},
    {"fileno", 1, nif_fileno, 0},
    // Blocking usbfs ioctls run on a dirty I/O scheduler (correctness-first,
    // per B4; the async select/reap engine in B5 supersedes the blocking path).
    {"control_transfer", 7, nif_control_transfer, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"bulk_transfer", 4, nif_bulk_transfer, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"set_interface", 3, nif_set_interface, ERL_NIF_DIRTY_JOB_IO_BOUND},
    // claim/release are fast fd bookkeeping ops -> normal scheduler.
    {"claim_interface", 2, nif_claim_interface, 0},
    {"release_interface", 2, nif_release_interface, 0},
    // driver query is fast; detach/attach drive probe/disconnect -> dirty I/O.
    {"get_driver", 2, nif_get_driver, 0},
    {"detach_driver", 2, nif_detach_driver, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"attach_driver", 2, nif_attach_driver, ERL_NIF_DIRTY_JOB_IO_BOUND},
    // recovery: clear stall / reset the device (both drive device round-trips).
    {"clear_halt", 2, nif_clear_halt, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"reset", 1, nif_reset, ERL_NIF_DIRTY_JOB_IO_BOUND},
    // async engine: all non-blocking, run inline on a normal scheduler.
    {"submit_urb", 6, nif_submit, 0},
    {"submit_iso", 5, nif_submit_iso, 0},
    {"select", 2, nif_select, 0},
    {"select_read", 2, nif_select_read, 0},
    {"reap", 1, nif_reap, 0},
    {"discard", 2, nif_discard, 0},
    // hotplug: netlink uevent socket (read/1 + select_read/2 drive it).
    {"netlink_uevent_open", 0, nif_netlink_uevent_open, 0},
};

ERL_NIF_INIT(Elixir.CircuitsUsb.Shim, nif_funcs, load, NULL, NULL, NULL)
