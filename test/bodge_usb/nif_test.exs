# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0

defmodule BodgeUSB.NifTest do
  use ExUnit.Case, async: false

  alias BodgeUSB.Nif

  describe "open/close/read/write on device files" do
    test "reads zeros from /dev/zero" do
      assert {:ok, h} = Nif.open("/dev/zero", [:rdonly])
      assert is_integer(Nif.fileno(h))
      assert {:ok, <<0, 0, 0, 0>>} = Nif.read(h, 4)
      assert :ok = Nif.close(h)
    end

    test "accepts a charlist path" do
      assert {:ok, h} = Nif.open(~c"/dev/zero", [:rdonly])
      assert :ok = Nif.close(h)
    end

    test "writes to /dev/null and reports the byte count" do
      assert {:ok, h} = Nif.open("/dev/null", [:wronly])
      assert {:ok, 5} = Nif.write(h, "hello")
      assert {:ok, 3} = Nif.write(h, [?a, "b", ?c])
      assert :ok = Nif.close(h)
    end

    test "read returns a possibly-short binary" do
      assert {:ok, h} = Nif.open("/dev/null", [:rdonly])
      # /dev/null is immediately EOF -> empty binary, not an error.
      assert {:ok, <<>>} = Nif.read(h, 128)
      assert :ok = Nif.close(h)
    end
  end

  describe "close semantics" do
    test "close is idempotent" do
      {:ok, h} = Nif.open("/dev/zero", [:rdonly])
      assert :ok = Nif.close(h)
      assert :ok = Nif.close(h)
    end

    test "read/write after close return :ebadf" do
      {:ok, h} = Nif.open("/dev/zero", [:rdonly])
      :ok = Nif.close(h)
      assert {:error, :ebadf} = Nif.read(h, 4)
      assert {:error, :ebadf} = Nif.write(h, "x")
      assert {:error, :ebadf} = Nif.fileno(h)
    end
  end

  describe "errno mapping" do
    test "missing path -> :enoent" do
      assert {:error, :enoent} = Nif.open("/no/such/usb/node", [:rdwr])
    end

    test "permission denied -> :eacces" do
      # /dev/mem exists but is not openable unprivileged.
      case Nif.open("/dev/mem", [:rdwr]) do
        {:error, :eacces} -> :ok
        # Some environments (running as root) may allow it; accept a handle too.
        {:ok, h} -> Nif.close(h)
        other -> flunk("unexpected: #{inspect(other)}")
      end
    end
  end

  describe "bad arguments raise ArgumentError (badarg), never crash" do
    test "unknown flag atom" do
      assert_raise ArgumentError, fn -> Nif.open("/dev/zero", [:bogus]) end
    end

    test "non-handle to read/close/write" do
      assert_raise ArgumentError, fn -> Nif.read(make_ref(), 4) end
      assert_raise ArgumentError, fn -> Nif.close(:not_a_handle) end
      assert_raise ArgumentError, fn -> Nif.write(self(), "x") end
    end

    test "non-integer count to read" do
      {:ok, h} = Nif.open("/dev/zero", [:rdonly])
      assert_raise ArgumentError, fn -> Nif.read(h, :lots) end
      Nif.close(h)
    end

    test "empty and oversized paths" do
      assert_raise ArgumentError, fn -> Nif.open("", [:rdwr]) end
      assert_raise ArgumentError, fn -> Nif.open(String.duplicate("a", 5000), [:rdwr]) end
    end
  end

  describe "resource lifecycle" do
    test "dropped handles are closed on GC (no fd leak)" do
      fdcount = fn -> length(File.ls!("/proc/self/fd")) end
      before = fdcount.()

      # Open in rounds, dropping each handle without closing, and force GC after
      # each round. This proves the destructor reclaims dropped fds (live count
      # returns to baseline) without ever exceeding the open-file ulimit -- the
      # VM's is only 1024, so we keep at most ~200 handles live at a time while
      # still exercising 4000 total open+drop cycles.
      for _round <- 1..20 do
        Enum.each(1..200, fn _ -> {:ok, _h} = Nif.open("/dev/null", [:rdonly]) end)
        :erlang.garbage_collect()
      end

      Process.sleep(50)
      leaked = fdcount.() - before
      assert leaked < 50, "leaked #{leaked} fds across 4000 open+drop+GC"
    end
  end

  describe "submit_control marshalling (no device needed)" do
    test "a well-formed control URB reaches the kernel (ENOTTY on a non-usbfs fd)" do
      {:ok, h} = Nif.open("/dev/null", [:rdwr])
      # Marshalling + setup-packet layout succeed; /dev/null just doesn't
      # implement SUBMITURB.
      assert {:error, :enotty} = Nif.submit_control(h, 1, 0x80, 0x06, 0x0100, 0, 18)
      assert {:error, :enotty} = Nif.submit_control(h, 2, 0x00, 0x00, 0, 0, "abc")
      assert {:error, :enotty} = Nif.set_interface(h, 0, 0)
      Nif.close(h)
    end

    test "oversized data/length is rejected before the syscall" do
      {:ok, h} = Nif.open("/dev/null", [:rdwr])
      assert_raise ArgumentError, fn -> Nif.submit_control(h, 1, 0x80, 6, 0, 0, 70_000) end
      big = :binary.copy(<<0>>, 70_000)
      assert_raise ArgumentError, fn -> Nif.submit_control(h, 2, 0x00, 0, 0, 0, big) end
      Nif.close(h)
    end

    test "out-of-range fields are rejected as badarg" do
      {:ok, h} = Nif.open("/dev/null", [:rdwr])
      assert_raise ArgumentError, fn -> Nif.submit_control(h, 1, 999, 6, 0, 0, 0) end
      assert_raise ArgumentError, fn -> Nif.submit_control(h, 1, 0x80, 6, 0x10000, 0, 0) end
      assert_raise ArgumentError, fn -> Nif.submit_control(:nope, 1, 0x80, 6, 0, 0, 0) end
      Nif.close(h)
    end

    test "control submit on a closed handle returns :ebadf" do
      {:ok, h} = Nif.open("/dev/null", [:rdwr])
      :ok = Nif.close(h)
      assert {:error, :ebadf} = Nif.submit_control(h, 1, 0x80, 6, 0x0100, 0, 18)
      assert {:error, :ebadf} = Nif.set_interface(h, 0, 0)
    end
  end

  describe "claim marshalling (no device needed)" do
    test "claim/release ioctls reach the kernel (ENOTTY on /dev/null)" do
      {:ok, h} = Nif.open("/dev/null", [:rdwr])
      assert {:error, :enotty} = Nif.claim_interface(h, 0)
      assert {:error, :enotty} = Nif.release_interface(h, 0)
      Nif.close(h)
    end

    test "oversized bulk submit is rejected before the syscall" do
      {:ok, h} = Nif.open("/dev/null", [:rdwr])
      assert_raise ArgumentError, fn -> Nif.submit_bulk(h, 1, 0x81, 20_000_000) end
      Nif.close(h)
    end

    test "claim on a closed handle returns :ebadf" do
      {:ok, h} = Nif.open("/dev/null", [:rdwr])
      :ok = Nif.close(h)
      assert {:error, :ebadf} = Nif.claim_interface(h, 0)
    end
  end

  describe "driver detach ioctls (no device needed)" do
    test "get_driver/detach/attach reach the kernel (ENOTTY on /dev/null)" do
      {:ok, h} = Nif.open("/dev/null", [:rdwr])
      assert {:error, :enotty} = Nif.get_driver(h, 0)
      assert {:error, :enotty} = Nif.detach_driver(h, 0)
      assert {:error, :enotty} = Nif.attach_driver(h, 0)
      Nif.close(h)
    end

    test "bad args are badarg; closed handle is :ebadf" do
      {:ok, h} = Nif.open("/dev/null", [:rdwr])
      assert_raise ArgumentError, fn -> Nif.get_driver(h, :nope) end
      assert_raise ArgumentError, fn -> Nif.detach_driver(:nope, 0) end
      :ok = Nif.close(h)
      assert {:error, :ebadf} = Nif.get_driver(h, 0)
    end
  end

  describe "recovery ioctls (no device needed)" do
    test "clear_halt/reset reach the kernel (ENOTTY on /dev/null)" do
      {:ok, h} = Nif.open("/dev/null", [:rdwr])
      assert {:error, :enotty} = Nif.clear_halt(h, 0x81)
      assert {:error, :enotty} = Nif.reset(h)
      Nif.close(h)
    end

    test "closed handle is :ebadf; bad args are badarg" do
      {:ok, h} = Nif.open("/dev/null", [:rdwr])
      assert_raise ArgumentError, fn -> Nif.clear_halt(h, :nope) end
      :ok = Nif.close(h)
      assert {:error, :ebadf} = Nif.clear_halt(h, 0x81)
      assert {:error, :ebadf} = Nif.reset(h)
    end
  end

  describe "async primitives (no device needed)" do
    test "submit_bulk/interrupt reach the kernel (ENOTTY on /dev/null)" do
      {:ok, h} = Nif.open("/dev/null", [:rdwr])
      assert {:error, :enotty} = Nif.submit_bulk(h, 1, 0x81, 64)
      assert {:error, :enotty} = Nif.submit_interrupt(h, 2, 0x81, 64)
      Nif.close(h)
    end

    test "submit_urb rejects an unknown URB type and bad flags as badarg" do
      {:ok, h} = Nif.open("/dev/null", [:rdwr])
      assert_raise ArgumentError, fn -> Nif.submit_urb(h, 1, 99, 0x81, 64, 0) end
      # 0x40 (ZERO_PACKET) is the only allowed flag.
      assert_raise ArgumentError, fn -> Nif.submit_urb(h, 1, 3, 0x01, "x", 0x02) end
      Nif.close(h)
    end

    test "zero_packet flag is accepted and reaches the kernel" do
      {:ok, h} = Nif.open("/dev/null", [:rdwr])
      assert {:error, :enotty} = Nif.submit_bulk(h, 1, 0x01, "data", zero_packet: true)
      Nif.close(h)
    end

    test "submit_iso reaches the kernel and validates packet specs" do
      {:ok, h} = Nif.open("/dev/null", [:rdwr])
      assert {:error, :enotty} = Nif.submit_iso(h, 1, 0x81, [64, 64, 64], nil)
      # OUT total must equal the sum of packet lengths.
      assert_raise ArgumentError, fn -> Nif.submit_iso(h, 2, 0x01, [4, 4], <<1, 2, 3>>) end
      # at least one packet.
      assert_raise ArgumentError, fn -> Nif.submit_iso(h, 3, 0x81, [], nil) end
      Nif.close(h)
    end

    test "submit_iso boundary: 128 packets is the cap, per-packet length caps at 0xFFFF" do
      {:ok, h} = Nif.open("/dev/null", [:rdwr])
      # Exactly at the cap: marshalling succeeds and reaches the kernel.
      assert {:error, :enotty} = Nif.submit_iso(h, 1, 0x81, List.duplicate(64, 128), nil)
      # One past the cap is rejected before any syscall.
      assert_raise ArgumentError, fn ->
        Nif.submit_iso(h, 2, 0x81, List.duplicate(64, 129), nil)
      end

      # Per-packet length is bounded to a __u16.
      assert {:error, :enotty} = Nif.submit_iso(h, 3, 0x81, [0xFFFF], nil)
      assert_raise ArgumentError, fn -> Nif.submit_iso(h, 4, 0x81, [0x10000], nil) end
      Nif.close(h)
    end

    test "discard of an unknown tag is :enoent; reap of an idle fd is empty" do
      {:ok, h} = Nif.open("/dev/null", [:rdwr])
      assert {:error, :enoent} = Nif.discard(h, 12_345)
      assert [] = Nif.reap(h)
      Nif.close(h)
    end

    test "async ops on a closed handle return :ebadf / empty" do
      {:ok, h} = Nif.open("/dev/null", [:rdwr])
      :ok = Nif.close(h)
      assert {:error, :ebadf} = Nif.submit_bulk(h, 1, 0x81, 64)
      assert {:error, :ebadf} = Nif.discard(h, 1)
      assert {:error, :ebadf} = Nif.select(h, make_ref())
      assert [] = Nif.reap(h)
    end
  end

  # Integration against a real usbfs node. Set BODGE_USB_TEST_NODE
  # to e.g. /dev/bus/usb/001/002. usbfs read() returns the cached descriptors;
  # the first 18 bytes are the device descriptor (bLength=18, bDescriptorType=1).
  describe "usbfs descriptor read" do
    @tag :usbfs
    test "reads a valid device descriptor" do
      node = System.get_env("BODGE_USB_TEST_NODE") || flunk("set BODGE_USB_TEST_NODE")
      assert {:ok, h} = Nif.open(node, [:rdwr])
      assert {:ok, <<blength, btype, _rest::binary>>} = Nif.read(h, 18)
      assert blength == 18
      assert btype == 1
      assert :ok = Nif.close(h)
    end

    # A control IN transfer round-trips the data buffer, driven at the raw NIF
    # tier (submit -> select -> reap, the discipline BodgeUSB automates).
    # GET_DESCRIPTOR of the device descriptor returns Gadget Zero's known
    # pattern (bLength 18, type 1, idVendor 0x0525, idProduct 0xa4a0), proving
    # the setup-packet marshalling and the kernel DMA into our buffer.
    @tag :usbfs
    test "raw submit/select/reap control IN round-trips the gadget-zero pattern" do
      node = System.get_env("BODGE_USB_TEST_NODE") || flunk("set BODGE_USB_TEST_NODE")
      {:ok, h} = Nif.open(node, [:rdwr])

      ref = make_ref()
      assert :ok = Nif.submit_control(h, 1, 0x80, 0x06, 0x0100, 0x0000, 18)
      assert :ok = Nif.select(h, ref)
      assert_receive {:select, _handle, ^ref, :ready_output}, 2000
      assert [{1, :ok, desc}] = Nif.reap(h)
      assert byte_size(desc) == 18

      <<blength, btype, _bcd_usb::16, _cls, _sub, _proto, _mps0, vendor::little-16,
        product::little-16, _rest::binary>> = desc

      assert blength == 18
      assert btype == 1
      assert vendor == 0x0525
      assert product == 0xA4A0

      assert :ok = Nif.close(h)
    end
  end
end
