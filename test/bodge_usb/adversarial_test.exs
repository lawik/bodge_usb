# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0

defmodule BodgeUSB.AdversarialTest do
  use ExUnit.Case, async: false

  alias BodgeUSB.Descriptor
  alias BodgeUSB.Enumeration

  # Live raw-gadget adversarial device (dead:beef, harness a3_device), one
  # fault active per phase (harness/vm/verify.sh). This checks the library
  # degrades safely against a *real* hostile device on the wire, not just
  # against synthetic descriptor blobs in descriptor_test.exs.
  defp a3_node do
    System.get_env("BODGE_USB_TEST_NODE") || flunk("set BODGE_USB_TEST_NODE")
  end

  describe "live adversarial device" do
    @tag :usbfs_a3_stall
    test "stall-string: device/config parse, but a string read is a typed :epipe" do
      n = a3_node()

      # The device and configuration descriptors still parse into structs.
      assert {:ok, %Descriptor.Device{vendor_id: 0xDEAD, product_id: 0xBEEF} = dev} =
               Enumeration.read_descriptors(n)

      # Reading a string descriptor stalls -> a typed error, not a crash.
      {:ok, eng} = BodgeUSB.open(n)

      try do
        assert {:error, :epipe} = BodgeUSB.string(eng, dev.product_index)
      after
        BodgeUSB.close(eng)
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
    test "slow: engine control timeout discards the URB; a retry then succeeds" do
      n = a3_node()
      {:ok, eng} = BodgeUSB.start_link(node: n)

      try do
        assert {:ok, _} = settle(fn -> BodgeUSB.control_in(eng, 0x06, 0x0100, 0, 18, 2000) end)

        # Engine-enforced timeout on an async control URB: the timer fires at
        # 100ms and the engine discards the URB, replying :timeout promptly
        # while staying fully operational.
        t0 = System.monotonic_time(:millisecond)
        assert {:error, :timeout} = BodgeUSB.control_in(eng, 0x06, 0x0100, 0, 18, 100)
        assert System.monotonic_time(:millisecond) - t0 < 500
        assert Process.alive?(eng)

        # Until the device abandons the cancelled response (its ep0 watchdog,
        # <= sleep + watchdog ~900ms) raw-gadget stalls new SETUPs, so retries
        # may see :epipe first; within a couple of seconds one must succeed.
        # Timeout-then-retry is a recoverable sequence.
        assert {:ok, <<18, 1, _::binary>>} =
                 settle(fn -> BodgeUSB.control_in(eng, 0x06, 0x0100, 0, 18, 2000) end)
      after
        BodgeUSB.close(eng)
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
