defmodule CircuitsUsb.AdversarialTest do
  use ExUnit.Case, async: false

  alias CircuitsUsb.Descriptor
  alias CircuitsUsb.Enumeration
  alias CircuitsUsb.Shim

  # Live A3 raw-gadget adversarial device (dead:beef), one fault active per phase
  # (harness/vm/verify.sh). This validates PROJECT.md's B3/B9 acceptance -- the
  # library degrades safely against a *real* hostile device on the wire, not just
  # against synthetic descriptor blobs in descriptor_test.exs.
  defp a3_node do
    System.get_env("CIRCUITS_USB_TEST_NODE") || flunk("set CIRCUITS_USB_TEST_NODE")
  end

  describe "live A3 device" do
    @tag :usbfs_a3_stall
    test "stall-string: device/config parse, but a string read is a typed :epipe" do
      n = a3_node()

      # The device and configuration descriptors still parse into structs.
      assert {:ok, %Descriptor.Device{vendor_id: 0xDEAD, product_id: 0xBEEF} = dev} =
               Enumeration.read_descriptors(n)

      # Reading a string descriptor stalls -> a typed error, not a crash.
      {:ok, h} = Shim.open(n, [:rdwr])

      try do
        assert {:error, :epipe} = Enumeration.string(h, dev.product_index)
      after
        Shim.close(h)
      end
    end

    @tag :usbfs_a3_blength
    test "bad-device-blength: library rejects a device Linux happily enumerated" do
      n = a3_node()

      # Linux tolerates the over-large device-descriptor bLength and enumerates
      # the device, but the library's strict parser surfaces it as a typed error
      # rather than trusting a non-compliant descriptor.
      assert {:error, {:invalid_device_length, 0x40}} = Enumeration.read_descriptors(n)
    end

    @tag :usbfs_a3_slow
    test "slow: a short-timeout control transfer times out cleanly" do
      n = a3_node()
      {:ok, h} = Shim.open(n, [:rdwr])

      try do
        # The device delays every descriptor response ~400ms; a live control
        # read with a 100ms timeout must return a typed error, not hang/crash.
        assert {:error, reason} = Shim.control_in(h, 0x06, 0x0100, 0, 18, 100)
        assert reason in [:etimedout, :etime, :eio]
      after
        Shim.close(h)
      end
    end
  end
end
