defmodule CircuitsUsb.AdversarialTest do
  use ExUnit.Case, async: false

  alias CircuitsUsb.Descriptor
  alias CircuitsUsb.Enumeration
  alias CircuitsUsb.Shim
  alias CircuitsUsb.Transfer

  # Live A3 raw-gadget adversarial device (dead:beef), one fault active per phase
  # (harness/vm/verify.sh). This checks the
  # library degrades safely against a *real* hostile device on the wire, not just
  # against synthetic descriptor blobs in descriptor_test.exs.
  defp a3_node do
    System.get_env("CIRCUITS_USB_TEST_NODE") || flunk("set CIRCUITS_USB_TEST_NODE")
  end

  describe "live A3 device" do
    @tag :usbfs_a3_stall
    test "stall-string: device/config parse, but a string read is a typed :epipe" do
      n = a3_node()

      # The device and configuration descriptors still parse into structs.
      assert {:ok, %Descriptor.Device{vendor_id: 0xDEAD, product_id: 0xBEEF} = dev} =
               Enumeration.read_descriptors(n)

      # Reading a string descriptor stalls -> a typed error, not a crash.
      {:ok, h} = Shim.open(n, [:rdwr])

      try do
        assert {:error, :epipe} = Enumeration.string(h, dev.product_index)
      after
        Shim.close(h)
      end
    end

    @tag :usbfs_a3_blength
    test "bad-device-blength: library rejects a device Linux happily enumerated" do
      n = a3_node()

      # Linux tolerates the over-large device-descriptor bLength and enumerates
      # the device, but the library's strict parser surfaces it as a typed error
      # rather than trusting a non-compliant descriptor.
      assert {:error, {:invalid_device_length, 0x40}} = Enumeration.read_descriptors(n)
    end

    @tag :usbfs_a3_slow
    test "slow: a short-timeout control transfer times out cleanly" do
      n = a3_node()
      {:ok, h} = Shim.open(n, [:rdwr])

      try do
        # A previous cancel in this phase may have left the device in its
        # recovery window (raw-gadget stalls new SETUPs while the stale one is
        # pending, ~900ms worst case); settle until it answers normally.
        assert {:ok, _} = settle(fn -> Shim.control_in(h, 0x06, 0x0100, 0, 18, 2000) end)

        # The device delays every descriptor response ~400ms; a live control
        # read with a 100ms timeout must return a typed error, not hang/crash.
        assert {:error, reason} = Shim.control_in(h, 0x06, 0x0100, 0, 18, 100)
        assert reason in [:etimedout, :etime, :eio]
      after
        Shim.close(h)
      end
    end

    @tag :usbfs_a3_slow
    test "slow: engine control timeout discards the URB; a retry then succeeds" do
      n = a3_node()
      {:ok, eng} = Transfer.start_link(node: n)

      try do
        assert {:ok, _} = settle(fn -> Transfer.control_in(eng, 0x06, 0x0100, 0, 18, 2000) end)

        # Engine-enforced timeout on an async control URB: the timer fires at
        # 100ms and the engine discards the URB, replying :timeout promptly
        # while staying fully operational.
        t0 = System.monotonic_time(:millisecond)
        assert {:error, :timeout} = Transfer.control_in(eng, 0x06, 0x0100, 0, 18, 100)
        assert System.monotonic_time(:millisecond) - t0 < 500
        assert Process.alive?(eng)

        # Until the device abandons the cancelled response (its ep0 watchdog,
        # <= sleep + watchdog ~900ms) raw-gadget stalls new SETUPs, so retries
        # may see :epipe first; within a couple of seconds one must succeed.
        # Timeout-then-retry is a recoverable sequence.
        assert {:ok, <<18, 1, _::binary>>} =
                 settle(fn -> Transfer.control_in(eng, 0x06, 0x0100, 0, 18, 2000) end)
      after
        Transfer.stop(eng)
      end
    end
  end

  # Retry a transfer until the device answers (it stalls SETUPs while a
  # cancelled exchange is still being abandoned). Returns the first success,
  # or the last error after ~3s of attempts.
  defp settle(fun, tries \\ 10) do
    case fun.() do
      {:ok, _} = ok ->
        ok

      {:error, _} = err when tries <= 1 ->
        err

      {:error, _} ->
        Process.sleep(300)
        settle(fun, tries - 1)
    end
  end
end
