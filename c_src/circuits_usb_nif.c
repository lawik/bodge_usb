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
#include <unistd.h>

#include <linux/usbdevice_fs.h>

#include <erl_nif.h>

// ---- resource type -------------------------------------------------------

typedef struct {
    int fd;                 // -1 once closed
    ErlNifMutex *lock;      // serializes fd use vs close (no double-close/UAF)
} UsbFd;

static ErlNifResourceType *usb_fd_type = NULL;

// Atoms, initialized in load().
static ERL_NIF_TERM am_ok;
static ERL_NIF_TERM am_error;
static ERL_NIF_TERM am_ebadf;

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

static void usb_fd_dtor(ErlNifEnv *env, void *obj) {
    (void)env;
    UsbFd *r = (UsbFd *)obj;
    // GC: no other references remain, so no locking is needed, but guard anyway.
    if (r->fd >= 0) {
        close(r->fd);
        r->fd = -1;
    }
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

    UsbFd *r = enif_alloc_resource(usb_fd_type, sizeof(UsbFd));
    if (!r) {
        close(fd);
        return err_tuple(env, ENOMEM);
    }
    r->fd = fd;
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

// close(handle) -> :ok | {:error, atom}   (idempotent)
static ERL_NIF_TERM nif_close(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    UsbFd *r;
    if (!enif_get_resource(env, argv[0], usb_fd_type, (void **)&r))
        return enif_make_badarg(env);

    int rc = 0, e = 0;
    enif_mutex_lock(r->lock);
    if (r->fd >= 0) {
        rc = close(r->fd);
        e = errno;
        r->fd = -1; // never retry a closed fd, even if close() reported an error
    }
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
    usb_fd_type = enif_open_resource_type(env, NULL, "circuits_usb_fd",
                                          usb_fd_dtor,
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
};

ERL_NIF_INIT(Elixir.CircuitsUsb.Shim, nif_funcs, load, NULL, NULL, NULL)
