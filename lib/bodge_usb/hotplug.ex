# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0

defmodule BodgeUSB.Hotplug do
  @moduledoc false

  # USB hotplug watcher: reads the kernel NETLINK_KOBJECT_UEVENT broadcast
  # socket and delivers device-level add/remove events to subscribers as
  # {:usb_hotplug, event} messages. Start it via BodgeUSB.watch_hotplug/1,
  # which documents the event shape. Only device-level USB events
  # (SUBSYSTEM=usb, DEVTYPE=usb_device) are reported.

  use GenServer

  alias BodgeUSB.Nif

  require Logger

  @type event :: %{
          action: :add | :remove | :bind | :unbind | :change | :unknown,
          busnum: integer() | nil,
          devnum: integer() | nil,
          devname: String.t() | nil,
          devpath: String.t() | nil,
          product: String.t() | nil
        }

  # The socket is opened before the watcher is started, so a failed open (no
  # root, typically) returns {:error, reason} without starting a process to
  # crash a non-trapping caller through the link.
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    subscribers = opts |> Keyword.get(:notify, self()) |> List.wrap()

    with {:ok, handle} <- Nif.netlink_uevent_open() do
      GenServer.start_link(__MODULE__, {handle, subscribers}, Keyword.take(opts, [:name]))
    end
  end

  @spec stop(GenServer.server()) :: :ok
  def stop(server), do: GenServer.stop(server)

  # ---- server ------------------------------------------------------------

  @impl true
  def init({handle, subscribers}) do
    Enum.each(subscribers, &Process.monitor/1)
    {:ok, arm(%{handle: handle, ref: make_ref(), subscribers: MapSet.new(subscribers)})}
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
    Nif.close(state.handle)
    :ok
  end

  # ---- internal ----------------------------------------------------------

  # One uevent per datagram; read until EAGAIN. netlink_read/2 verifies the
  # kernel is the sender and drops anything else as an empty payload.
  defp drain(handle, acc) do
    case Nif.netlink_read(handle, 8192) do
      {:ok, data} when byte_size(data) > 0 ->
        case parse_uevent(data) do
          {:ok, event} -> drain(handle, [event | acc])
          :skip -> drain(handle, acc)
        end

      # A dropped (non-kernel) datagram: keep draining so a forged event cannot
      # mask the real ones queued behind it. EAGAIN, not an empty read, ends the
      # drain on this non-blocking socket.
      {:ok, _dropped} ->
        drain(handle, acc)

      {:error, :eagain} ->
        Enum.reverse(acc)

      {:error, reason} ->
        # ENOBUFS means the kernel dropped uevents on socket overrun; anything
        # else is equally worth surfacing -- never swallow it silently.
        Logger.warning(
          "BodgeUSB.Hotplug: uevent read failed: #{inspect(reason)} " <>
            "(events may have been lost)"
        )

        Enum.reverse(acc)
    end
  end

  defp arm(state) do
    case Nif.select_read(state.handle, state.ref) do
      :ok ->
        :ok

      {:error, reason} ->
        # The watcher would otherwise go silently deaf.
        Logger.warning("BodgeUSB.Hotplug: select_read failed: #{inspect(reason)}")
    end

    state
  end

  defp broadcast(state, event) do
    Enum.each(state.subscribers, &send(&1, {:usb_hotplug, event}))
  end

  @doc false
  # A uevent datagram is a header line then NUL-separated key=value fields.
  # Public for the fuzz suite.
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
