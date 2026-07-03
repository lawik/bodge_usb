defmodule CircuitsUsb.GadgetTest do
  use ExUnit.Case, async: false

  alias CircuitsUsb.Enumeration
  alias CircuitsUsb.Gadget
  alias CircuitsUsb.Shim
  alias CircuitsUsb.Transfer

  # 8-byte vendor-usage HID report descriptor with one input and one output
  # report (mirrors the harness gadget, plus the output usage).
  @report_desc <<0x06, 0x00, 0xFF, 0x09, 0x01, 0xA1, 0x01, 0x15, 0x00, 0x26, 0xFF, 0x00, 0x75,
                 0x08, 0x95, 0x08, 0x09, 0x01, 0x81, 0x02, 0x09, 0x01, 0x91, 0x02, 0xC0>>

  @spec_fixture %{
    vendor_id: 0xCAFE,
    product_id: 0xBABE,
    bcd_usb: 0x0200,
    strings: %{manufacturer: "circuits", product: "gadget test", serialnumber: "g-1"},
    functions: %{
      "hid.usb0" => %{protocol: 0, subclass: 0, report_length: 8, report_desc: @report_desc}
    },
    configs: %{
      "c.1" => %{configuration: "test", max_power: 120, functions: ["hid.usb0"]}
    }
  }

  describe "spec validation (no configfs needed)" do
    test "rejects names that could escape the configfs root" do
      for bad <- ["", ".", "..", "../evil", "a/b", ".hidden"] do
        assert {:error, {:invalid_name, ^bad}} = Gadget.define(bad, @spec_fixture, root: "/tmp")
      end
    end

    test "rejects malformed function and config names" do
      spec = put_in(@spec_fixture, [:functions], %{"hidusb0" => %{}})

      assert {:error, {:invalid_function_name, "hidusb0"}} =
               Gadget.define("g", spec, root: "/tmp")

      spec = put_in(@spec_fixture, [:configs], %{"c/1" => %{functions: ["hid.usb0"]}})
      assert {:error, {:invalid_config_name, "c/1"}} = Gadget.define("g", spec, root: "/tmp")
    end

    test "rejects configs that link a function the spec does not define" do
      spec = put_in(@spec_fixture, [:configs, "c.1", :functions], ["acm.gs0"])
      assert {:error, {:unknown_function, "acm.gs0"}} = Gadget.define("g", spec, root: "/tmp")
    end

    test "fails typed when the configfs root does not exist" do
      assert {:error, {:no_configfs, _}} =
               Gadget.define("g", @spec_fixture, root: "/no/such/configfs")
    end
  end

  describe "tree construction against a plain directory" do
    # A tmpdir stands in for configfs: mkdir/write/symlink behave the same,
    # which is enough to pin down exactly what lands where. (Real-configfs
    # semantics, including remove/1, are covered by the :usbfs_gadget test.)
    setup do
      root = Path.join(System.tmp_dir!(), "gadget_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)
      %{root: root}
    end

    test "define/3 lays out ids, strings, function attrs, and config links", %{root: root} do
      assert {:ok, g} = Gadget.define("demo", @spec_fixture, root: root)
      assert g.path == Path.join(root, "demo")

      # Integers land in decimal (kernel parses base 0), binaries raw.
      assert File.read!(Path.join(g.path, "idVendor")) == "51966"
      assert File.read!(Path.join(g.path, "idProduct")) == "47806"
      assert File.read!(Path.join(g.path, "bcdUSB")) == "512"
      assert File.read!(Path.join(g.path, "strings/0x409/manufacturer")) == "circuits"
      assert File.read!(Path.join(g.path, "functions/hid.usb0/report_desc")) == @report_desc
      assert File.read!(Path.join(g.path, "functions/hid.usb0/report_length")) == "8"
      assert File.read!(Path.join(g.path, "configs/c.1/MaxPower")) == "120"
      assert File.read!(Path.join(g.path, "configs/c.1/strings/0x409/configuration")) == "test"

      link = Path.join(g.path, "configs/c.1/hid.usb0")
      assert {:ok, %File.Stat{type: :symlink}} = File.lstat(link)
      assert {:ok, target} = File.read_link(link)
      assert target == Path.join(g.path, "functions/hid.usb0")
    end

    test "define/3 refuses to overwrite an existing gadget", %{root: root} do
      assert {:ok, _g} = Gadget.define("demo", @spec_fixture, root: root)
      assert {:error, :already_defined} = Gadget.define("demo", @spec_fixture, root: root)
    end

    test "remove/1 unlinks config function symlinks first", %{root: root} do
      {:ok, g} = Gadget.define("demo", @spec_fixture, root: root)
      link = Path.join(g.path, "configs/c.1/hid.usb0")
      assert File.exists?(link)

      # On a tmpdir the attribute *files* survive (in configfs the kernel owns
      # them and they vanish with rmdir), so remove/1 cannot finish here; it
      # must still be safe and take the symlinks out in the right order.
      _ = Gadget.remove(g)
      refute File.exists?(link)
    end
  end

  # Both USB roles in one test: this library defines the device via configfs,
  # binds it to dummy_udc.0, and its own host side enumerates and exchanges
  # interrupt transfers with it. Runs in the VM (:usbfs_gadget phase; needs
  # dummy_hcd, libcomposite, usb_f_hid, root).
  describe "live gadget on dummy_udc" do
    @tag :usbfs_gadget
    test "define -> bind -> enumerate -> interrupt IN/OUT -> unbind -> remove" do
      unless "dummy_udc.0" in Gadget.udcs(), do: flunk("dummy_udc.0 not available")

      assert {:ok, g} = Gadget.define("circuits_gadget_t", @spec_fixture)

      try do
        assert :ok = Gadget.bind(g, "dummy_udc.0")
        assert {:ok, "dummy_udc.0"} = Gadget.udc(g)

        # The host side of the same library sees it appear...
        ref = await_device(0xCAFE, 0xBABE, 50) || flunk("gadget did not enumerate")
        {:ok, dev} = ref.descriptor

        # ...as a HID device with an interrupt IN/OUT pair.
        [config] = dev.configurations
        [iface] = config.interfaces
        assert iface.class == 3
        ep_in = Enum.find(iface.endpoints, &(&1.direction == :in))
        ep_out = Enum.find(iface.endpoints, &(&1.direction == :out))
        assert ep_in.transfer_type == :interrupt
        assert ep_out.transfer_type == :interrupt

        # Device side of the pipe: the function's chardev.
        assert {:ok, "/dev/hidg" <> _ = hidg} = Gadget.device_node(g, "hid.usb0")
        {:ok, gh} = Shim.open(hidg, [:rdwr, :nonblock])
        {:ok, eng} = Transfer.start_link(node: ref.path)

        try do
          assert Transfer.detach_driver(eng, iface.number) in [:ok, {:error, :enodata}]
          assert :ok = Transfer.claim_interface(eng, iface.number)

          # Gadget -> host over the interrupt IN endpoint.
          in_report = <<1, 2, 3, 4, 5, 6, 7, 8>>
          assert {:ok, 8} = write_report(gh, in_report, 50)
          assert ^in_report = read_host(eng, ep_in.address, 50)

          # Host -> gadget over the interrupt OUT endpoint.
          out_report = <<8, 7, 6, 5, 4, 3, 2, 1>>
          assert {:ok, 8} = Transfer.interrupt_out(eng, ep_out.address, out_report, 2000)
          assert ^out_report = read_gadget(gh, 100)
        after
          Transfer.stop(eng)
          Shim.close(gh)
        end

        # Unbind disconnects: the device leaves the bus.
        assert :ok = Gadget.unbind(g)
        assert :ok = await_gone(0xCAFE, 0xBABE, 50)
      after
        Gadget.remove(g)
      end

      # remove/1 ran in after: the whole configfs tree must be gone.
      refute File.dir?(g.path)
    end
  end

  # ---- helpers -------------------------------------------------------------

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
        {:ok, %CircuitsUsb.Descriptor.Device{vendor_id: ^vid, product_id: ^pid}},
        ref.descriptor
      )
    end)
  end

  # f_hid's write can be briefly EAGAIN (nonblocking) until the endpoint has a
  # free request; retry past it.
  defp write_report(_gh, _report, 0), do: {:error, :eagain}

  defp write_report(gh, report, tries) do
    case Shim.write(gh, report) do
      {:ok, 8} = ok ->
        ok

      {:error, :eagain} ->
        Process.sleep(20)
        write_report(gh, report, tries - 1)

      other ->
        other
    end
  end

  defp read_host(eng, ep, tries) when tries > 0 do
    case Transfer.interrupt_in(eng, ep, 8, 1000) do
      {:ok, <<_::8-bytes>> = report} -> report
      _ -> read_host(eng, ep, tries - 1)
    end
  end

  defp read_host(_eng, _ep, 0), do: :timed_out

  defp read_gadget(_gh, 0), do: :timed_out

  defp read_gadget(gh, tries) do
    case Shim.read(gh, 8) do
      {:ok, <<_::8-bytes>> = report} ->
        report

      _ ->
        Process.sleep(20)
        read_gadget(gh, tries - 1)
    end
  end
end
