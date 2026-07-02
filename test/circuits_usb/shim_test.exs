defmodule CircuitsUsb.ShimTest do
  use ExUnit.Case, async: false

  alias CircuitsUsb.Shim

  describe "open/close/read/write on device files" do
    test "reads zeros from /dev/zero" do
      assert {:ok, h} = Shim.open("/dev/zero", [:rdonly])
      assert is_integer(Shim.fileno(h))
      assert {:ok, <<0, 0, 0, 0>>} = Shim.read(h, 4)
      assert :ok = Shim.close(h)
    end

    test "accepts a charlist path" do
      assert {:ok, h} = Shim.open(~c"/dev/zero", [:rdonly])
      assert :ok = Shim.close(h)
    end

    test "writes to /dev/null and reports the byte count" do
      assert {:ok, h} = Shim.open("/dev/null", [:wronly])
      assert {:ok, 5} = Shim.write(h, "hello")
      assert {:ok, 3} = Shim.write(h, [?a, "b", ?c])
      assert :ok = Shim.close(h)
    end

    test "read returns a possibly-short binary" do
      assert {:ok, h} = Shim.open("/dev/null", [:rdonly])
      # /dev/null is immediately EOF -> empty binary, not an error.
      assert {:ok, <<>>} = Shim.read(h, 128)
      assert :ok = Shim.close(h)
    end
  end

  describe "close semantics" do
    test "close is idempotent" do
      {:ok, h} = Shim.open("/dev/zero", [:rdonly])
      assert :ok = Shim.close(h)
      assert :ok = Shim.close(h)
    end

    test "read/write after close return :ebadf" do
      {:ok, h} = Shim.open("/dev/zero", [:rdonly])
      :ok = Shim.close(h)
      assert {:error, :ebadf} = Shim.read(h, 4)
      assert {:error, :ebadf} = Shim.write(h, "x")
      assert {:error, :ebadf} = Shim.fileno(h)
    end
  end

  describe "errno mapping" do
    test "missing path -> :enoent" do
      assert {:error, :enoent} = Shim.open("/no/such/usb/node", [:rdwr])
    end

    test "permission denied -> :eacces" do
      # /dev/mem exists but is not openable unprivileged.
      case Shim.open("/dev/mem", [:rdwr]) do
        {:error, :eacces} -> :ok
        # Some environments (running as root) may allow it; accept a handle too.
        {:ok, h} -> Shim.close(h)
        other -> flunk("unexpected: #{inspect(other)}")
      end
    end
  end

  describe "bad arguments raise ArgumentError (badarg), never crash" do
    test "unknown flag atom" do
      assert_raise ArgumentError, fn -> Shim.open("/dev/zero", [:bogus]) end
    end

    test "non-handle to read/close/write" do
      assert_raise ArgumentError, fn -> Shim.read(make_ref(), 4) end
      assert_raise ArgumentError, fn -> Shim.close(:not_a_handle) end
      assert_raise ArgumentError, fn -> Shim.write(self(), "x") end
    end

    test "non-integer count to read" do
      {:ok, h} = Shim.open("/dev/zero", [:rdonly])
      assert_raise ArgumentError, fn -> Shim.read(h, :lots) end
      Shim.close(h)
    end

    test "empty and oversized paths" do
      assert_raise ArgumentError, fn -> Shim.open("", [:rdwr]) end
      assert_raise ArgumentError, fn -> Shim.open(String.duplicate("a", 5000), [:rdwr]) end
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
        Enum.each(1..200, fn _ -> {:ok, _h} = Shim.open("/dev/null", [:rdonly]) end)
        :erlang.garbage_collect()
      end

      Process.sleep(50)
      leaked = fdcount.() - before
      assert leaked < 50, "leaked #{leaked} fds across 4000 open+drop+GC"
    end
  end

  describe "control_transfer marshalling (no device needed)" do
    test "a well-formed control ioctl reaches the kernel (ENOTTY on a non-usbfs fd)" do
      {:ok, h} = Shim.open("/dev/null", [:rdwr])
      # Marshalling + pointer fixup succeed; /dev/null just doesn't implement it.
      assert {:error, :enotty} = Shim.control_in(h, 0x06, 0x0100, 0x0000, 18, 100)
      assert {:error, :enotty} = Shim.control_out(h, 0x00, 0, 0, "abc", 100)
      assert {:error, :enotty} = Shim.set_interface(h, 0, 0)
      Shim.close(h)
    end

    test "oversized data/length is rejected before the syscall" do
      {:ok, h} = Shim.open("/dev/null", [:rdwr])
      assert_raise ArgumentError, fn -> Shim.control_in(h, 6, 0, 0, 70_000, 100) end
      big = :binary.copy(<<0>>, 70_000)
      assert_raise ArgumentError, fn -> Shim.control_out(h, 0, 0, 0, big, 100) end
      Shim.close(h)
    end

    test "out-of-range fields are rejected as badarg" do
      {:ok, h} = Shim.open("/dev/null", [:rdwr])
      assert_raise ArgumentError, fn -> Shim.control_transfer(h, 999, 6, 0, 0, 0, 100) end
      assert_raise ArgumentError, fn -> Shim.control_transfer(h, 0x80, 6, 0x10000, 0, 0, 100) end
      assert_raise ArgumentError, fn -> Shim.control_transfer(:nope, 0x80, 6, 0, 0, 0, 100) end
      Shim.close(h)
    end

    test "control on a closed handle returns :ebadf" do
      {:ok, h} = Shim.open("/dev/null", [:rdwr])
      :ok = Shim.close(h)
      assert {:error, :ebadf} = Shim.control_in(h, 6, 0x0100, 0, 18, 100)
      assert {:error, :ebadf} = Shim.set_interface(h, 0, 0)
    end
  end

  describe "bulk / claim marshalling (no device needed)" do
    test "well-formed bulk and claim ioctls reach the kernel (ENOTTY on /dev/null)" do
      {:ok, h} = Shim.open("/dev/null", [:rdwr])
      assert {:error, :enotty} = Shim.bulk_in(h, 0x81, 64, 100)
      assert {:error, :enotty} = Shim.bulk_out(h, 0x01, "data", 100)
      assert {:error, :enotty} = Shim.claim_interface(h, 0)
      assert {:error, :enotty} = Shim.release_interface(h, 0)
      Shim.close(h)
    end

    test "oversized bulk is rejected before the syscall" do
      {:ok, h} = Shim.open("/dev/null", [:rdwr])
      assert_raise ArgumentError, fn -> Shim.bulk_in(h, 0x81, 20_000_000, 100) end
      Shim.close(h)
    end

    test "bulk/claim on a closed handle return :ebadf" do
      {:ok, h} = Shim.open("/dev/null", [:rdwr])
      :ok = Shim.close(h)
      assert {:error, :ebadf} = Shim.bulk_in(h, 0x81, 64, 100)
      assert {:error, :ebadf} = Shim.claim_interface(h, 0)
    end
  end

  describe "driver detach ioctls (no device needed)" do
    test "get_driver/detach/attach reach the kernel (ENOTTY on /dev/null)" do
      {:ok, h} = Shim.open("/dev/null", [:rdwr])
      assert {:error, :enotty} = Shim.get_driver(h, 0)
      assert {:error, :enotty} = Shim.detach_driver(h, 0)
      assert {:error, :enotty} = Shim.attach_driver(h, 0)
      Shim.close(h)
    end

    test "bad args are badarg; closed handle is :ebadf" do
      {:ok, h} = Shim.open("/dev/null", [:rdwr])
      assert_raise ArgumentError, fn -> Shim.get_driver(h, :nope) end
      assert_raise ArgumentError, fn -> Shim.detach_driver(:nope, 0) end
      :ok = Shim.close(h)
      assert {:error, :ebadf} = Shim.get_driver(h, 0)
    end
  end

  describe "async primitives (no device needed)" do
    test "submit_bulk/interrupt reach the kernel (ENOTTY on /dev/null)" do
      {:ok, h} = Shim.open("/dev/null", [:rdwr])
      assert {:error, :enotty} = Shim.submit_bulk(h, 1, 0x81, 64)
      assert {:error, :enotty} = Shim.submit_interrupt(h, 2, 0x81, 64)
      Shim.close(h)
    end

    test "submit_urb rejects an unknown URB type as badarg" do
      {:ok, h} = Shim.open("/dev/null", [:rdwr])
      assert_raise ArgumentError, fn -> Shim.submit_urb(h, 1, 99, 0x81, 64) end
      Shim.close(h)
    end

    test "discard of an unknown tag is :enoent; reap of an idle fd is empty" do
      {:ok, h} = Shim.open("/dev/null", [:rdwr])
      assert {:error, :enoent} = Shim.discard(h, 12_345)
      assert [] = Shim.reap(h)
      Shim.close(h)
    end

    test "async ops on a closed handle return :ebadf / empty" do
      {:ok, h} = Shim.open("/dev/null", [:rdwr])
      :ok = Shim.close(h)
      assert {:error, :ebadf} = Shim.submit_bulk(h, 1, 0x81, 64)
      assert {:error, :ebadf} = Shim.discard(h, 1)
      assert {:error, :ebadf} = Shim.select(h, make_ref())
      assert [] = Shim.reap(h)
    end
  end

  # Integration against a real usbfs node (Part A A1). Set CIRCUITS_USB_TEST_NODE
  # to e.g. /dev/bus/usb/001/002. usbfs read() returns the cached descriptors;
  # the first 18 bytes are the device descriptor (bLength=18, bDescriptorType=1).
  describe "usbfs descriptor read" do
    @tag :usbfs
    test "reads a valid device descriptor" do
      node = System.get_env("CIRCUITS_USB_TEST_NODE") || flunk("set CIRCUITS_USB_TEST_NODE")
      assert {:ok, h} = Shim.open(node, [:rdwr])
      assert {:ok, <<blength, btype, _rest::binary>>} = Shim.read(h, 18)
      assert blength == 18
      assert btype == 1
      assert :ok = Shim.close(h)
    end

    # B2: a control IN transfer round-trips the data buffer. GET_DESCRIPTOR of
    # the device descriptor returns Gadget Zero's known pattern (bLength 18,
    # type 1, idVendor 0x0525, idProduct 0xa4a0), proving the usbdevfs_ctrltransfer
    # marshalling and the .data pointer fixup (kernel DMA into our buffer).
    @tag :usbfs
    test "control IN GET_DESCRIPTOR round-trips against the gadget-zero pattern" do
      node = System.get_env("CIRCUITS_USB_TEST_NODE") || flunk("set CIRCUITS_USB_TEST_NODE")
      {:ok, h} = Shim.open(node, [:rdwr])

      assert {:ok, desc} = Shim.control_in(h, 0x06, 0x0100, 0x0000, 18, 1000)
      assert byte_size(desc) == 18

      <<blength, btype, _bcd_usb::16, _cls, _sub, _proto, _mps0, vendor::little-16,
        product::little-16, _rest::binary>> = desc

      assert blength == 18
      assert btype == 1
      assert vendor == 0x0525
      assert product == 0xA4A0

      assert :ok = Shim.close(h)
    end
  end
end
