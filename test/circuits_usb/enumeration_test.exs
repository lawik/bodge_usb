defmodule CircuitsUsb.EnumerationTest do
  use ExUnit.Case, async: false

  alias CircuitsUsb.Descriptor.Device
  alias CircuitsUsb.Enumeration
  alias CircuitsUsb.Shim

  describe "on a host without usbfs" do
    test "list_devices/1 returns [] for a missing root" do
      assert [] = Enumeration.list_devices("/no/such/usb/root")
    end
  end

  # Integration against the live gadget-zero node (harness A2). Set
  # CIRCUITS_USB_TEST_NODE to /dev/bus/usb/BBB/DDD.
  describe "against a real usbfs node" do
    @tag :usbfs
    test "read_descriptors/1 parses the gadget-zero device + config" do
      node = System.get_env("CIRCUITS_USB_TEST_NODE") || flunk("set CIRCUITS_USB_TEST_NODE")

      assert {:ok, %Device{} = d} = Enumeration.read_descriptors(node)
      assert d.vendor_id == 0x0525
      assert d.product_id == 0xA4A0
      assert d.num_configurations >= 1
      assert [_ | _] = d.configurations

      # Gadget Zero source/sink exposes bulk endpoints.
      endpoints =
        for c <- d.configurations, i <- c.interfaces, ep <- i.endpoints, do: ep

      assert Enum.any?(endpoints, &(&1.transfer_type == :bulk))
    end

    @tag :usbfs
    test "string/3 reads the product string" do
      node = System.get_env("CIRCUITS_USB_TEST_NODE") || flunk("set CIRCUITS_USB_TEST_NODE")
      {:ok, h} = Shim.open(node, [:rdwr])
      {:ok, d} = Enumeration.read_descriptors(node)

      assert {:ok, product} = Enumeration.string(h, d.product_index)
      assert product =~ "Gadget Zero"
      Shim.close(h)
    end

    @tag :usbfs
    test "list_devices/1 finds the gadget with parsed descriptors" do
      refs = Enumeration.list_devices()

      assert Enum.any?(refs, fn ref ->
               match?({:ok, %Device{vendor_id: 0x0525, product_id: 0xA4A0}}, ref.descriptor)
             end)
    end
  end
end
