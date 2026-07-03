defmodule CircuitsUsb.Descriptor do
  @moduledoc """
  USB descriptor parsing.

  Parses the raw descriptor bytes that usbfs returns (device descriptor followed
  by the configuration descriptor sets) into Elixir structs, plus string
  descriptor decoding.

  Parsing is total and defensive: for *any* input binary, `parse/1` returns
  either `{:ok, %Device{}}` or `{:error, reason}` with a typed reason, and never
  raises. That is what lets the library survive malformed descriptors from a
  hostile or buggy device (truncated, oversized, zero-length, wrong `bLength`,
  ...).
  """

  # Standard descriptor type codes (USB 2.0 table 9-5).
  @dt_device 0x01
  @dt_configuration 0x02
  @dt_string 0x03
  @dt_interface 0x04
  @dt_endpoint 0x05

  defmodule Endpoint do
    @moduledoc "Parsed endpoint descriptor."
    defstruct [:address, :number, :direction, :transfer_type, :max_packet_size, :interval]

    @type t :: %__MODULE__{
            address: 0..0xFF,
            number: 0..15,
            direction: :in | :out,
            transfer_type: :control | :isochronous | :bulk | :interrupt,
            max_packet_size: non_neg_integer(),
            interval: 0..0xFF
          }
  end

  defmodule Interface do
    @moduledoc "Parsed interface descriptor with its endpoints."
    defstruct number: nil,
              alternate_setting: nil,
              class: nil,
              subclass: nil,
              protocol: nil,
              interface_index: nil,
              endpoints: [],
              extra: []

    @type t :: %__MODULE__{
            number: 0..0xFF,
            alternate_setting: 0..0xFF,
            class: 0..0xFF,
            subclass: 0..0xFF,
            protocol: 0..0xFF,
            interface_index: 0..0xFF,
            endpoints: [Endpoint.t()],
            extra: [map()]
          }
  end

  defmodule Configuration do
    @moduledoc "Parsed configuration descriptor with its interfaces."
    defstruct value: nil,
              total_length: nil,
              num_interfaces: nil,
              configuration_index: nil,
              attributes: nil,
              max_power_ma: nil,
              interfaces: [],
              extra: []

    @type t :: %__MODULE__{
            value: 0..0xFF,
            total_length: non_neg_integer(),
            num_interfaces: 0..0xFF,
            configuration_index: 0..0xFF,
            attributes: 0..0xFF,
            max_power_ma: non_neg_integer(),
            interfaces: [Interface.t()],
            extra: [map()]
          }
  end

  defmodule Device do
    @moduledoc "Parsed device descriptor with its configurations."
    defstruct [
      :usb_version,
      :class,
      :subclass,
      :protocol,
      :max_packet_size0,
      :vendor_id,
      :product_id,
      :device_version,
      :manufacturer_index,
      :product_index,
      :serial_number_index,
      :num_configurations,
      configurations: []
    ]

    @type t :: %__MODULE__{
            usb_version: non_neg_integer(),
            class: 0..0xFF,
            subclass: 0..0xFF,
            protocol: 0..0xFF,
            max_packet_size0: non_neg_integer(),
            vendor_id: 0..0xFFFF,
            product_id: 0..0xFFFF,
            device_version: non_neg_integer(),
            manufacturer_index: 0..0xFF,
            product_index: 0..0xFF,
            serial_number_index: 0..0xFF,
            num_configurations: 0..0xFF,
            configurations: [Configuration.t()]
          }
  end

  @type reason ::
          :short_device_descriptor
          | :not_a_device_descriptor
          | {:invalid_device_length, non_neg_integer()}
          | :zero_length_descriptor
          | {:invalid_descriptor_length, non_neg_integer()}
          | :truncated

  @doc """
  Parse a full descriptor blob (device descriptor + configuration sets), as
  returned by reading a usbfs node. Returns `{:ok, %Device{}}` or `{:error, reason}`.
  """
  @spec parse(binary()) :: {:ok, Device.t()} | {:error, reason()}
  def parse(binary) when is_binary(binary) do
    with {:ok, device} <- parse_device(binary) do
      <<_device::binary-size(18), rest::binary>> = binary

      case walk(rest, []) do
        {:ok, raws} -> {:ok, %{device | configurations: group_configurations(raws)}}
        {:error, _} = err -> err
      end
    end
  end

  @doc """
  Parse just the 18-byte device descriptor (ignores any trailing bytes).

  Note: reading a usbfs node returns the *device* descriptor with its multibyte
  fields (`bcdUSB`, `idVendor`, `idProduct`, `bcdDevice`) already byte-swapped to
  host order by the kernel; we read them little-endian, which is correct on
  little-endian hosts (the common case). Configuration descriptors are raw
  little-endian and parse correctly everywhere.
  """
  @spec parse_device(binary()) :: {:ok, Device.t()} | {:error, reason()}
  def parse_device(binary) when is_binary(binary) and byte_size(binary) < 18,
    do: {:error, :short_device_descriptor}

  def parse_device(
        <<b_length, @dt_device, bcd_usb::little-16, class, subclass, protocol, mps0,
          vendor::little-16, product::little-16, device_ver::little-16, i_man, i_prod, i_serial,
          num_configs, _rest::binary>>
      ) do
    if b_length == 18 do
      {:ok,
       %Device{
         usb_version: bcd_usb,
         class: class,
         subclass: subclass,
         protocol: protocol,
         max_packet_size0: mps0,
         vendor_id: vendor,
         product_id: product,
         device_version: device_ver,
         manufacturer_index: i_man,
         product_index: i_prod,
         serial_number_index: i_serial,
         num_configurations: num_configs
       }}
    else
      {:error, {:invalid_device_length, b_length}}
    end
  end

  def parse_device(<<_b_length, _type, _rest::binary>>), do: {:error, :not_a_device_descriptor}

  @doc """
  Parse a single configuration descriptor set (config + interfaces + endpoints).
  """
  @spec parse_configuration(binary()) :: {:ok, Configuration.t()} | {:error, reason()}
  def parse_configuration(binary) when is_binary(binary) do
    case walk(binary, []) do
      {:ok, [%{type: @dt_configuration} | _] = raws} ->
        case group_configurations(raws) do
          [config] -> {:ok, config}
          [config | _] -> {:ok, config}
          [] -> {:error, :not_a_configuration_descriptor}
        end

      {:ok, _} ->
        {:error, :not_a_configuration_descriptor}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Decode a string descriptor's bytes (`<<bLength, 0x03, utf16le...>>`) to a
  UTF-8 string. For index 0 the payload is a LANGID array; use `language_ids/1`.
  """
  @spec decode_string(binary()) :: {:ok, String.t()} | {:error, :invalid_string}
  def decode_string(<<b_length, @dt_string, rest::binary>>) when b_length >= 2 do
    take = min(b_length - 2, byte_size(rest))
    <<utf16::binary-size(^take), _::binary>> = rest

    case :unicode.characters_to_binary(utf16, {:utf16, :little}) do
      s when is_binary(s) -> {:ok, s}
      _ -> {:error, :invalid_string}
    end
  end

  def decode_string(_), do: {:error, :invalid_string}

  @doc "Decode the LANGID list from a string-index-0 descriptor."
  @spec language_ids(binary()) :: {:ok, [0..0xFFFF]} | {:error, :invalid_string}
  def language_ids(<<b_length, @dt_string, rest::binary>>) when b_length >= 2 do
    take = min(b_length - 2, byte_size(rest))
    <<langids::binary-size(^take), _::binary>> = rest
    {:ok, for(<<id::little-16 <- langids>>, do: id)}
  end

  def language_ids(_), do: {:error, :invalid_string}

  # ---- internal: walk a descriptor list defensively ----------------------

  # Split a blob into a list of %{type, length, data} chunks by bLength.
  # Returns {:error, reason} on any malformation instead of crashing.
  defp walk(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp walk(<<_only_one_byte>>, _acc), do: {:error, :truncated}

  defp walk(<<b_length, b_type, _::binary>> = bin, acc) do
    cond do
      b_length == 0 ->
        {:error, :zero_length_descriptor}

      b_length < 2 ->
        {:error, {:invalid_descriptor_length, b_length}}

      byte_size(bin) < b_length ->
        {:error, :truncated}

      true ->
        <<chunk::binary-size(^b_length), tail::binary>> = bin
        walk(tail, [%{type: b_type, length: b_length, data: chunk} | acc])
    end
  end

  # ---- internal: group raw descriptors into nested structs ---------------

  defp group_configurations(raws) do
    raws
    |> Enum.reduce([], &attach/2)
    |> Enum.reverse()
    |> Enum.map(&finalize_config/1)
  end

  # Build a reversed list of configs; each config accumulates interfaces, each
  # interface accumulates endpoints. Unknown descriptors attach to the nearest
  # enclosing interface (or config) as `extra`, never dropped, never crashing.
  defp attach(%{type: @dt_configuration} = raw, configs) do
    [%{config: parse_config_header(raw), interfaces: [], extra: []} | configs]
  end

  defp attach(%{type: @dt_interface} = raw, [cfg | rest]) do
    case parse_interface_header(raw) do
      nil ->
        # undersized/malformed interface descriptor: keep as config extra rather
        # than fabricate an all-nil struct that violates the typespec.
        [%{cfg | extra: [strip(raw) | cfg.extra]} | rest]

      %Interface{} = header ->
        iface = %{interface: header, endpoints: [], extra: []}
        [%{cfg | interfaces: [iface | cfg.interfaces]} | rest]
    end
  end

  defp attach(%{type: @dt_endpoint} = raw, [cfg | rest]) do
    case {cfg.interfaces, parse_endpoint(raw)} do
      {[iface | ifaces], %Endpoint{} = ep} ->
        iface = %{iface | endpoints: [ep | iface.endpoints]}
        [%{cfg | interfaces: [iface | ifaces]} | rest]

      {[iface | ifaces], nil} ->
        # undersized endpoint descriptor: attach as interface extra.
        iface = %{iface | extra: [strip(raw) | iface.extra]}
        [%{cfg | interfaces: [iface | ifaces]} | rest]

      {[], _} ->
        # endpoint before any interface: keep it as config-level extra
        [%{cfg | extra: [strip(raw) | cfg.extra]} | rest]
    end
  end

  defp attach(raw, [cfg | rest]) do
    # class/vendor-specific descriptor: attach to current interface if any.
    case cfg.interfaces do
      [iface | ifaces] ->
        iface = %{iface | extra: [strip(raw) | iface.extra]}
        [%{cfg | interfaces: [iface | ifaces]} | rest]

      [] ->
        [%{cfg | extra: [strip(raw) | cfg.extra]} | rest]
    end
  end

  # A descriptor appearing before any configuration descriptor: ignore for the
  # nested view (it is still available via the raw walk if needed).
  defp attach(_raw, []), do: []

  defp finalize_config(%{config: config, interfaces: ifaces, extra: extra}) do
    %{
      config
      | interfaces: ifaces |> Enum.reverse() |> Enum.map(&finalize_interface/1),
        extra: Enum.reverse(extra)
    }
  end

  defp finalize_interface(%{interface: iface, endpoints: eps, extra: extra}) do
    %{iface | endpoints: Enum.reverse(eps), extra: Enum.reverse(extra)}
  end

  defp parse_config_header(%{
         data:
           <<_bl, _bt, total::little-16, num_ifaces, value, i_config, attributes, max_power,
             _::binary>>
       }) do
    %Configuration{
      value: value,
      total_length: total,
      num_interfaces: num_ifaces,
      configuration_index: i_config,
      attributes: attributes,
      max_power_ma: max_power * 2
    }
  end

  defp parse_config_header(%{data: data}),
    do: %Configuration{value: nil, total_length: byte_size(data)}

  defp parse_interface_header(%{
         data: <<_bl, _bt, number, alt, _num_eps, class, subclass, protocol, i_iface, _::binary>>
       }) do
    %Interface{
      number: number,
      alternate_setting: alt,
      class: class,
      subclass: subclass,
      protocol: protocol,
      interface_index: i_iface
    }
  end

  defp parse_interface_header(_), do: nil

  defp parse_endpoint(%{
         data: <<_bl, _bt, address, attributes, max_packet::little-16, interval, _::binary>>
       }) do
    # bEndpointAddress: bit 7 direction, bits 6-4 reserved, bits 3-0 number.
    <<dir::1, _reserved::3, number::4>> = <<address>>
    # bmAttributes: bits 1-0 are the transfer type.
    <<_::6, xfer::2>> = <<attributes>>

    %Endpoint{
      address: address,
      number: number,
      direction: if(dir == 1, do: :in, else: :out),
      transfer_type: elem({:control, :isochronous, :bulk, :interrupt}, xfer),
      max_packet_size: max_packet,
      interval: interval
    }
  end

  defp parse_endpoint(_), do: nil

  defp strip(%{type: type, length: length, data: data}),
    do: %{type: type, length: length, data: data}
end
