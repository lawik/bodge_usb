defmodule CircuitsUsb.TransferTest do
  use ExUnit.Case, async: false

  alias CircuitsUsb.Enumeration
  alias CircuitsUsb.Shim

  # Integration against the live gadget-zero source/sink (harness A2, no usbtest
  # bound so we can claim the interface ourselves). Set CIRCUITS_USB_TEST_NODE.
  describe "bulk source/sink against gadget zero" do
    @tag :usbfs
    test "claim + bulk IN/OUT round-trips the device's pattern" do
      node = System.get_env("CIRCUITS_USB_TEST_NODE") || flunk("set CIRCUITS_USB_TEST_NODE")
      {:ok, dev} = Enumeration.read_descriptors(node)
      {iface, ep_in, ep_out} = find_bulk_pair(dev) || flunk("no bulk in/out pair found")

      {:ok, h} = Shim.open(node, [:rdwr])

      try do
        assert :ok = Shim.claim_interface(h, iface)

        # Source endpoint produces the device's pattern.
        assert {:ok, data} = Shim.bulk_in(h, ep_in, 4096, 1000)
        assert byte_size(data) == 4096

        # Writing those exact bytes back to the sink matches whatever pattern the
        # gadget is checking for (source and sink share it), so no stall -- this
        # is the pattern-verified source/sink exchange usbtest also performs.
        assert {:ok, 4096} = Shim.bulk_out(h, ep_out, data, 1000)

        # A second read is consistent with the first (same per-buffer pattern).
        assert {:ok, ^data} = Shim.bulk_in(h, ep_in, 4096, 1000)
      after
        Shim.release_interface(h, iface)
        Shim.close(h)
      end
    end
  end

  # First interface exposing both a bulk IN and a bulk OUT endpoint.
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
