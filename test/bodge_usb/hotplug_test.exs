defmodule BodgeUSB.HotplugTest do
  use ExUnit.Case, async: false

  alias BodgeUSB.Hotplug

  # Scripted hotplug churn: a gadget appears and disappears; the library
  # observes it over the netlink uevent socket. Needs dummy_hcd loaded and g_zero
  # not loaded on entry (verify.sh :usbfs_hotplug phase). Runs as root.
  describe "hotplug notifications" do
    @tag :usbfs_hotplug
    test "add and remove events for a gadget connecting and disconnecting" do
      # Clean start: no gadget.
      System.cmd("rmmod", ["g_zero"], stderr_to_stdout: true)
      Process.sleep(300)

      {:ok, hp} = BodgeUSB.watch_hotplug(notify: self())
      flush_hotplug()

      try do
        # Scripted connect.
        assert {_, 0} = System.cmd("modprobe", ["g_zero"], stderr_to_stdout: true)
        assert_receive {:usb_hotplug, %{action: :add} = ev}, 5000
        assert is_integer(ev.busnum)
        assert is_integer(ev.devnum)

        # Scripted disconnect.
        assert {_, 0} = System.cmd("rmmod", ["g_zero"], stderr_to_stdout: true)
        assert_receive {:usb_hotplug, %{action: :remove}}, 5000
      after
        Hotplug.stop(hp)
      end
    end
  end

  defp flush_hotplug do
    receive do
      {:usb_hotplug, _} -> flush_hotplug()
    after
      0 -> :ok
    end
  end
end
