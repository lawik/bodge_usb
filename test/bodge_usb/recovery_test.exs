defmodule BodgeUSB.RecoveryTest do
  use ExUnit.Case, async: false

  import BodgeUSB.TestHelpers

  alias BodgeUSB.Descriptor
  alias BodgeUSB.Enumeration
  alias BodgeUSB.Nif

  @gzero_vendor 0x0525
  @gzero_product 0xA4A0

  describe "endpoint stall recovery against gadget zero" do
    @tag :usbfs
    test "a halted endpoint returns :epipe and recovers with clear_halt" do
      node = find_gzero() || flunk("no gadget zero")
      {:ok, dev} = Enumeration.read_descriptors(node)
      {iface, ep_in, _ep_out} = find_bulk_pair(dev) || flunk("no bulk pair")

      {:ok, eng} = BodgeUSB.open(node)

      try do
        :ok = BodgeUSB.claim_interface(eng, iface)

        # Halt the endpoint: SET_FEATURE(ENDPOINT_HALT). bmRequestType 0x02 =
        # host->device, standard, endpoint recipient; bRequest 0x03 = SET_FEATURE;
        # wValue 0 = ENDPOINT_HALT; wIndex = endpoint address.
        assert {:ok, 0} = BodgeUSB.control_transfer(eng, 0x02, 0x03, 0x0000, ep_in, "", 1000)

        # Transfers on the halted endpoint stall with :epipe.
        assert {:error, :epipe} = BodgeUSB.bulk_in(eng, ep_in, 512, 1000)

        # Recover, then it works again.
        assert :ok = BodgeUSB.clear_halt(eng, ep_in)
        assert {:ok, <<_::512-bytes>>} = BodgeUSB.bulk_in(eng, ep_in, 512, 1000)
      after
        BodgeUSB.release_interface(eng, iface)
        BodgeUSB.close(eng)
      end
    end
  end

  describe "device reset" do
    @tag :usbfs_reset
    test "reset succeeds and the device comes back usable" do
      node = find_gzero() || flunk("no gadget zero")
      {:ok, h} = Nif.open(node, [:rdwr])
      assert :ok = Nif.reset(h)
      Nif.close(h)

      # The device re-enumerates (possibly at a new address). It must come
      # back, and its descriptors must read and parse: reset that leaves the
      # device unusable would otherwise pass silently.
      assert {:ok, %Descriptor.Device{vendor_id: @gzero_vendor}} = wait_for_gzero(50)
    end
  end

  defp wait_for_gzero(0), do: {:error, :gadget_never_returned}

  defp wait_for_gzero(tries) do
    with node when is_binary(node) <- find_gzero() || :not_yet,
         {:ok, dev} <- Enumeration.read_descriptors(node) do
      {:ok, dev}
    else
      _ ->
        Process.sleep(100)
        wait_for_gzero(tries - 1)
    end
  end

  describe "mid-transfer disconnect" do
    @tag :usbfs_disconnect
    test "a transfer during disconnect yields a typed error and the engine survives" do
      node = find_gzero() || flunk("no gadget zero")
      {:ok, dev} = Enumeration.read_descriptors(node)
      {iface, ep_in, _ep_out} = find_bulk_pair(dev) || flunk("no bulk pair")

      {:ok, eng} = BodgeUSB.start_link(node: node)
      :ok = BodgeUSB.claim_interface(eng, iface)

      # Start a slow (~40ms) read, then rip the device away mid-flight.
      task = Task.async(fn -> BodgeUSB.bulk_in(eng, ep_in, 1_048_576, 5000) end)
      Process.sleep(5)
      System.cmd("rmmod", ["g_zero"], stderr_to_stdout: true)

      result = Task.await(task, 10_000)
      # Defined, typed outcome -- not a crash.
      assert match?({:error, _}, result)

      # The engine is still alive and further ops fail cleanly (device gone).
      assert Process.alive?(eng)
      assert match?({:error, _}, BodgeUSB.bulk_in(eng, ep_in, 64, 500))

      assert :ok = BodgeUSB.close(eng)
    end
  end

  defp find_gzero do
    Enum.find_value(Enumeration.list_devices(), fn ref ->
      case ref.descriptor do
        {:ok, %Descriptor.Device{vendor_id: @gzero_vendor, product_id: @gzero_product}} ->
          ref.path

        _ ->
          nil
      end
    end)
  end
end
