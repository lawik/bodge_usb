defmodule BodgeUSBTest do
  use ExUnit.Case, async: true
  doctest BodgeUSB

  describe "facade (no device needed)" do
    test "list_devices/0 returns a list (empty without usbfs)" do
      assert is_list(BodgeUSB.list_devices())
    end

    test "find_device/2 returns nil when absent" do
      assert BodgeUSB.find_device(0xDEAD, 0xBEEF) == nil
    end

    test "open/2 by vid/pid returns :not_found when absent" do
      assert BodgeUSB.open(0xDEAD, 0xBEEF) == {:error, :not_found}
    end

    test "watch_hotplug/0 never crashes a non-trapping caller" do
      # Regression: the netlink socket is opened before the watcher is started,
      # so the common failure (no root) returns {:error, reason} instead of
      # exiting the caller through the link. As root the open succeeds; the
      # invariant under test is the caller's :normal exit either way.
      parent = self()

      {caller, mon} =
        spawn_monitor(fn ->
          send(parent, {:watched, BodgeUSB.watch_hotplug()})
        end)

      assert_receive {:watched, result}
      assert_receive {:DOWN, ^mon, :process, ^caller, :normal}

      case result do
        {:ok, hp} -> BodgeUSB.Hotplug.stop(hp)
        {:error, reason} -> assert is_atom(reason)
      end
    end

    test "open/1 on an unopenable path errors without crashing a non-trapping caller" do
      # Regression: open the fd before starting the engine, so a failed open
      # starts no process to exit the caller through the link. When the engine
      # opened inside init instead, its {:stop, reason} took down a non-trapping
      # caller (still the behavior of BodgeUSB.start_link with :node).
      parent = self()

      {caller, mon} =
        spawn_monitor(fn ->
          Process.flag(:trap_exit, false)
          send(parent, {:opened, BodgeUSB.open("/nonexistent-usb-node")})
        end)

      assert_receive {:opened, {:error, :enoent}}
      assert_receive {:DOWN, ^mon, :process, ^caller, :normal}
    end
  end
end
