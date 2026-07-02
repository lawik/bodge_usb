defmodule CircuitsUsb.InterruptTest do
  use ExUnit.Case, async: false

  alias CircuitsUsb.Enumeration
  alias CircuitsUsb.Transfer

  # Runs against a configfs HID gadget (verify.sh :usbfs_int phase). The gadget
  # continuously emits the 8-byte input report <<1,2,3,4,5,6,7,8>> on its
  # interrupt IN endpoint; the host reads it. Tag :usbfs_int.
  @report <<1, 2, 3, 4, 5, 6, 7, 8>>

  describe "interrupt transfers against a HID gadget" do
    @tag :usbfs_int
    test "interrupt IN reads reports through the async engine" do
      node = System.get_env("CIRCUITS_USB_TEST_NODE") || flunk("set CIRCUITS_USB_TEST_NODE")
      {:ok, dev} = Enumeration.read_descriptors(node)
      {iface, ep_in} = find_interrupt_in(dev) || flunk("no interrupt IN endpoint")

      {:ok, eng} = Transfer.start_link(node: node)

      try do
        # Take the interface over from usbhid.
        assert {:ok, "usbhid"} = Transfer.get_driver(eng, iface)
        assert :ok = Transfer.detach_driver(eng, iface)
        assert :ok = Transfer.claim_interface(eng, iface)

        # The gadget streams reports; a read lands on one (retry past idle gaps).
        assert @report == read_report(eng, ep_in, 50)
      after
        Transfer.stop(eng)
      end
    end
  end

  defp read_report(eng, ep, tries) when tries > 0 do
    case Transfer.interrupt_in(eng, ep, 8, 1000) do
      {:ok, @report} -> @report
      _ -> read_report(eng, ep, tries - 1)
    end
  end

  defp read_report(_eng, _ep, 0), do: :timed_out

  defp find_interrupt_in(dev) do
    Enum.find_value(dev.configurations, fn c ->
      Enum.find_value(c.interfaces, fn i ->
        ep = Enum.find(i.endpoints, &(&1.transfer_type == :interrupt and &1.direction == :in))
        if ep, do: {i.number, ep.address}
      end)
    end)
  end
end
