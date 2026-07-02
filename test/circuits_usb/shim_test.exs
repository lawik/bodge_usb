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

      # Open many handles and drop each immediately without closing.
      Enum.each(1..3000, fn _ -> {:ok, _h} = Shim.open("/dev/null", [:rdonly]) end)
      :erlang.garbage_collect()
      Process.sleep(50)

      leaked = fdcount.() - before
      assert leaked < 50, "leaked #{leaked} fds across 3000 open+drop+GC"
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
  end
end
