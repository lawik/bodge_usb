defmodule CircuitsUsb.Shim do
  @moduledoc """
  Low-level usbfs syscall shim (Part B1): the primitive tier of this library.

  A deliberately narrow NIF over a single file descriptor: `open/2`, `close/1`,
  `read/2`, `write/2`, the fixed usbfs ioctls, and the async URB primitives
  (`submit_bulk/5`, `submit_interrupt/5`, `submit_control/7`, `submit_iso/5`,
  `select/2`, `reap/1`, `discard/2`). The descriptor is held in a NIF resource
  whose destructor closes it, so a handle that goes out of scope and is garbage
  collected never leaks an fd.

  Most applications want the tiers built on top: `CircuitsUsb.Transfer` (a
  process that owns one handle and runs the submit/select/reap loop for you)
  or the `CircuitsUsb` facade. This module is a supported API in its own right,
  though, for code that wants no process between it and the fd -- your own
  engine, a soft real-time loop, an embedded receive loop. Using it directly
  means taking on the select/reap discipline yourself:

    * after `submit_*`, arm `select/2`; the poller sends
      `{:select, handle, ref, :ready_output}` to the calling process when a
      completion is reapable;
    * drain with `reap/1` (non-blocking, returns every completed URB), then
      re-arm `select/2` while URBs remain in flight;
    * `close/1` (or GC of the handle) cancels everything in flight.

  All calls return `{:error, errno_atom}` on failure, where `errno_atom` is the
  captured `errno` as an atom (`:enoent`, `:eacces`, `:enodev`, ...), or `:eNNN`
  for errnos without a dedicated name.
  """

  @typedoc "An open file-descriptor handle (a NIF resource)."
  @opaque handle :: reference()

  @typedoc "Flags accepted by `open/2`. `O_CLOEXEC` is always applied."
  @type open_flag :: :rdonly | :wronly | :rdwr | :nonblock | :cloexec | :sync

  @on_load :load_nif
  @doc false
  @spec load_nif() :: :ok | {:error, {atom(), charlist()}}
  def load_nif() do
    path = :filename.join(:code.priv_dir(:circuits_usb), ~c"circuits_usb_nif")
    :erlang.load_nif(path, 0)
  end

  @doc """
  Open `path`. Defaults to read/write. `O_CLOEXEC` is always set.

  Returns `{:ok, handle}` or `{:error, errno_atom}`.
  """
  @spec open(binary() | charlist(), [open_flag()]) :: {:ok, handle()} | {:error, atom()}
  def open(path, flags \\ [:rdwr])
  def open(path, flags) when is_list(path), do: open(IO.iodata_to_binary(path), flags)
  def open(_path, _flags), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Close a handle. Idempotent: closing an already-closed handle returns `:ok`.

  Always returns `:ok`. If a blocking ioctl is mid-flight on the handle, the
  fd teardown is deferred until it finishes (the fd is never closed out from
  under an active syscall); new operations are refused from this call onward.
  """
  @spec close(handle()) :: :ok
  def close(_handle), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Read up to `count` bytes. Returns `{:ok, binary}` (possibly shorter than
  `count`, including empty on EOF) or `{:error, errno_atom}`.

  Runs inline on a normal scheduler, so it assumes a fast fd: a usbfs node
  (descriptor reads return immediately) or the netlink uevent socket paired with
  `select_read/2` (only read when readiness fired). Do not point it at a fd whose
  read can block indefinitely (a pipe, a socket with no data) or it will stall a
  scheduler thread.
  """
  @spec read(handle(), non_neg_integer()) :: {:ok, binary()} | {:error, atom()}
  def read(_handle, _count), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Write `data`. Returns `{:ok, bytes_written}` or `{:error, errno_atom}`. Like
  `read/2`, runs inline and assumes a non-blocking fd.
  """
  @spec write(handle(), iodata()) :: {:ok, non_neg_integer()} | {:error, atom()}
  def write(_handle, _data), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Issue a usbfs control transfer (`USBDEVFS_CONTROL`).

  Direction is taken from bit 7 of `request_type`:

    * IN  (`0x80` set): `data_or_length` is the number of bytes to read;
      returns `{:ok, binary}` with what the device returned (may be shorter).
    * OUT (`0x80` clear): `data_or_length` is the payload (iodata);
      returns `{:ok, bytes_written}`.

  `timeout_ms` is the transfer timeout in milliseconds (`0` = no timeout). The
  data buffer is bounded by `wLength` (0..65535); oversized requests raise
  `ArgumentError` before any syscall. Runs on a dirty I/O scheduler.

  Prefer `control_in/6` and `control_out/6` for readability.
  """
  @spec control_transfer(
          handle(),
          0..255,
          0..255,
          0..0xFFFF,
          0..0xFFFF,
          iodata() | non_neg_integer(),
          non_neg_integer()
        ) :: {:ok, binary()} | {:ok, non_neg_integer()} | {:error, atom()}
  def control_transfer(_h, _request_type, _request, _value, _index, _data_or_length, _timeout_ms),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc "Control IN transfer. Returns `{:ok, binary}` of up to `length` bytes."
  @spec control_in(handle(), 0..255, 0..0xFFFF, 0..0xFFFF, non_neg_integer(), non_neg_integer()) ::
          {:ok, binary()} | {:error, atom()}
  def control_in(h, request, value, index, length, timeout_ms \\ 1000) do
    control_transfer(h, 0x80, request, value, index, length, timeout_ms)
  end

  @doc "Control OUT transfer. Returns `{:ok, bytes_written}`."
  @spec control_out(handle(), 0..255, 0..0xFFFF, 0..0xFFFF, iodata(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, atom()}
  def control_out(h, request, value, index, data, timeout_ms \\ 1000) do
    control_transfer(h, 0x00, request, value, index, data, timeout_ms)
  end

  @doc """
  Issue a usbfs bulk transfer (`USBDEVFS_BULK`).

  Direction is taken from bit 7 of `endpoint`:

    * IN  (`0x80` set): `data_or_length` is the number of bytes to read;
      returns `{:ok, binary}`.
    * OUT (`0x80` clear): `data_or_length` is the payload (iodata);
      returns `{:ok, bytes_written}`.

  The interface owning the endpoint must be claimed first (see
  `claim_interface/2`). Runs on a dirty I/O scheduler.

  Prefer `bulk_in/4` and `bulk_out/4`.
  """
  @spec bulk_transfer(handle(), 0..255, iodata() | non_neg_integer(), non_neg_integer()) ::
          {:ok, binary()} | {:ok, non_neg_integer()} | {:error, atom()}
  def bulk_transfer(_h, _endpoint, _data_or_length, _timeout_ms),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc "Bulk IN transfer on an IN endpoint address (bit 7 set). Returns `{:ok, binary}`."
  @spec bulk_in(handle(), 0..255, non_neg_integer(), non_neg_integer()) ::
          {:ok, binary()} | {:error, atom()}
  def bulk_in(h, endpoint, length, timeout_ms \\ 1000),
    do: bulk_transfer(h, endpoint, length, timeout_ms)

  @doc "Bulk OUT transfer on an OUT endpoint address (bit 7 clear). Returns `{:ok, bytes_written}`."
  @spec bulk_out(handle(), 0..255, iodata(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, atom()}
  def bulk_out(h, endpoint, data, timeout_ms \\ 1000),
    do: bulk_transfer(h, endpoint, data, timeout_ms)

  @doc """
  Claim an interface (`USBDEVFS_CLAIMINTERFACE`) so its endpoints can be used
  for transfers. Fast; runs inline.
  """
  @spec claim_interface(handle(), non_neg_integer()) :: :ok | {:error, atom()}
  def claim_interface(_h, _interface), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Release a claimed interface (`USBDEVFS_RELEASEINTERFACE`). Fast; runs inline."
  @spec release_interface(handle(), non_neg_integer()) :: :ok | {:error, atom()}
  def release_interface(_h, _interface), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Name of the kernel driver bound to an interface (`USBDEVFS_GETDRIVER`), or
  `{:error, :enodata}` if none is bound.
  """
  @spec get_driver(handle(), non_neg_integer()) :: {:ok, binary()} | {:error, atom()}
  def get_driver(_h, _interface), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Detach the kernel driver from an interface (`USBDEVFS_DISCONNECT` via
  `USBDEVFS_IOCTL`) so it can be claimed. Runs on a dirty I/O scheduler.
  """
  @spec detach_driver(handle(), non_neg_integer()) :: :ok | {:error, atom()}
  def detach_driver(_h, _interface), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Reattach the kernel driver to an interface (`USBDEVFS_CONNECT` via
  `USBDEVFS_IOCTL`). Runs on a dirty I/O scheduler.
  """
  @spec attach_driver(handle(), non_neg_integer()) :: :ok | {:error, atom()}
  def attach_driver(_h, _interface), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Clear an endpoint's halt/stall condition (`USBDEVFS_CLEAR_HALT`), the recovery
  after a transfer fails with `:epipe`. Runs on a dirty I/O scheduler.
  """
  @spec clear_halt(handle(), 0..255) :: :ok | {:error, atom()}
  def clear_halt(_h, _endpoint), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Reset the device (`USBDEVFS_RESET`). The device re-enumerates and may return
  with a new address, so this handle can become stale afterwards. Runs on a
  dirty I/O scheduler.
  """
  @spec reset(handle()) :: :ok | {:error, atom()}
  def reset(_h), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Select an alternate setting for an interface (`USBDEVFS_SETINTERFACE`).
  Runs on a dirty I/O scheduler.
  """
  @spec set_interface(handle(), non_neg_integer(), non_neg_integer()) :: :ok | {:error, atom()}
  def set_interface(_h, _interface, _altsetting), do: :erlang.nif_error(:nif_not_loaded)

  # ---- async engine primitives (B5) --------------------------------------

  # USBDEVFS_URB_TYPE_* codes and flags.
  @urb_type_interrupt 1
  @urb_type_bulk 3
  @urb_zero_packet 0x40

  @doc """
  Submit a URB asynchronously (`USBDEVFS_SUBMITURB`). Returns immediately.
  `urb_type` is `USBDEVFS_URB_TYPE_BULK` (3) or `_INTERRUPT` (1). `tag` is a
  caller-chosen 64-bit id echoed back by `reap/1`. Direction is bit 7 of
  `endpoint`; IN takes a length, OUT takes iodata. `flags` may include
  `0x40` (`USBDEVFS_URB_ZERO_PACKET`) to append a terminating zero-length packet
  on an OUT transfer. The interface must be claimed. Pair with `select/2` +
  `reap/1`. Prefer `submit_bulk/4` and `submit_interrupt/4`.
  """
  @spec submit_urb(
          handle(),
          non_neg_integer(),
          1..3,
          0..255,
          iodata() | non_neg_integer(),
          0..0x40
        ) ::
          :ok | {:error, atom()}
  def submit_urb(_h, _tag, _urb_type, _endpoint, _data_or_length, _flags),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc "Submit a bulk URB. `opts[:zero_packet]` appends a terminating ZLP (OUT)."
  @spec submit_bulk(handle(), non_neg_integer(), 0..255, iodata() | non_neg_integer(), keyword()) ::
          :ok | {:error, atom()}
  def submit_bulk(h, tag, endpoint, data_or_length, opts \\ []),
    do: submit_urb(h, tag, @urb_type_bulk, endpoint, data_or_length, flags(opts))

  @doc "Submit an interrupt URB. See `submit_bulk/5`."
  @spec submit_interrupt(
          handle(),
          non_neg_integer(),
          0..255,
          iodata() | non_neg_integer(),
          keyword()
        ) ::
          :ok | {:error, atom()}
  def submit_interrupt(h, tag, endpoint, data_or_length, opts \\ []),
    do: submit_urb(h, tag, @urb_type_interrupt, endpoint, data_or_length, flags(opts))

  defp flags(opts), do: if(opts[:zero_packet], do: @urb_zero_packet, else: 0)

  @doc """
  Submit a control transfer as an async URB (`USBDEVFS_URB_TYPE_CONTROL`) so the
  caller never blocks a scheduler on it. Direction is bit 7 of `request_type`
  (`0x80` = IN): IN takes a read length and reaps as `{tag, status, binary}`; OUT
  takes iodata and reaps as `{tag, status, bytes_written}`. Pair with `select/2`
  + `reap/1`; the `CircuitsUsb.Transfer` engine drives this. For a one-shot
  synchronous control transfer use `control_transfer/7` instead.
  """
  @spec submit_control(
          handle(),
          non_neg_integer(),
          0..255,
          0..255,
          0..0xFFFF,
          0..0xFFFF,
          iodata() | non_neg_integer()
        ) :: :ok | {:error, atom()}
  def submit_control(_h, _tag, _request_type, _request, _value, _index, _data_or_length),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Submit an isochronous URB (`USBDEVFS_URB_TYPE_ISO`, scheduled ASAP).
  `packet_lengths` is the list of per-packet byte counts (its length is the
  packet count, its sum the total buffer). For IN, `data` is ignored; for OUT it
  must be exactly the total. `reap/1` returns the completion as
  `{tag, status, {:iso, data_or_bytes, [{actual_length, packet_status}, ...]}}`.
  """
  @spec submit_iso(handle(), non_neg_integer(), 0..255, [0..0xFFFF], iodata() | nil) ::
          :ok | {:error, atom()}
  def submit_iso(_h, _tag, _endpoint, _packet_lengths, _data),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Arm readiness notification: usbfs signals `POLLOUT` when a URB is reapable.
  The calling process receives `{:select, handle, ref, :ready_output}`. Re-arm
  after each `reap/1` while URBs remain in flight.
  """
  @spec select(handle(), reference()) :: :ok | {:error, atom()}
  def select(_h, _ref), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Drain all currently-completed URBs (`USBDEVFS_REAPURBNDELAY`). Returns a list
  of `{tag, status, payload}` where `status` is `:ok` or an errno atom, and
  `payload` is the received binary (IN) or bytes written (OUT).
  """
  @spec reap(handle()) :: [{non_neg_integer(), :ok | atom(), binary() | non_neg_integer()}]
  def reap(_h), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Cancel an in-flight URB by `tag` (`USBDEVFS_DISCARDURB`). It still completes
  (with a reset status) and is returned by the next `reap/1`.
  """
  @spec discard(handle(), non_neg_integer()) :: :ok | {:error, atom()}
  def discard(_h, _tag), do: :erlang.nif_error(:nif_not_loaded)

  # ---- hotplug (netlink uevents) -----------------------------------------

  @doc """
  Open a `NETLINK_KOBJECT_UEVENT` socket bound to the kernel uevent broadcast
  group. `read/2` returns one uevent datagram (NUL-separated `key=value`
  fields); `select_read/2` signals read-readiness. Usually needs root.

  Note: `read/2` cannot verify the sender, so datagrams are trusted to come
  from the kernel (group 1). Sending to that group requires `CAP_NET_ADMIN`,
  so this matches udev's threat model, but a hardened consumer would switch to
  `recvmsg` and check `nl_pid == 0` before trusting an event.
  """
  @spec netlink_uevent_open() :: {:ok, handle()} | {:error, atom()}
  def netlink_uevent_open(), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Arm read-readiness (`POLLIN`) notification on a handle (e.g. the uevent
  socket). The calling process receives `{:select, handle, ref, :ready_input}`.
  """
  @spec select_read(handle(), reference()) :: :ok | {:error, atom()}
  def select_read(_h, _ref), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  The underlying integer fd, or `{:error, :ebadf}` if closed. Diagnostic aid
  (used by tests to assert descriptors are actually released).
  """
  @spec fileno(handle()) :: integer() | {:error, :ebadf}
  def fileno(_handle), do: :erlang.nif_error(:nif_not_loaded)
end
