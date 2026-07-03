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

  Pipeline transfers without blocking, via the async primitive the blocking
  calls are built on:

      {:ok, ref} = CircuitsUsb.submit(dev, {:bulk_in, 0x81, 4096}, timeout: 1000)
      receive do
        {:circuits_usb, ^ref, {:ok, data}} -> data
        {:circuits_usb, ^ref, {:error, reason}} -> reason
      end

  ## API tiers

  Pick the lowest tier that fits; each is a supported API:

    * `CircuitsUsb.Shim` - the primitive: a handle over one fd, raw submit/
      select/reap. No processes; you run the loop.
    * `CircuitsUsb.Transfer` - one engine process per device: `submit/3` /
      `cancel/2` / completion messages, plus blocking conveniences.
    * `CircuitsUsb` (this module) - discovery, open/close, and delegates for
      everyday use.

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

  @doc "Bulk OUT transfer. `opts[:zero_packet]` appends a terminating ZLP. See `CircuitsUsb.Transfer.bulk_out/5`."
  @spec bulk_out(device(), 0..255, iodata(), timeout(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def bulk_out(device, endpoint, data, timeout \\ 1000, opts \\ []),
    do: Transfer.bulk_out(device, endpoint, data, timeout, opts)

  @doc "Interrupt IN transfer. See `CircuitsUsb.Transfer.interrupt_in/4`."
  @spec interrupt_in(device(), 0..255, non_neg_integer(), timeout()) ::
          {:ok, binary()} | {:error, term()}
  def interrupt_in(device, endpoint, length, timeout \\ 1000),
    do: Transfer.interrupt_in(device, endpoint, length, timeout)

  @doc "Interrupt OUT transfer. `opts[:zero_packet]` appends a terminating ZLP. See `CircuitsUsb.Transfer.interrupt_out/5`."
  @spec interrupt_out(device(), 0..255, iodata(), timeout(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def interrupt_out(device, endpoint, data, timeout \\ 1000, opts \\ []),
    do: Transfer.interrupt_out(device, endpoint, data, timeout, opts)

  @doc "Control transfer with an explicit `bmRequestType` (class/vendor/etc.). See `CircuitsUsb.Transfer.control_transfer/7`."
  @spec control_transfer(
          device(),
          0..255,
          0..255,
          0..0xFFFF,
          0..0xFFFF,
          iodata() | non_neg_integer(),
          timeout()
        ) :: {:ok, binary()} | {:ok, non_neg_integer()} | {:error, atom()}
  def control_transfer(
        device,
        request_type,
        request,
        value,
        index,
        data_or_length,
        timeout \\ 1000
      ),
      do:
        Transfer.control_transfer(
          device,
          request_type,
          request,
          value,
          index,
          data_or_length,
          timeout
        )

  @doc "Standard device-recipient control IN. See `CircuitsUsb.Transfer.control_in/6`."
  @spec control_in(device(), 0..255, 0..0xFFFF, 0..0xFFFF, non_neg_integer(), timeout()) ::
          {:ok, binary()} | {:error, atom()}
  def control_in(device, request, value, index, length, timeout \\ 1000),
    do: Transfer.control_in(device, request, value, index, length, timeout)

  @doc "Control OUT transfer. See `CircuitsUsb.Transfer.control_out/6`."
  @spec control_out(device(), 0..255, 0..0xFFFF, 0..0xFFFF, iodata(), timeout()) ::
          {:ok, non_neg_integer()} | {:error, atom()}
  def control_out(device, request, value, index, data, timeout \\ 1000),
    do: Transfer.control_out(device, request, value, index, data, timeout)

  @doc "Isochronous IN transfer (one URB). See `CircuitsUsb.Transfer.iso_in/4`."
  @spec iso_in(device(), 0..255, [0..0xFFFF], timeout()) ::
          {:ok, {:iso, binary(), [Transfer.iso_packet()]}} | {:error, term()}
  def iso_in(device, endpoint, packet_lengths, timeout \\ 1000),
    do: Transfer.iso_in(device, endpoint, packet_lengths, timeout)

  @doc "Isochronous OUT transfer (one URB). See `CircuitsUsb.Transfer.iso_out/5`."
  @spec iso_out(device(), 0..255, [0..0xFFFF], iodata(), timeout()) ::
          {:ok, {:iso, non_neg_integer(), [Transfer.iso_packet()]}} | {:error, term()}
  def iso_out(device, endpoint, packet_lengths, data, timeout \\ 1000),
    do: Transfer.iso_out(device, endpoint, packet_lengths, data, timeout)

  @doc """
  Submit a transfer asynchronously; the completion arrives as
  `{:circuits_usb, ref, result}`. This is the engine's primitive; the blocking
  calls above are built on it. See `CircuitsUsb.Transfer.submit/3`.
  """
  @spec submit(device(), Transfer.request(), keyword()) ::
          {:ok, reference()} | {:error, atom()}
  defdelegate submit(device, request, opts \\ []), to: Transfer

  @doc "Cancel an in-flight transfer. See `CircuitsUsb.Transfer.cancel/2`."
  @spec cancel(device(), reference()) :: :ok | {:error, :not_found}
  defdelegate cancel(device, ref), to: Transfer

  @doc "Block on one completion. See `CircuitsUsb.Transfer.await/3`."
  @spec await(device(), reference(), timeout()) :: Transfer.result()
  defdelegate await(device, ref, timeout \\ :infinity), to: Transfer

  @doc "Start watching for hotplug events. See `CircuitsUsb.Hotplug.start_link/1`."
  @spec watch_hotplug(keyword()) :: GenServer.on_start()
  defdelegate watch_hotplug(opts \\ []), to: Hotplug, as: :start_link
end
