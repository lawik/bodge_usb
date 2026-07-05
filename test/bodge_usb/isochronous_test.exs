defmodule BodgeUSB.IsochronousTest do
  use ExUnit.Case, async: false

  alias BodgeUSB.Descriptor
  alias BodgeUSB.Enumeration
  alias BodgeUSB.Nif

  # dummy_hcd cannot emulate isochronous transfers, so this runs against the
  # QEMU usb-audio device on the emulated xHCI (see harness/vm/vm.sh). Tag
  # :usbfs_iso. The device is always present, so the test discovers it itself.
  @qemu_audio_vendor 0x46F4
  @qemu_audio_product 0x0002

  describe "isochronous OUT streaming to usb-audio" do
    @tag :usbfs_iso
    test "sustained isoc OUT completes with correct per-packet accounting" do
      node = find_audio_node() || flunk("no QEMU usb-audio device present")
      {:ok, dev} = Enumeration.read_descriptors(node)
      {iface, alt, ep, mps} = find_iso_out(dev) || flunk("no isochronous OUT endpoint")

      {:ok, h} = Nif.open(node, [:rdwr])

      try do
        # Detach snd-usb-audio (tolerate it being already detached from a prior run).
        assert Nif.detach_driver(h, iface) in [:ok, {:error, :enodata}]
        assert :ok = Nif.claim_interface(h, iface)
        # Select the alt setting that activates the isoc endpoint.
        assert :ok = Nif.set_interface(h, iface, alt)

        packets = 8
        lengths = List.duplicate(mps, packets)
        data = :binary.copy(<<0>>, mps * packets)

        # Stream several URBs back-to-back; drain and check every packet.
        urb_count = 10

        Enum.each(1..urb_count, fn tag ->
          assert :ok = Nif.submit_iso(h, tag, ep, lengths, data)
        end)

        completions = reap_n(h, urb_count, [])
        assert length(completions) == urb_count

        for {_tag, status, {:iso, actual, pkts}} <- completions do
          assert status == :ok
          assert actual == mps * packets
          assert length(pkts) == packets
          assert Enum.all?(pkts, fn {alen, pstatus} -> alen == mps and pstatus == :ok end)
        end
      after
        Nif.set_interface(h, iface, 0)
        Nif.release_interface(h, iface)
        # Restore the interface to snd-usb-audio for a clean, re-runnable state.
        Nif.attach_driver(h, iface)
        Nif.close(h)
      end
    end
  end

  describe "isochronous OUT through the engine" do
    @tag :usbfs_iso
    test "single URB and async submit stream both complete with per-packet accounting" do
      node = find_audio_node() || flunk("no QEMU usb-audio device present")
      {:ok, dev} = Enumeration.read_descriptors(node)
      {iface, alt, ep, mps} = find_iso_out(dev) || flunk("no isochronous OUT endpoint")

      {:ok, eng} = BodgeUSB.start_link(node: node)

      try do
        assert BodgeUSB.detach_driver(eng, iface) in [:ok, {:error, :enodata}]
        assert :ok = BodgeUSB.claim_interface(eng, iface)
        assert :ok = BodgeUSB.set_interface(eng, iface, alt)

        packets = 8
        lengths = List.duplicate(mps, packets)
        data = :binary.copy(<<0>>, mps * packets)

        # One URB, one result: submit + await (iso has no blocking wrapper;
        # streaming is the normal shape).
        {:ok, one} = BodgeUSB.submit(eng, {:iso_out, ep, lengths, data}, timeout: 2000)
        assert {:ok, {:iso, actual, pkts}} = BodgeUSB.await(eng, one, 4000)
        assert actual == mps * packets
        assert Enum.all?(pkts, fn {alen, pstatus} -> alen == mps and pstatus == :ok end)

        # The primitive: several URBs in flight from one process, completions
        # as messages -- the shape isochronous streaming actually needs.
        refs =
          for _ <- 1..5 do
            {:ok, ref} = BodgeUSB.submit(eng, {:iso_out, ep, lengths, data}, timeout: 3000)
            ref
          end

        for ref <- refs do
          assert_receive {:bodge_usb, ^ref, {:ok, {:iso, _bytes, pkts}}}, 4000
          assert length(pkts) == packets
          assert Enum.all?(pkts, fn {_alen, pstatus} -> pstatus == :ok end)
        end
      after
        BodgeUSB.set_interface(eng, iface, 0)
        BodgeUSB.release_interface(eng, iface)
        BodgeUSB.attach_driver(eng, iface)
        BodgeUSB.close(eng)
      end
    end
  end

  defp reap_n(_h, 0, acc), do: acc

  defp reap_n(h, remaining, acc) do
    ref = make_ref()
    :ok = Nif.select(h, ref)

    receive do
      {:select, _h, ^ref, :ready_output} -> :ok
    after
      3000 -> :ok
    end

    new = Nif.reap(h)
    reap_n(h, remaining - length(new), acc ++ new)
  end

  defp find_audio_node do
    Enum.find_value(Enumeration.list_devices(), fn ref ->
      case ref.descriptor do
        {:ok, %Descriptor.Device{vendor_id: @qemu_audio_vendor, product_id: @qemu_audio_product}} ->
          ref.path

        _ ->
          nil
      end
    end)
  end

  defp find_iso_out(dev) do
    Enum.find_value(dev.configurations, fn c ->
      Enum.find_value(c.interfaces, fn i ->
        ep = Enum.find(i.endpoints, &(&1.transfer_type == :isochronous and &1.direction == :out))
        if ep, do: {i.number, i.alternate_setting, ep.address, ep.max_packet_size}
      end)
    end)
  end
end
