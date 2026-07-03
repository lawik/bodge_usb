defmodule CircuitsUsb.FunctionFsTest do
  use ExUnit.Case, async: false

  alias CircuitsUsb.Descriptor
  alias CircuitsUsb.Enumeration
  alias CircuitsUsb.FunctionFs
  alias CircuitsUsb.FunctionFs.Descriptors
  alias CircuitsUsb.Gadget
  alias CircuitsUsb.Shim
  alias CircuitsUsb.Transfer

  @function %{
    interface: %{class: 0xFF, subclass: 0x42, protocol: 0x01, string_index: 1},
    endpoints: [
      %{address: 0x01, type: :bulk},
      %{address: 0x81, type: :bulk}
    ],
    flags: [:all_ctrl_recip]
  }

  describe "descriptor blob construction (host-safe)" do
    test "v2 header, counts, and per-speed descriptor sets" do
      blob = Descriptors.descriptors(@function)

      fs_set =
        <<9, 4, 0, 0, 2, 0xFF, 0x42, 0x01, 1>> <>
          <<7, 5, 0x01, 2, 64::little-16, 0>> <> <<7, 5, 0x81, 2, 64::little-16, 0>>

      hs_set =
        <<9, 4, 0, 0, 2, 0xFF, 0x42, 0x01, 1>> <>
          <<7, 5, 0x01, 2, 512::little-16, 0>> <> <<7, 5, 0x81, 2, 512::little-16, 0>>

      # magic v2 = 3; flags = HAS_FS_DESC(1) + HAS_HS_DESC(2) + ALL_CTRL_RECIP(64);
      # one interface + two endpoints per speed = 3 descriptors each.
      expected =
        <<3::little-32, 8 + 12 + byte_size(fs_set) + byte_size(hs_set)::little-32, 67::little-32,
          3::little-32, 3::little-32>> <> fs_set <> hs_set

      assert blob == expected
    end

    test "the built descriptors survive our own defensive parser" do
      blob = Descriptors.descriptors(@function)

      # Slice the full-speed set out (after the 20-byte header) and wrap it in
      # a synthetic configuration header so parse_configuration/1 accepts it.
      set_len = 9 + 7 + 7
      <<_header::binary-size(20), fs_set::binary-size(^set_len), _hs::binary>> = blob
      config = <<9, 2, 9 + set_len::little-16, 1, 1, 0, 0x80, 50>> <> fs_set

      assert {:ok, parsed} = Descriptor.parse_configuration(config)
      assert [%Descriptor.Interface{class: 0xFF, subclass: 0x42} = iface] = parsed.interfaces
      assert [ep_out, ep_in] = iface.endpoints
      assert %Descriptor.Endpoint{address: 0x01, direction: :out, transfer_type: :bulk} = ep_out
      assert %Descriptor.Endpoint{address: 0x81, direction: :in, transfer_type: :bulk} = ep_in
      assert ep_out.max_packet_size == 64
    end

    test "interrupt endpoints keep their interval and cap full-speed packets at 64" do
      spec = %{
        interface: %{class: 3},
        endpoints: [%{address: 0x82, type: :interrupt, max_packet_size: 512, interval: 4}]
      }

      blob = Descriptors.descriptors(spec)

      <<_header::binary-size(20), _iface::binary-size(9), fs_ep::binary-size(7),
        _::binary-size(9), hs_ep::binary-size(7)>> = blob

      assert fs_ep == <<7, 5, 0x82, 3, 64::little-16, 4>>
      assert hs_ep == <<7, 5, 0x82, 3, 512::little-16, 4>>
    end

    test "strings blob: magic, counts, langid, NUL-terminated table" do
      blob = Descriptors.strings(["NetMD", "ok"], 0x0409)
      table = "NetMD" <> <<0>> <> "ok" <> <<0>>

      assert blob ==
               <<2::little-32, 8 + 10 + byte_size(table)::little-32, 2::little-32, 1::little-32,
                 0x0409::little-16>> <> table
    end
  end

  # Both roles in-process again: CircuitsUsb.Gadget declares an ffs function,
  # CircuitsUsb.FunctionFs serves a toy vendor protocol (control echo across
  # ep0, bulk echo across ep1/ep2), and the host tier of the same library
  # drives it. Runs in the VM (:usbfs_ffs phase; needs dummy_hcd, libcomposite,
  # usb_f_fs, root).
  describe "live FunctionFS function on dummy_udc" do
    @tag :usbfs_ffs
    test "custom vendor protocol: control echo, bulk echo, stall, teardown" do
      unless "dummy_udc.0" in Gadget.udcs(), do: flunk("dummy_udc.0 not available")

      mnt = "/dev/ffs-circuits"

      gadget_spec = %{
        vendor_id: 0xCAFE,
        product_id: 0xF5F5,
        strings: %{manufacturer: "circuits", product: "ffs test", serialnumber: "ffs-1"},
        functions: %{"ffs.circuits" => %{}},
        configs: %{"c.1" => %{configuration: "ffs", max_power: 120, functions: ["ffs.circuits"]}}
      }

      assert {:ok, g} = Gadget.define("circuits_ffs_t", gadget_spec)

      try do
        assert :ok = FunctionFs.mount("circuits", mnt)

        try do
          {:ok, store} = Agent.start_link(fn -> <<>> end)

          # Toy vendor protocol: 0x02 stores the control OUT payload, 0x01
          # reads it back, anything else stalls.
          handler = fn
            %{request: 0x01, request_type: rt}, nil when rt >= 0x80 ->
              {:reply, Agent.get(store, & &1)}

            %{request: 0x02}, data when is_binary(data) ->
              Agent.update(store, fn _ -> data end)
              :ok

            _setup, _data ->
              :stall
          end

          {:ok, ffs} =
            FunctionFs.start_link(
              mountpoint: mnt,
              function: @function,
              strings: ["circuits ffs"],
              handler: handler
            )

          try do
            # Descriptors are in place, so the gadget may bind now (:bound);
            # the host configuring the device fires :enabled.
            assert :ok = Gadget.bind(g, "dummy_udc.0")
            assert_receive {:functionfs, ^ffs, :bound}, 5000
            assert_receive {:functionfs, ^ffs, :enabled}, 5000

            ref = await_device(0xCAFE, 0xF5F5, 50) || flunk("ffs gadget did not enumerate")
            {:ok, dev} = ref.descriptor
            [config] = dev.configurations
            [iface] = config.interfaces
            assert iface.class == 0xFF
            ep_out = Enum.find(iface.endpoints, &(&1.direction == :out))
            ep_in = Enum.find(iface.endpoints, &(&1.direction == :in))

            # Device-side bulk echo pump: ep1 = first declared (OUT), ep2 = IN.
            {:ok, gh_out} = FunctionFs.open_endpoint(mnt, 1)
            {:ok, gh_in} = FunctionFs.open_endpoint(mnt, 2)
            pump = Task.async(fn -> pump_loop(gh_out, gh_in) end)

            {:ok, eng} = Transfer.start_link(node: ref.path)

            try do
              payload = for i <- 0..63, into: <<>>, do: <<rem(i * 7, 256)>>

              # Control echo, device recipient: exercises ALL_CTRL_RECIP.
              assert {:ok, 64} = Transfer.control_transfer(eng, 0x40, 0x02, 0, 0, payload, 2000)
              assert {:ok, ^payload} = Transfer.control_transfer(eng, 0xC0, 0x01, 0, 0, 64, 2000)

              # Same protocol, interface recipient: the ordinary routing path.
              payload2 = :binary.copy(<<0xA5>>, 32)

              assert {:ok, 32} =
                       Transfer.control_transfer(eng, 0x41, 0x02, 0, iface.number, payload2, 2000)

              assert {:ok, ^payload2} =
                       Transfer.control_transfer(eng, 0xC1, 0x01, 0, iface.number, 32, 2000)

              # Unknown requests are stalled by the handler: typed :epipe.
              assert {:error, :epipe} = Transfer.control_transfer(eng, 0xC0, 0x7F, 0, 0, 8, 2000)
              # ep0 recovers: the next request works.
              assert {:ok, ^payload2} = Transfer.control_transfer(eng, 0xC0, 0x01, 0, 0, 32, 2000)

              # Bulk echo through the endpoint files.
              :ok = Transfer.claim_interface(eng, iface.number)
              data = for i <- 0..4095, into: <<>>, do: <<rem(i, 251)>>
              assert {:ok, 4096} = Transfer.bulk_out(eng, ep_out.address, data, 3000)
              assert {:ok, ^data} = Transfer.bulk_in(eng, ep_in.address, 4096, 3000)
            after
              Transfer.stop(eng)
            end

            # Unbind: the function unbinds (endpoints shut down, unblocking
            # the pump) and the device leaves the bus. (:disabled would come
            # from SET_CONFIGURATION(0), not from UDC unbind.)
            assert :ok = Gadget.unbind(g)
            assert_receive {:functionfs, ^ffs, :unbound}, 5000
            assert :done = Task.await(pump, 5000)
            Shim.close(gh_out)
            Shim.close(gh_in)
            assert :ok = await_gone(0xCAFE, 0xF5F5, 50)
          after
            FunctionFs.stop(ffs)
          end
        after
          FunctionFs.umount(mnt)
        end
      after
        Gadget.remove(g)
      end
    end
  end

  # ---- helpers -------------------------------------------------------------

  defp pump_loop(gh_out, gh_in) do
    case Shim.read_blocking(gh_out, 4096) do
      {:ok, data} when byte_size(data) > 0 ->
        Shim.write_blocking(gh_in, data)
        pump_loop(gh_out, gh_in)

      _shutdown_or_error ->
        :done
    end
  end

  defp await_device(_vid, _pid, 0), do: nil

  defp await_device(vid, pid, tries) do
    case find_device(vid, pid) do
      nil ->
        Process.sleep(100)
        await_device(vid, pid, tries - 1)

      ref ->
        ref
    end
  end

  defp await_gone(_vid, _pid, 0), do: :still_present

  defp await_gone(vid, pid, tries) do
    case find_device(vid, pid) do
      nil ->
        :ok

      _ref ->
        Process.sleep(100)
        await_gone(vid, pid, tries - 1)
    end
  end

  defp find_device(vid, pid) do
    Enum.find(Enumeration.list_devices(), fn ref ->
      match?(
        {:ok, %Descriptor.Device{vendor_id: ^vid, product_id: ^pid}},
        ref.descriptor
      )
    end)
  end
end
