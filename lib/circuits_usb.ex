defmodule CircuitsUsb do
  @moduledoc """
  Native USB for Erlang/Elixir on Linux, over a usbfs-scoped syscall NIF.

  This is the high-level, ergonomic entry point. It ties together device
  discovery (`CircuitsUsb.Enumeration`), the asynchronous transfer engine
  (`CircuitsUsb.Transfer`), and hotplug notifications (`CircuitsUsb.Hotplug`).

  ## Example

      # Find and open a device (starts a per-device transfer engine).
      {:ok, dev} = CircuitsUsb.open(0x0525, 0xA4A0)

      # Take an interface over from any bound kernel driver, then transfer.
      CircuitsUsb.detach_driver(dev, 0)
      :ok = CircuitsUsb.claim_interface(dev, 0)
      {:ok, data} = CircuitsUsb.bulk_in(dev, 0x81, 512)
      {:ok, _n} = CircuitsUsb.bulk_out(dev, 0x02, data)

      CircuitsUsb.close(dev)

  Watch for devices coming and going:

      {:ok, _hp} = CircuitsUsb.watch_hotplug()
      receive do
        {:usb_hotplug, %{action: :add, busnum: b, devnum: d}} -> ...
      end

  Everything is Linux-only and needs access to `/dev/bus/usb` (root or udev
  rules); hotplug additionally needs the netlink uevent socket (root).
  """

  alias CircuitsUsb.Descriptor
  alias CircuitsUsb.Enumeration
  alias CircuitsUsb.Hotplug
  alias CircuitsUsb.Transfer

  @typedoc "An open device (a transfer-engine process)."
  @type device :: GenServer.server()

  @doc "List all USB devices with parsed descriptors. See `CircuitsUsb.Enumeration.list_devices/1`."
  @spec list_devices() :: [Enumeration.DeviceRef.t()]
  defdelegate list_devices(), to: Enumeration

  @doc "Find the first device matching `vendor_id`/`product_id`, or `nil`."
  @spec find_device(0..0xFFFF, 0..0xFFFF) :: Enumeration.DeviceRef.t() | nil
  def find_device(vendor_id, product_id) do
    Enum.find(Enumeration.list_devices(), fn ref ->
      match?(
        {:ok, %Descriptor.Device{vendor_id: ^vendor_id, product_id: ^product_id}},
        ref.descriptor
      )
    end)
  end

  @doc """
  Open a device and start its transfer engine. Accepts a `DeviceRef`, a usbfs
  path, or a `vendor_id, product_id` pair. Returns `{:ok, device}`.
  """
  @spec open(Enumeration.DeviceRef.t() | Path.t()) :: GenServer.on_start()
  def open(%Enumeration.DeviceRef{path: path}), do: Transfer.start_link(node: path)
  def open(path) when is_binary(path), do: Transfer.start_link(node: path)

  @spec open(0..0xFFFF, 0..0xFFFF) :: GenServer.on_start() | {:error, :not_found}
  def open(vendor_id, product_id) do
    case find_device(vendor_id, product_id) do
      nil -> {:error, :not_found}
      ref -> open(ref)
    end
  end

  @doc "Close a device (stops its transfer engine, releasing the fd)."
  @spec close(device()) :: :ok
  defdelegate close(device), to: Transfer, as: :stop

  defdelegate claim_interface(device, interface), to: Transfer
  defdelegate release_interface(device, interface), to: Transfer
  defdelegate set_interface(device, interface, alternate), to: Transfer
  defdelegate get_driver(device, interface), to: Transfer
  defdelegate detach_driver(device, interface), to: Transfer
  defdelegate attach_driver(device, interface), to: Transfer
  defdelegate clear_halt(device, endpoint), to: Transfer
  defdelegate reset(device), to: Transfer

  @doc "Bulk IN transfer. See `CircuitsUsb.Transfer.bulk_in/4`."
  @spec bulk_in(device(), 0..255, non_neg_integer(), timeout()) ::
          {:ok, binary()} | {:error, term()}
  def bulk_in(device, endpoint, length, timeout \\ 1000),
    do: Transfer.bulk_in(device, endpoint, length, timeout)

  @doc "Bulk OUT transfer. See `CircuitsUsb.Transfer.bulk_out/4`."
  @spec bulk_out(device(), 0..255, iodata(), timeout()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def bulk_out(device, endpoint, data, timeout \\ 1000),
    do: Transfer.bulk_out(device, endpoint, data, timeout)

  @doc "Interrupt IN transfer. See `CircuitsUsb.Transfer.interrupt_in/4`."
  @spec interrupt_in(device(), 0..255, non_neg_integer(), timeout()) ::
          {:ok, binary()} | {:error, term()}
  def interrupt_in(device, endpoint, length, timeout \\ 1000),
    do: Transfer.interrupt_in(device, endpoint, length, timeout)

  @doc "Interrupt OUT transfer. See `CircuitsUsb.Transfer.interrupt_out/4`."
  @spec interrupt_out(device(), 0..255, iodata(), timeout()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def interrupt_out(device, endpoint, data, timeout \\ 1000),
    do: Transfer.interrupt_out(device, endpoint, data, timeout)

  @doc "Control IN transfer. See `CircuitsUsb.Transfer.control_in/6`."
  @spec control_in(device(), 0..255, 0..0xFFFF, 0..0xFFFF, non_neg_integer(), timeout()) ::
          {:ok, binary()} | {:error, atom()}
  def control_in(device, request, value, index, length, timeout \\ 1000),
    do: Transfer.control_in(device, request, value, index, length, timeout)

  @doc "Control OUT transfer. See `CircuitsUsb.Transfer.control_out/6`."
  @spec control_out(device(), 0..255, 0..0xFFFF, 0..0xFFFF, iodata(), timeout()) ::
          {:ok, non_neg_integer()} | {:error, atom()}
  def control_out(device, request, value, index, data, timeout \\ 1000),
    do: Transfer.control_out(device, request, value, index, data, timeout)

  @doc "Start watching for hotplug events. See `CircuitsUsb.Hotplug.start_link/1`."
  @spec watch_hotplug(keyword()) :: GenServer.on_start()
  defdelegate watch_hotplug(opts \\ []), to: Hotplug, as: :start_link
end
