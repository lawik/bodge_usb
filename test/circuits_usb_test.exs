defmodule CircuitsUsbTest do
  use ExUnit.Case, async: true
  doctest CircuitsUsb

  describe "facade (no device needed)" do
    test "list_devices/0 returns a list (empty without usbfs)" do
      assert is_list(CircuitsUsb.list_devices())
    end

    test "find_device/2 returns nil when absent" do
      assert CircuitsUsb.find_device(0xDEAD, 0xBEEF) == nil
    end

    test "open/2 by vid/pid returns :not_found when absent" do
      assert CircuitsUsb.open(0xDEAD, 0xBEEF) == {:error, :not_found}
    end

    test "open/1 on an unopenable path errors without crashing a non-trapping caller" do
      # Regression: open the fd before starting the engine, so a failed open
      # starts no process to exit the caller through the link. When the engine
      # opened inside init instead, its {:stop, reason} took down a non-trapping
      # caller (still the behavior of Transfer.start_link with :node).
      parent = self()

      {caller, mon} =
        spawn_monitor(fn ->
          Process.flag(:trap_exit, false)
          send(parent, {:opened, CircuitsUsb.open("/nonexistent-usb-node")})
        end)

      assert_receive {:opened, {:error, :enoent}}
      assert_receive {:DOWN, ^mon, :process, ^caller, :normal}
    end
  end
end
