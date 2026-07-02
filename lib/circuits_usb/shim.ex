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
  The underlying integer fd, or `{:error, :ebadf}` if closed. Diagnostic aid
  (used by tests to assert descriptors are actually released).
  """
  @spec fileno(handle()) :: integer() | {:error, :ebadf}
  def fileno(_handle), do: :erlang.nif_error(:nif_not_loaded)
end
