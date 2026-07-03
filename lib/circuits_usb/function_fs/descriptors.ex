defmodule CircuitsUsb.FunctionFs.Descriptors do
  @moduledoc """
  Builds the binary blobs FunctionFS expects on `ep0` (Part C2).

  A FunctionFS function describes itself by writing two blobs to its `ep0`
  before the gadget can bind: a `FUNCTIONFS_DESCRIPTORS_MAGIC_V2` blob holding
  raw USB interface/endpoint descriptors per speed, and a
  `FUNCTIONFS_STRINGS_MAGIC` blob with the function's strings. This module
  constructs both from a declarative spec:

      %{
        interface: %{class: 0xFF, subclass: 0, protocol: 0, string_index: 1},
        endpoints: [
          %{address: 0x01, type: :bulk},
          %{address: 0x81, type: :bulk}
        ],
        flags: [:all_ctrl_recip]
      }

  Full-speed and high-speed descriptor sets are emitted (bulk packet sizes 64
  and 512 respectively; interrupt endpoints use the given `max_packet_size`,
  capped at 64 for full speed). The kernel renumbers interfaces, endpoint
  addresses, and string indexes to fit the composite gadget; the `epN` files
  map to endpoints in declaration order (`ep1` is the first listed).

  `:all_ctrl_recip` requests delivery of control transfers regardless of
  recipient (device/interface/endpoint), which vendor protocols that address
  the device (rather than the interface) need.
  """

  # include/uapi/linux/usb/functionfs.h
  @descriptors_magic_v2 3
  @strings_magic 2
  @has_fs_desc 1
  @has_hs_desc 2
  @all_ctrl_recip 64

  @dt_interface 0x04
  @dt_endpoint 0x05

  @transfer_type %{control: 0, isochronous: 1, bulk: 2, interrupt: 3}

  @typedoc "One endpoint of the function, in declaration order (`ep1`, `ep2`, ...)."
  @type endpoint :: %{
          required(:address) => 0..0xFF,
          required(:type) => :bulk | :interrupt | :isochronous,
          optional(:max_packet_size) => 1..0xFFFF,
          optional(:interval) => 0..0xFF
        }

  @typedoc "The function description the blobs are built from."
  @type spec :: %{
          required(:interface) => %{
            optional(:class) => 0..0xFF,
            optional(:subclass) => 0..0xFF,
            optional(:protocol) => 0..0xFF,
            optional(:string_index) => 0..0xFF
          },
          required(:endpoints) => [endpoint()],
          optional(:flags) => [:all_ctrl_recip]
        }

  @doc """
  Build the v2 descriptors blob (full-speed + high-speed sets) for `spec`.
  """
  @spec descriptors(spec()) :: binary()
  def descriptors(spec) when is_map(spec) do
    endpoints = Map.fetch!(spec, :endpoints)
    flag_atoms = Map.get(spec, :flags, [])

    fs_set = descriptor_set(spec, endpoints, :fs)
    hs_set = descriptor_set(spec, endpoints, :hs)
    count = 1 + length(endpoints)

    flags =
      @has_fs_desc + @has_hs_desc +
        if(:all_ctrl_recip in flag_atoms, do: @all_ctrl_recip, else: 0)

    # Header: magic, total length, flags, then one descriptor count per
    # advertised speed, then the concatenated descriptor sets.
    body = <<flags::little-32, count::little-32, count::little-32>> <> fs_set <> hs_set
    total = 8 + byte_size(body)
    <<@descriptors_magic_v2::little-32, total::little-32>> <> body
  end

  @doc """
  Build the strings blob: `strings` become indexes 1..n (in order) for the
  single language `langid` (default `0x0409`, en-US).
  """
  @spec strings([String.t()], 0..0xFFFF) :: binary()
  def strings(strings, langid \\ 0x0409) when is_list(strings) do
    table = Enum.map_join(strings, &(&1 <> <<0>>))
    body = <<length(strings)::little-32, 1::little-32, langid::little-16>> <> table
    total = 8 + byte_size(body)
    <<@strings_magic::little-32, total::little-32>> <> body
  end

  # ---- descriptor encoding ---------------------------------------------------

  defp descriptor_set(spec, endpoints, speed) do
    iface = Map.fetch!(spec, :interface)

    interface =
      <<9, @dt_interface, 0, 0, length(endpoints), Map.get(iface, :class, 0xFF),
        Map.get(iface, :subclass, 0), Map.get(iface, :protocol, 0),
        Map.get(iface, :string_index, 0)>>

    Enum.reduce(endpoints, interface, fn ep, acc ->
      acc <> endpoint_descriptor(ep, speed)
    end)
  end

  defp endpoint_descriptor(ep, speed) do
    address = Map.fetch!(ep, :address)
    type = Map.fetch!(ep, :type)
    attributes = Map.fetch!(@transfer_type, type)
    mps = packet_size(type, Map.get(ep, :max_packet_size), speed)
    interval = interval(type, Map.get(ep, :interval), speed)

    <<7, @dt_endpoint, address, attributes, mps::little-16, interval>>
  end

  # Bulk packet size is fixed by the spec per speed; interrupt/isoc sizes are
  # caller-chosen but full speed caps at 64.
  defp packet_size(:bulk, _mps, :fs), do: 64
  defp packet_size(:bulk, _mps, :hs), do: 512
  defp packet_size(_type, mps, :fs), do: min(mps || 64, 64)
  defp packet_size(_type, mps, :hs), do: mps || 64

  # Periodic endpoints need a service interval; bulk must carry 0.
  defp interval(:bulk, _interval, _speed), do: 0
  defp interval(_type, interval, _speed), do: interval || 1
end
