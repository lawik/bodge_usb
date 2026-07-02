defmodule CircuitsUsb.Shim do
  @moduledoc """
  Low-level usbfs syscall shim (Part B1).

  A deliberately narrow NIF over a single file descriptor: `open/2`, `close/1`,
  `read/2`, `write/2`. The descriptor is held in a NIF resource whose destructor
  closes it, so a handle that goes out of scope and is garbage collected never
  leaks an fd.

  This is the bottom layer. Higher layers (enumeration, the transfer engine, the
  public API) build on top of it; application code should not normally use it
  directly.

  All calls return `{:error, errno_atom}` on failure, where `errno_atom` is the
  captured `errno` as an atom (`:enoent`, `:eacces`, `:enodev`, ...), or `:eNNN`
  for errnos without a dedicated name.
  """

  import Bitwise

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
  """
  @spec close(handle()) :: :ok | {:error, atom()}
  def close(_handle), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Read up to `count` bytes. Returns `{:ok, binary}` (possibly shorter than
  `count`, including empty on EOF) or `{:error, errno_atom}`.
  """
  @spec read(handle(), non_neg_integer()) :: {:ok, binary()} | {:error, atom()}
  def read(_handle, _count), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Write `data`. Returns `{:ok, bytes_written}` or `{:error, errno_atom}`.
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

  @doc "Bulk IN transfer. Returns `{:ok, binary}` of up to `length` bytes."
  @spec bulk_in(handle(), 0..255, non_neg_integer(), non_neg_integer()) ::
          {:ok, binary()} | {:error, atom()}
  def bulk_in(h, endpoint, length, timeout_ms \\ 1000),
    do: bulk_transfer(h, endpoint ||| 0x80, length, timeout_ms)

  @doc "Bulk OUT transfer. Returns `{:ok, bytes_written}`."
  @spec bulk_out(handle(), 0..255, iodata(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, atom()}
  def bulk_out(h, endpoint, data, timeout_ms \\ 1000),
    do: bulk_transfer(h, endpoint &&& 0x7F, data, timeout_ms)

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
  Select an alternate setting for an interface (`USBDEVFS_SETINTERFACE`).
  Runs on a dirty I/O scheduler.
  """
  @spec set_interface(handle(), non_neg_integer(), non_neg_integer()) :: :ok | {:error, atom()}
  def set_interface(_h, _interface, _altsetting), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  The underlying integer fd, or `{:error, :ebadf}` if closed. Diagnostic aid
  (used by tests to assert descriptors are actually released).
  """
  @spec fileno(handle()) :: integer() | {:error, :ebadf}
  def fileno(_handle), do: :erlang.nif_error(:nif_not_loaded)
end
