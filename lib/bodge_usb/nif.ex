# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0

defmodule BodgeUSB.Nif do
  @moduledoc false

  # Raw usbfs syscall shim. Internal; the public surface is `BodgeUSB`.
  #
  # A deliberately narrow NIF over a single file descriptor: open/close/read/
  # write, the fixed usbfs ioctls, the async URB primitives (submit_* ->
  # select -> reap -> discard), and the netlink uevent socket for hotplug.
  # The descriptor is held in a NIF resource whose destructor closes it, so a
  # handle that goes out of scope and is garbage collected never leaks an fd.
  #
  # All calls return {:error, errno_atom} on failure, where errno_atom is the
  # captured errno as an atom (:enoent, :eacces, :enodev, ...), or :eNNN for
  # errnos without a dedicated name.
  #
  # The async URB discipline (BodgeUSB runs this loop):
  #   * after submit_*, arm select/2; the poller sends
  #     {:select, handle, ref, :ready_output} when a completion is reapable;
  #   * drain with reap/1 (non-blocking, returns every completed URB), then
  #     re-arm select/2 while URBs remain in flight;
  #   * close/1 (or GC of the handle) cancels everything in flight.

  @type handle :: reference()
  @type open_flag :: :rdonly | :wronly | :rdwr | :nonblock

  @on_load :load_nif
  @doc false
  @spec load_nif() :: :ok | {:error, {atom(), charlist()}}
  def load_nif() do
    path = :filename.join(:code.priv_dir(:bodge_usb), ~c"bodge_usb_nif")
    :erlang.load_nif(path, 0)
  end

  # Open path (O_CLOEXEC always set; defaults to O_RDWR).
  @spec open(binary() | charlist(), [open_flag()]) :: {:ok, handle()} | {:error, atom()}
  def open(path, flags \\ [:rdwr])
  def open(path, flags) when is_list(path), do: open(IO.iodata_to_binary(path), flags)
  def open(_path, _flags), do: :erlang.nif_error(:nif_not_loaded)

  # Idempotent. If a blocking ioctl is mid-flight the fd teardown is deferred
  # until it finishes; new operations are refused from this call onward.
  @spec close(handle()) :: :ok
  def close(_handle), do: :erlang.nif_error(:nif_not_loaded)

  # Inline read for fast fds (usbfs descriptor reads). May return short.
  @spec read(handle(), non_neg_integer()) :: {:ok, binary()} | {:error, atom()}
  def read(_handle, _count), do: :erlang.nif_error(:nif_not_loaded)

  # Inline write; assumes a fast or non-blocking fd.
  @spec write(handle(), iodata()) :: {:ok, non_neg_integer()} | {:error, atom()}
  def write(_handle, _data), do: :erlang.nif_error(:nif_not_loaded)

  # ---- usbfs ioctls --------------------------------------------------------

  @spec claim_interface(handle(), non_neg_integer()) :: :ok | {:error, atom()}
  def claim_interface(_h, _interface), do: :erlang.nif_error(:nif_not_loaded)

  @spec release_interface(handle(), non_neg_integer()) :: :ok | {:error, atom()}
  def release_interface(_h, _interface), do: :erlang.nif_error(:nif_not_loaded)

  # {:error, :enodata} when no driver is bound.
  @spec get_driver(handle(), non_neg_integer()) :: {:ok, binary()} | {:error, atom()}
  def get_driver(_h, _interface), do: :erlang.nif_error(:nif_not_loaded)

  @spec detach_driver(handle(), non_neg_integer()) :: :ok | {:error, atom()}
  def detach_driver(_h, _interface), do: :erlang.nif_error(:nif_not_loaded)

  @spec attach_driver(handle(), non_neg_integer()) :: :ok | {:error, atom()}
  def attach_driver(_h, _interface), do: :erlang.nif_error(:nif_not_loaded)

  @spec clear_halt(handle(), 0..255) :: :ok | {:error, atom()}
  def clear_halt(_h, _endpoint), do: :erlang.nif_error(:nif_not_loaded)

  # The device re-enumerates; the handle may be stale afterwards.
  @spec reset(handle()) :: :ok | {:error, atom()}
  def reset(_h), do: :erlang.nif_error(:nif_not_loaded)

  @spec set_interface(handle(), non_neg_integer(), non_neg_integer()) :: :ok | {:error, atom()}
  def set_interface(_h, _interface, _altsetting), do: :erlang.nif_error(:nif_not_loaded)

  # ---- async URB primitives --------------------------------------------

  # USBDEVFS_URB_TYPE_* codes and flags.
  @urb_type_interrupt 1
  @urb_type_bulk 3
  @urb_zero_packet 0x40

  # Submit a bulk/interrupt URB (USBDEVFS_SUBMITURB); returns immediately.
  # tag is a caller-chosen 64-bit id echoed back by reap/1. Direction is bit 7
  # of endpoint: IN takes a length, OUT takes iodata.
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

  @spec submit_bulk(handle(), non_neg_integer(), 0..255, iodata() | non_neg_integer(), keyword()) ::
          :ok | {:error, atom()}
  def submit_bulk(h, tag, endpoint, data_or_length, opts \\ []),
    do: submit_urb(h, tag, @urb_type_bulk, endpoint, data_or_length, flags(opts))

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

  # Submit a control transfer as an async URB (USBDEVFS_URB_TYPE_CONTROL).
  # Direction is bit 7 of request_type (0x80 = IN): IN takes a read length and
  # reaps as {tag, status, binary}; OUT takes iodata and reaps as
  # {tag, status, bytes_written}.
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

  # Submit an isochronous URB (USBDEVFS_URB_TYPE_ISO, scheduled ASAP).
  # packet_lengths is the per-packet byte counts (its length is the packet
  # count, its sum the total buffer). For IN, data is ignored; for OUT it must
  # be exactly the total. Reaps as
  # {tag, status, {:iso, data_or_bytes, [{actual_length, packet_status}]}},
  # where iso IN data is the RAW kernel buffer: each packet's bytes at its
  # requested-length offset, zero-filled gaps (BodgeUSB compacts it).
  @spec submit_iso(handle(), non_neg_integer(), 0..255, [0..0xFFFF], iodata() | nil) ::
          :ok | {:error, atom()}
  def submit_iso(_h, _tag, _endpoint, _packet_lengths, _data),
    do: :erlang.nif_error(:nif_not_loaded)

  # Arm readiness notification: usbfs signals POLLOUT when a URB is reapable.
  # The calling process receives {:select, handle, ref, :ready_output}.
  @spec select(handle(), reference()) :: :ok | {:error, atom()}
  def select(_h, _ref), do: :erlang.nif_error(:nif_not_loaded)

  # Drain all currently-completed URBs (USBDEVFS_REAPURBNDELAY). Returns
  # {tag, status, payload} tuples where status is :ok or an errno atom.
  @spec reap(handle()) :: [{non_neg_integer(), :ok | atom(), term()}]
  def reap(_h), do: :erlang.nif_error(:nif_not_loaded)

  # Cancel an in-flight URB by tag (USBDEVFS_DISCARDURB). It still completes
  # (with a reset status) and is returned by the next reap/1.
  @spec discard(handle(), non_neg_integer()) :: :ok | {:error, atom()}
  def discard(_h, _tag), do: :erlang.nif_error(:nif_not_loaded)

  # ---- hotplug (netlink uevents) -----------------------------------------

  # Open a NETLINK_KOBJECT_UEVENT socket bound to the kernel uevent broadcast
  # group. Pair with netlink_read/2 and select_read/2. Usually needs root.
  @spec netlink_uevent_open() :: {:ok, handle()} | {:error, atom()}
  def netlink_uevent_open(), do: :erlang.nif_error(:nif_not_loaded)

  # Read one uevent datagram via recvmsg, verifying the kernel sent it
  # (source nl_pid == 0, as libudev does). A datagram from a user process is
  # dropped and returned as {:ok, <<>>}. Non-blocking: {:error, :eagain} once
  # drained.
  @spec netlink_read(handle(), non_neg_integer()) :: {:ok, binary()} | {:error, atom()}
  def netlink_read(_handle, _count), do: :erlang.nif_error(:nif_not_loaded)

  # Arm read-readiness (POLLIN) notification; the calling process receives
  # {:select, handle, ref, :ready_input}.
  @spec select_read(handle(), reference()) :: :ok | {:error, atom()}
  def select_read(_h, _ref), do: :erlang.nif_error(:nif_not_loaded)

  # Test aid: the underlying integer fd, to assert descriptors are released.
  @spec fileno(handle()) :: integer() | {:error, :ebadf}
  def fileno(_handle), do: :erlang.nif_error(:nif_not_loaded)
end
