defmodule BodgeUSB.DriverTest do
  use ExUnit.Case, async: false

  import BodgeUSB.TestHelpers

  alias BodgeUSB.Enumeration
  alias BodgeUSB.Nif

  # Runs with the in-kernel usbtest driver bound to gadget zero (verify.sh runs
  # this phase before removing usbtest). Tag :usbfs_driver.
  describe "kernel driver detach/reattach against gadget zero" do
    @tag :usbfs_driver
    test "take over an interface from a stock driver, use it, and reattach" do
      node = System.get_env("BODGE_USB_TEST_NODE") || flunk("set BODGE_USB_TEST_NODE")
      {:ok, dev} = Enumeration.read_descriptors(node)
      {iface, ep_in, _ep_out} = find_bulk_pair(dev) || flunk("no bulk pair")

      {:ok, h} = Nif.open(node, [:rdwr])

      try do
        # usbtest owns the interface, so we can't claim it yet.
        assert {:ok, "usbtest"} = Nif.get_driver(h, iface)
        assert {:error, :ebusy} = Nif.claim_interface(h, iface)

        # Detach the kernel driver, then take over and use the interface
        # (one async bulk URB through the raw submit/select/reap discipline).
        assert :ok = Nif.detach_driver(h, iface)
        assert {:error, :enodata} = Nif.get_driver(h, iface)
        assert :ok = Nif.claim_interface(h, iface)
        ref = make_ref()
        assert :ok = Nif.submit_bulk(h, 1, ep_in, 4096)
        assert :ok = Nif.select(h, ref)
        assert_receive {:select, _handle, ^ref, :ready_output}, 2000
        assert [{1, :ok, <<_::4096-bytes>>}] = Nif.reap(h)
        assert :ok = Nif.release_interface(h, iface)

        # Reattach the original driver.
        assert :ok = Nif.attach_driver(h, iface)
        assert {:ok, "usbtest"} = wait_for_driver(h, iface, "usbtest")
      after
        Nif.close(h)
      end
    end
  end

  # attach_driver triggers a re-probe; give it a moment to settle.
  defp wait_for_driver(h, iface, name, tries \\ 20) do
    case Nif.get_driver(h, iface) do
      {:ok, ^name} = ok ->
        ok

      _ when tries > 0 ->
        Process.sleep(50)
        wait_for_driver(h, iface, name, tries - 1)

      other ->
        other
    end
  end
end
