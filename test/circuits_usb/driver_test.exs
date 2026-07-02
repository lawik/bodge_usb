defmodule CircuitsUsb.DriverTest do
  use ExUnit.Case, async: false

  alias CircuitsUsb.Enumeration
  alias CircuitsUsb.Shim

  # Runs with the in-kernel usbtest driver bound to gadget zero (verify.sh runs
  # this phase before removing usbtest). Tag :usbfs_driver.
  describe "kernel driver detach/reattach against gadget zero" do
    @tag :usbfs_driver
    test "take over an interface from a stock driver, use it, and reattach" do
      node = System.get_env("CIRCUITS_USB_TEST_NODE") || flunk("set CIRCUITS_USB_TEST_NODE")
      {:ok, dev} = Enumeration.read_descriptors(node)
      {iface, ep_in, _ep_out} = find_bulk_pair(dev) || flunk("no bulk pair")

      {:ok, h} = Shim.open(node, [:rdwr])

      try do
        # usbtest owns the interface, so we can't claim it yet.
        assert {:ok, "usbtest"} = Shim.get_driver(h, iface)
        assert {:error, :ebusy} = Shim.claim_interface(h, iface)

        # Detach the kernel driver, then take over and use the interface.
        assert :ok = Shim.detach_driver(h, iface)
        assert {:error, :enodata} = Shim.get_driver(h, iface)
        assert :ok = Shim.claim_interface(h, iface)
        assert {:ok, <<_::4096-bytes>>} = Shim.bulk_in(h, ep_in, 4096, 2000)
        assert :ok = Shim.release_interface(h, iface)

        # Reattach the original driver.
        assert :ok = Shim.attach_driver(h, iface)
        assert {:ok, "usbtest"} = wait_for_driver(h, iface, "usbtest")
      after
        Shim.close(h)
      end
    end
  end

  # attach_driver triggers a re-probe; give it a moment to settle.
  defp wait_for_driver(h, iface, name, tries \\ 20) do
    case Shim.get_driver(h, iface) do
      {:ok, ^name} = ok ->
        ok

      _ when tries > 0 ->
        Process.sleep(50)
        wait_for_driver(h, iface, name, tries - 1)

      other ->
        other
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
