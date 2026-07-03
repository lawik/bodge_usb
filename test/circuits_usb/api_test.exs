defmodule CircuitsUsb.ApiTest do
  use ExUnit.Case, async: false

  # End-to-end through the high-level facade against gadget zero (:usbfs phase).
  describe "high-level API against gadget zero" do
    @tag :usbfs
    test "discover, open, claim, and transfer via CircuitsUsb" do
      ref = CircuitsUsb.find_device(0x0525, 0xA4A0) || flunk("no gadget zero")
      {:ok, desc} = ref.descriptor
      {iface, ep_in, ep_out} = find_bulk_pair(desc) || flunk("no bulk pair")

      {:ok, dev} = CircuitsUsb.open(ref)

      try do
        # No driver bound (usbtest removed by the harness) -> detach is a no-op.
        assert CircuitsUsb.detach_driver(dev, iface) in [:ok, {:error, :enodata}]
        assert :ok = CircuitsUsb.claim_interface(dev, iface)

        # Bulk source/sink. The harness loads g_zero with pattern=1, so the
        # source emits a mod-63 ramp -- assert the actual content, not just the
        # length, so corruption/offset/stale-buffer bugs can't slip through.
        assert {:ok, data} = CircuitsUsb.bulk_in(dev, ep_in, 512)
        expected = for i <- 0..511, into: <<>>, do: <<rem(i, 63)>>
        assert data == expected
        assert {:ok, 512} = CircuitsUsb.bulk_out(dev, ep_out, data)

        # Control message: read the device descriptor back.
        assert {:ok, <<18, 1, _rest::binary>>} = CircuitsUsb.control_in(dev, 0x06, 0x0100, 0, 18)
      after
        CircuitsUsb.release_interface(dev, iface)
        CircuitsUsb.close(dev)
      end
    end
  end

  defp find_bulk_pair(dev) do
    Enum.find_value(dev.configurations, fn c ->
      Enum.find_value(c.interfaces, fn i ->
        ep_in = Enum.find(i.endpoints, &(&1.transfer_type == :bulk and &1.direction == :in))
        ep_out = Enum.find(i.endpoints, &(&1.transfer_type == :bulk and &1.direction == :out))
        if ep_in && ep_out, do: {i.number, ep_in.address, ep_out.address}
      end)
    end)
  end
end
