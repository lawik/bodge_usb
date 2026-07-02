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
#include <unistd.h>

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
};

ERL_NIF_INIT(Elixir.CircuitsUsb.Shim, nif_funcs, load, NULL, NULL, NULL)
