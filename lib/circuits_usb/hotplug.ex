defmodule CircuitsUsb.Hotplug do
  @moduledoc """
  USB hotplug notifications (Part B10).

  Watches the kernel `NETLINK_KOBJECT_UEVENT` broadcast socket and delivers
  device add/remove events to subscribers as `{:usb_hotplug, event}` messages,
  where `event` is a map:

      %{action: :add | :remove | :bind | :unbind | :change,
        busnum: integer | nil, devnum: integer | nil,
        devname: "/dev/bus/usb/BBB/DDD" | nil, devpath: String.t(), product: String.t() | nil}

  Only device-level USB events (`SUBSYSTEM=usb`, `DEVTYPE=usb_device`) are
  reported. Opening the socket usually needs root.
  """

  use GenServer

  alias CircuitsUsb.Shim

  require Logger

  @type event :: %{
          action: :add | :remove | :bind | :unbind | :change | :unknown,
          busnum: integer() | nil,
          devnum: integer() | nil,
          devname: String.t() | nil,
          devpath: String.t() | nil,
          product: String.t() | nil
        }

  @doc """
  Start watching. `:notify` (a pid or list of pids) receives events; defaults to
  the caller. `:name` optionally names the server.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    opts = Keyword.put_new(opts, :notify, self())
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc "Add a subscriber pid."
  @spec subscribe(GenServer.server(), pid()) :: :ok
  def subscribe(server, pid \\ self()), do: GenServer.call(server, {:subscribe, pid})

  @spec stop(GenServer.server()) :: :ok
  def stop(server), do: GenServer.stop(server)

  # ---- server ------------------------------------------------------------

  @impl true
  def init(opts) do
    case Shim.netlink_uevent_open() do
      {:ok, handle} ->
        subscribers = opts |> Keyword.fetch!(:notify) |> List.wrap()
        Enum.each(subscribers, &Process.monitor/1)
        {:ok, arm(%{handle: handle, ref: make_ref(), subscribers: MapSet.new(subscribers)})}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    Process.monitor(pid)
    {:reply, :ok, %{state | subscribers: MapSet.put(state.subscribers, pid)}}
  end

  @impl true
  def handle_info({:select, _handle, ref, :ready_input}, %{ref: ref} = state) do
    state.handle |> drain([]) |> Enum.each(&broadcast(state, &1))
    {:noreply, arm(state)}
  end

  # Stale select ref; ignore.
  def handle_info({:select, _handle, _other, _}, state), do: {:noreply, state}

  # Drop subscribers that have exited.
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state),
    do: {:noreply, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}

  @impl true
  def terminate(_reason, state) do
    Shim.close(state.handle)
    :ok
  end

  # ---- internal ----------------------------------------------------------

  # One uevent per datagram; read until EAGAIN.
  defp drain(handle, acc) do
    case Shim.read(handle, 8192) do
      {:ok, data} when byte_size(data) > 0 ->
        case parse_uevent(data) do
          {:ok, event} -> drain(handle, [event | acc])
          :skip -> drain(handle, acc)
        end

      _ ->
        Enum.reverse(acc)
    end
  end

  defp arm(state) do
    case Shim.select_read(state.handle, state.ref) do
      :ok ->
        :ok

      {:error, reason} ->
        # The watcher would otherwise go silently deaf.
        Logger.warning("CircuitsUsb.Hotplug: select_read failed: #{inspect(reason)}")
    end

    state
  end

  defp broadcast(state, event) do
    Enum.each(state.subscribers, &send(&1, {:usb_hotplug, event}))
  end

  @doc false
  # A uevent datagram is a header line then NUL-separated key=value fields.
  @spec parse_uevent(binary()) :: {:ok, event()} | :skip
  def parse_uevent(data) do
    fields =
      data
      |> :binary.split(<<0>>, [:global])
      |> Enum.reject(&(&1 == ""))

    map =
      for field <- fields,
          [key, value] <- [String.split(field, "=", parts: 2)],
          into: %{},
          do: {key, value}

    if map["SUBSYSTEM"] == "usb" and map["DEVTYPE"] == "usb_device" do
      {:ok,
       %{
         action: parse_action(map["ACTION"]),
         busnum: to_int(map["BUSNUM"]),
         devnum: to_int(map["DEVNUM"]),
         devname: devname(map["DEVNAME"]),
         devpath: map["DEVPATH"],
         product: map["PRODUCT"]
       }}
    else
      :skip
    end
  end

  defp parse_action("add"), do: :add
  defp parse_action("remove"), do: :remove
  defp parse_action("bind"), do: :bind
  defp parse_action("unbind"), do: :unbind
  defp parse_action("change"), do: :change
  defp parse_action(_), do: :unknown

  defp devname(nil), do: nil
  defp devname("/dev/" <> _ = full), do: full
  defp devname(rel), do: "/dev/" <> rel

  defp to_int(nil), do: nil

  defp to_int(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> nil
    end
  end
end
