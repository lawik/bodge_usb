defmodule BodgeUSB.InterruptTest do
  use ExUnit.Case, async: false

  alias BodgeUSB.Enumeration
  alias BodgeUSB

  # Runs against a configfs HID gadget (verify.sh :usbfs_int phase). The gadget
  # continuously emits the 8-byte input report <<1,2,3,4,5,6,7,8>> on its
  # interrupt IN endpoint; the host reads it. Tag :usbfs_int.
  @report <<1, 2, 3, 4, 5, 6, 7, 8>>

  describe "interrupt transfers against a HID gadget" do
    @tag :usbfs_int
    test "interrupt IN reads reports through the async engine" do
      node = System.get_env("BODGE_USB_TEST_NODE") || flunk("set BODGE_USB_TEST_NODE")
      {:ok, dev} = Enumeration.read_descriptors(node)
      {iface, ep_in} = find_interrupt_in(dev) || flunk("no interrupt IN endpoint")

      {:ok, eng} = BodgeUSB.start_link(node: node)

      try do
        # Take the interface over from usbhid (the OUT test in this phase may
        # already have detached it; test order is randomized).
        assert BodgeUSB.get_driver(eng, iface) in [{:ok, "usbhid"}, {:error, :enodata}]
        assert BodgeUSB.detach_driver(eng, iface) in [:ok, {:error, :enodata}]
        assert :ok = BodgeUSB.claim_interface(eng, iface)

        # The gadget streams reports; a read lands on one (retry past idle gaps).
        assert @report == read_report(eng, ep_in, 50)
      after
        BodgeUSB.close(eng)
      end
    end

    @tag :usbfs_int
    test "interrupt OUT delivers a report to the gadget" do
      node = System.get_env("BODGE_USB_TEST_NODE") || flunk("set BODGE_USB_TEST_NODE")
      {:ok, dev} = Enumeration.read_descriptors(node)

      {iface, ep_out} =
        find_interrupt_out(dev) || flunk("no interrupt OUT endpoint on the HID gadget")

      {:ok, eng} = BodgeUSB.start_link(node: node)

      try do
        assert BodgeUSB.detach_driver(eng, iface) in [:ok, {:error, :enodata}]
        assert :ok = BodgeUSB.claim_interface(eng, iface)

        # verify.sh has a gadget-side reader capturing one 8-byte OUT report
        # from /dev/hidg0 and asserts the exact bytes after this phase; the
        # completion here proves the URB was accepted and ACKed on the wire.
        assert {:ok, 8} = BodgeUSB.interrupt_out(eng, ep_out, <<8, 7, 6, 5, 4, 3, 2, 1>>, 2000)
      after
        BodgeUSB.close(eng)
      end
    end
  end

  defp read_report(eng, ep, tries) when tries > 0 do
    case BodgeUSB.interrupt_in(eng, ep, 8, 1000) do
      {:ok, @report} -> @report
      _ -> read_report(eng, ep, tries - 1)
    end
  end

  defp read_report(_eng, _ep, 0), do: :timed_out

  defp find_interrupt_in(dev), do: find_interrupt(dev, :in)
  defp find_interrupt_out(dev), do: find_interrupt(dev, :out)

  defp find_interrupt(dev, direction) do
    Enum.find_value(dev.configurations, fn c ->
      Enum.find_value(c.interfaces, fn i ->
        ep =
          Enum.find(i.endpoints, &(&1.transfer_type == :interrupt and &1.direction == direction))

        if ep, do: {i.number, ep.address}
      end)
    end)
  end
end
