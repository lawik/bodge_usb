defmodule CircuitsUsb.FunctionFs do
  @moduledoc """
  Custom USB device functions over FunctionFS.

  Where `CircuitsUsb.Gadget` covers the device classes the kernel implements,
  FunctionFS is for functions the kernel does *not* know: your own protocol,
  served from Elixir. The kernel handles enumeration and the composite
  plumbing; SETUP requests for this function arrive here as events, and the
  function's endpoints are files.

  ## Lifecycle

      # 1. A gadget with an ffs function (instance name "netmd"):
      {:ok, g} = Gadget.define("player", %{functions: %{"ffs.netmd" => %{}}, ...})

      # 2. Mount the instance and start the function:
      :ok = FunctionFs.mount("netmd", "/dev/ffs-netmd")

      {:ok, fun} =
        FunctionFs.start_link(
          mountpoint: "/dev/ffs-netmd",
          function: %{
            interface: %{class: 0xFF},
            endpoints: [%{address: 0x01, type: :bulk}, %{address: 0x81, type: :bulk}],
            flags: [:all_ctrl_recip]
          },
          strings: ["NetMD"],
          handler: &MyProtocol.handle_setup/2
        )

      # 3. Only now can the gadget bind (FunctionFS must have its descriptors):
      :ok = Gadget.bind(g, udc)

  ## Control transfers: the handler

  `handler` is a 2-arity fun called in the server for each SETUP aimed at this
  function (`flags: [:all_ctrl_recip]` includes device-recipient requests):

    * IN (`setup.request_type >= 0x80`): called as `handler.(setup, nil)`;
      return `{:reply, iodata}` (truncated to `wLength`) or `:stall`.
    * OUT: the data stage (`wLength` bytes) is read first and the transfer
      thereby accepted, then `handler.(setup, data)` is called; the return
      value is ignored. (v1 limitation: OUT requests cannot be stalled.)

  A crashing handler stalls the request and the server keeps running.

  ## Everything else

  Lifecycle events are sent to `opts[:notify]` (default: the caller) as
  `{:functionfs, server, :bound | :enabled | :disabled | :unbound | :suspend |
  :resume}`. `:enabled` means the host configured the device: endpoints are
  live from that point.

  Endpoint I/O: `open_endpoint/2` opens `epN` (numbered in declaration order,
  from 1). These files *block* until the host transacts and are not pollable,
  so drive them with `CircuitsUsb.Shim.read_blocking/2` and
  `write_blocking/2` from their own process (a `Task` per direction is the
  usual shape); each in-flight call occupies a dirty I/O scheduler. Unbinding
  the gadget unblocks them with `{:error, :eshutdown}`.
  """

  use GenServer

  alias CircuitsUsb.FunctionFs.Descriptors
  alias CircuitsUsb.Shim

  require Logger

  @typedoc "A decoded SETUP request."
  @type setup :: %{
          request_type: 0..0xFF,
          request: 0..0xFF,
          value: 0..0xFFFF,
          index: 0..0xFFFF,
          length: 0..0xFFFF
        }

  @typedoc "The control-request handler. See the moduledoc for the contract."
  @type handler :: (setup(), binary() | nil -> {:reply, iodata()} | :stall | :ok)

  # include/uapi/linux/usb/functionfs.h event types.
  @event_names %{
    0 => :bound,
    1 => :unbound,
    2 => :enabled,
    3 => :disabled,
    4 => :setup,
    5 => :suspend,
    6 => :resume
  }

  @doc """
  Mount a FunctionFS instance (the `NAME` of an `ffs.NAME` gadget function) at
  `mountpoint`, creating the directory if needed. Needs root.
  """
  @spec mount(String.t(), Path.t()) :: :ok | {:error, term()}
  def mount(instance, mountpoint) do
    with :ok <- File.mkdir_p(mountpoint) do
      case System.cmd("mount", ["-t", "functionfs", instance, mountpoint], stderr_to_stdout: true) do
        {_out, 0} -> :ok
        {out, status} -> {:error, {:mount_failed, status, String.trim(out)}}
      end
    end
  end

  @doc "Unmount a FunctionFS instance."
  @spec umount(Path.t()) :: :ok | {:error, term()}
  def umount(mountpoint) do
    case System.cmd("umount", [mountpoint], stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, status} -> {:error, {:umount_failed, status, String.trim(out)}}
    end
  end

  @doc """
  Start the function: opens `ep0` under `opts[:mountpoint]`, writes the
  descriptor and string blobs (built from `opts[:function]`, a
  `t:CircuitsUsb.FunctionFs.Descriptors.spec/0`, and `opts[:strings]`), and
  serves SETUP events with `opts[:handler]`. After this returns, the gadget
  can be bound. `opts[:notify]` (default: the caller) receives lifecycle
  events; `opts[:name]` optionally names the server.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    opts = Keyword.put_new(opts, :notify, self())
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @spec stop(GenServer.server()) :: :ok
  def stop(server), do: GenServer.stop(server)

  @doc """
  Open endpoint file `epN` for the function at `mountpoint`. Endpoints are
  numbered in descriptor declaration order, starting at 1. Returns a shim
  handle for `Shim.read_blocking/2` / `Shim.write_blocking/2`.
  """
  @spec open_endpoint(Path.t(), pos_integer()) :: {:ok, Shim.handle()} | {:error, atom()}
  def open_endpoint(mountpoint, n) when is_integer(n) and n >= 1 do
    Shim.open(Path.join(mountpoint, "ep#{n}"), [:rdwr])
  end

  # ---- server ------------------------------------------------------------

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    mountpoint = Keyword.fetch!(opts, :mountpoint)
    function = Keyword.fetch!(opts, :function)
    handler = Keyword.fetch!(opts, :handler)
    strings = Keyword.get(opts, :strings, [])
    langid = Keyword.get(opts, :langid, 0x0409)

    with {:ok, handle} <- Shim.open(Path.join(mountpoint, "ep0"), [:rdwr]),
         :ok <- write_blob(handle, Descriptors.descriptors(function)),
         :ok <- write_blob(handle, Descriptors.strings(strings, langid)) do
      state = %{
        handle: handle,
        ref: make_ref(),
        handler: handler,
        notify: Keyword.fetch!(opts, :notify)
      }

      {:ok, arm(state)}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_info({:select, _handle, ref, :ready_input}, %{ref: ref} = state) do
    # One 12-byte event per readiness cycle; re-arming immediately fires again
    # while more events are queued, and a SETUP leaves ep0 expecting its data
    # stage as the *next* I/O, so single-event reads keep the state machine
    # unambiguous.
    case Shim.read_blocking(state.handle, 12) do
      {:ok, <<setup_raw::binary-size(8), type, _pad::binary-size(3)>>} ->
        handle_event(Map.get(@event_names, type, {:unknown, type}), setup_raw, state)

      {:ok, _short} ->
        :ok

      {:error, reason} ->
        Logger.warning("CircuitsUsb.FunctionFs: ep0 event read failed: #{inspect(reason)}")
    end

    {:noreply, arm(state)}
  end

  def handle_info({:select, _handle, _stale_ref, _}, state), do: {:noreply, state}

  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}

  @impl true
  def terminate(_reason, state) do
    Shim.close(state.handle)
    :ok
  end

  # ---- events --------------------------------------------------------------

  defp handle_event(:setup, setup_raw, state) do
    <<request_type, request, value::little-16, index::little-16, length::little-16>> = setup_raw

    setup = %{
      request_type: request_type,
      request: request,
      value: value,
      index: index,
      length: length
    }

    if request_type >= 0x80 do
      handle_setup_in(setup, state)
    else
      handle_setup_out(setup, state)
    end
  end

  defp handle_event({:unknown, type}, _setup_raw, _state) do
    Logger.warning("CircuitsUsb.FunctionFs: unknown ep0 event type #{type}")
  end

  defp handle_event(event, _setup_raw, state) do
    send(state.notify, {:functionfs, self(), event})
  end

  # IN: the handler produces the data stage (or refuses); writing is the
  # response, reading in the wrong direction is the documented stall.
  defp handle_setup_in(setup, state) do
    case run_handler(state.handler, setup, nil) do
      {:reply, iodata} ->
        data = IO.iodata_to_binary(iodata)
        reply = binary_part(data, 0, min(byte_size(data), setup.length))
        checked(Shim.write_blocking(state.handle, reply), "control IN reply")

      _stall ->
        _ = Shim.read_blocking(state.handle, 1)
        :ok
    end
  end

  # OUT: reading the data stage accepts the transfer (a zero-length read acks
  # a dataless request), then the handler sees the payload.
  defp handle_setup_out(setup, state) do
    case checked(Shim.read_blocking(state.handle, setup.length), "control OUT data") do
      {:ok, data} -> run_handler(state.handler, setup, data)
      _error -> :ok
    end
  end

  defp run_handler(handler, setup, data) do
    handler.(setup, data)
  rescue
    e ->
      Logger.warning(
        "CircuitsUsb.FunctionFs: handler crashed on #{inspect(setup)}: #{inspect(e)}"
      )

      :stall
  end

  defp checked({:error, reason} = error, what) do
    Logger.warning("CircuitsUsb.FunctionFs: #{what} failed: #{inspect(reason)}")
    error
  end

  defp checked(ok, _what), do: ok

  defp write_blob(handle, blob) do
    case Shim.write(handle, blob) do
      {:ok, n} when n == byte_size(blob) -> :ok
      {:ok, n} -> {:error, {:short_blob_write, n, byte_size(blob)}}
      {:error, _} = err -> err
    end
  end

  defp arm(state) do
    case Shim.select_read(state.handle, state.ref) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("CircuitsUsb.FunctionFs: select_read failed: #{inspect(reason)}")
    end

    state
  end
end
