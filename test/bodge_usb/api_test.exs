defmodule BodgeUSB.ApiTest do
  use ExUnit.Case, async: false

  import BodgeUSB.TestHelpers

  # End-to-end through the high-level facade against gadget zero (:usbfs phase).
  describe "high-level API against gadget zero" do
    @tag :usbfs
    test "discover, open, claim, and transfer via BodgeUSB" do
      ref = BodgeUSB.find_device(0x0525, 0xA4A0) || flunk("no gadget zero")
      {:ok, desc} = ref.descriptor
      {iface, ep_in, ep_out} = find_bulk_pair(desc) || flunk("no bulk pair")

      {:ok, dev} = BodgeUSB.open(ref)

      try do
        # No driver bound (usbtest removed by the harness) -> detach is a no-op.
        assert BodgeUSB.detach_driver(dev, iface) in [:ok, {:error, :enodata}]
        assert :ok = BodgeUSB.claim_interface(dev, iface)

        # Bulk source/sink. The harness loads g_zero with pattern=1, so the
        # source emits a mod-63 ramp -- assert the actual content, not just the
        # length, so corruption/offset/stale-buffer bugs can't slip through.
        assert {:ok, data} = BodgeUSB.bulk_in(dev, ep_in, 512)
        expected = for i <- 0..511, into: <<>>, do: <<rem(i, 63)>>
        assert data == expected
        assert {:ok, 512} = BodgeUSB.bulk_out(dev, ep_out, data)

        # Control message: read the device descriptor back.
        assert {:ok, <<18, 1, _rest::binary>>} = BodgeUSB.control_in(dev, 0x06, 0x0100, 0, 18)
      after
        BodgeUSB.release_interface(dev, iface)
        BodgeUSB.close(dev)
      end
    end
  end
end
