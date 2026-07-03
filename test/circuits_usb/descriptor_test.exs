defmodule CircuitsUsb.DescriptorTest do
  use ExUnit.Case, async: true

  alias CircuitsUsb.Descriptor
  alias CircuitsUsb.Descriptor.{Configuration, Device, Endpoint, Interface}

  # A well-formed device with one config, one interface, two bulk endpoints.
  @device <<18, 1, 0x00, 0x02, 0, 0, 0, 64, 0x25, 0x05, 0xA0, 0xA4, 0x01, 0x00, 1, 2, 3, 1>>
  @config <<9, 2, 32::little-16, 1, 1, 0, 0x80, 60>>
  @interface <<9, 4, 0, 0, 2, 0xFF, 0, 0, 0>>
  @ep_in <<7, 5, 0x81, 0x02, 512::little-16, 0>>
  @ep_out <<7, 5, 0x01, 0x02, 512::little-16, 0>>
  @full @device <> @config <> @interface <> @ep_in <> @ep_out

  describe "parse/1 well-formed" do
    test "parses device fields" do
      assert {:ok, %Device{} = d} = Descriptor.parse(@full)
      assert d.vendor_id == 0x0525
      assert d.product_id == 0xA4A0
      assert d.usb_version == 0x0200
      assert d.max_packet_size0 == 64
      assert d.num_configurations == 1
      assert d.manufacturer_index == 1
      assert d.serial_number_index == 3
    end

    test "parses nested config/interface/endpoints" do
      {:ok, d} = Descriptor.parse(@full)
      assert [%Configuration{} = c] = d.configurations
      assert c.value == 1
      assert c.total_length == 32
      assert c.max_power_ma == 120
      assert [%Interface{} = i] = c.interfaces
      assert i.number == 0
      assert i.class == 0xFF

      assert [%Endpoint{} = ep_in, %Endpoint{} = ep_out] = i.endpoints
      assert ep_in.address == 0x81
      assert ep_in.number == 1
      assert ep_in.direction == :in
      assert ep_in.transfer_type == :bulk
      assert ep_in.max_packet_size == 512
      assert ep_out.direction == :out
    end

    test "class-specific descriptors are attached, not dropped or fatal" do
      # An HID descriptor (type 0x21) between interface and endpoint.
      hid = <<9, 0x21, 0x11, 0x01, 0x00, 1, 0x22, 0x3F, 0x00>>
      blob = @device <> @config <> @interface <> hid <> @ep_in <> @ep_out
      assert {:ok, d} = Descriptor.parse(blob)
      [c] = d.configurations
      [i] = c.interfaces
      assert [%{type: 0x21}] = i.extra
      assert length(i.endpoints) == 2
    end
  end

  describe "parse/1 routes undersized interface/endpoint descriptors to extra (L4)" do
    test "undersized interface descriptor becomes config extra, not an all-nil interface" do
      # bLength 6, shorter than the 9 an interface header needs.
      bad_iface = <<6, 4, 0, 0, 2, 0xFF>>
      assert {:ok, d} = Descriptor.parse(@device <> @config <> bad_iface)
      [c] = d.configurations
      assert c.interfaces == []
      assert [%{type: 4, length: 6, data: ^bad_iface}] = c.extra
    end

    test "undersized endpoint descriptor becomes interface extra, not an all-nil endpoint" do
      # bLength 6, shorter than the 7 an endpoint descriptor needs.
      bad_ep = <<6, 5, 0x81, 0x02, 512::little-16>>
      assert {:ok, d} = Descriptor.parse(@device <> @config <> @interface <> bad_ep)
      [c] = d.configurations
      [i] = c.interfaces
      assert i.endpoints == []
      assert [%{type: 5, length: 6, data: ^bad_ep}] = i.extra
    end

    test "undersized endpoint before any interface becomes config extra" do
      bad_ep = <<6, 5, 0x81, 0x02, 512::little-16>>
      assert {:ok, d} = Descriptor.parse(@device <> @config <> bad_ep)
      [c] = d.configurations
      assert c.interfaces == []
      assert [%{type: 5, length: 6, data: ^bad_ep}] = c.extra
    end
  end

  describe "parse/1 degrades safely on the A3 malformation catalog" do
    test "short device descriptor" do
      assert {:error, :short_device_descriptor} = Descriptor.parse(<<8, 1, 0, 0>>)
      assert {:error, :short_device_descriptor} = Descriptor.parse(<<>>)
    end

    test "wrong device bLength (bad-device-blength)" do
      bad = <<64, 1>> <> :binary.copy(<<0>>, 16)
      assert {:error, {:invalid_device_length, 64}} = Descriptor.parse(bad)
    end

    test "first descriptor is not a device descriptor" do
      not_dev = <<18, 2>> <> :binary.copy(<<0>>, 16)
      assert {:error, :not_a_device_descriptor} = Descriptor.parse(not_dev)
    end

    test "zero-length descriptor (would otherwise loop forever)" do
      assert {:error, :zero_length_descriptor} = Descriptor.parse(@device <> <<0, 2, 0>>)
    end

    test "descriptor bLength of 1 is invalid" do
      assert {:error, {:invalid_descriptor_length, 1}} = Descriptor.parse(@device <> <<1, 2>>)
    end

    test "truncated config set (config-truncated)" do
      assert {:error, :truncated} = Descriptor.parse(@device <> <<9, 2, 32::little-16, 1>>)
    end

    test "oversized wTotalLength is tolerated (we walk actual bytes)" do
      # config claims wTotalLength 0xffff but only the real bytes are present.
      oversized = <<9, 2, 0xFFFF::little-16, 1, 1, 0, 0x80, 60>>
      blob = @device <> oversized <> @interface <> @ep_in <> @ep_out
      assert {:ok, d} = Descriptor.parse(blob)
      assert [%Configuration{total_length: 0xFFFF, interfaces: [_]}] = d.configurations
    end

    test "trailing single byte is truncation, not a crash" do
      assert {:error, :truncated} = Descriptor.parse(@device <> <<5>>)
    end
  end

  describe "parse/1 is total (never raises)" do
    test "arbitrary and adversarial byte inputs always return a tagged result" do
      inputs =
        [<<>>, <<0>>, <<1>>, <<255>>, <<18, 1>>, :binary.copy(<<0>>, 18)] ++
          for len <- [0, 1, 2, 17, 18, 19, 64, 300],
              byte <- [0, 1, 2, 5, 255],
              do: :binary.copy(<<byte>>, len)

      for input <- inputs do
        result = Descriptor.parse(input)

        assert match?({:ok, _}, result) or match?({:error, _}, result),
               "parse/1 did not return a tagged result for #{inspect(input, limit: 8)}"
      end
    end
  end

  describe "string descriptors" do
    test "decode_string/1 decodes UTF-16LE" do
      # "Hi" as a string descriptor: bLength=6, type=3, 'H',0,'i',0
      assert {:ok, "Hi"} = Descriptor.decode_string(<<6, 3, ?H, 0, ?i, 0>>)
    end

    test "decode_string/1 tolerates a lying bLength" do
      # bLength claims more than present; we clamp to what's there.
      assert {:ok, "Hi"} = Descriptor.decode_string(<<40, 3, ?H, 0, ?i, 0>>)
    end

    test "decode_string/1 rejects a non-string descriptor" do
      assert {:error, :invalid_string} = Descriptor.decode_string(<<4, 2, 0, 0>>)
    end

    test "language_ids/1 parses the LANGID array" do
      assert {:ok, [0x0409]} = Descriptor.language_ids(<<4, 3, 0x09, 0x04>>)
    end
  end
end
