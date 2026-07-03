defmodule CircuitsUsb.TransferTest do
  use ExUnit.Case, async: false

  alias CircuitsUsb.Enumeration
  alias CircuitsUsb.Shim

  # Integration against the live gadget-zero source/sink (harness A2, no usbtest
  # bound so we can claim the interface ourselves). Set CIRCUITS_USB_TEST_NODE.
  describe "bulk source/sink against gadget zero" do
    @tag :usbfs
    test "claim + bulk IN/OUT round-trips the device's pattern" do
      node = System.get_env("CIRCUITS_USB_TEST_NODE") || flunk("set CIRCUITS_USB_TEST_NODE")
      {:ok, dev} = Enumeration.read_descriptors(node)
      {iface, ep_in, ep_out} = find_bulk_pair(dev) || flunk("no bulk in/out pair found")

      {:ok, h} = Shim.open(node, [:rdwr])

      try do
        assert :ok = Shim.claim_interface(h, iface)

        # Source endpoint produces the device's pattern.
        assert {:ok, data} = Shim.bulk_in(h, ep_in, 4096, 1000)
        assert byte_size(data) == 4096

        # Writing those exact bytes back to the sink matches whatever pattern the
        # gadget is checking for (source and sink share it), so no stall -- this
        # is the pattern-verified source/sink exchange usbtest also performs.
        assert {:ok, 4096} = Shim.bulk_out(h, ep_out, data, 1000)

        # A second read is consistent with the first (same per-buffer pattern).
        assert {:ok, ^data} = Shim.bulk_in(h, ep_in, 4096, 1000)
      after
        Shim.release_interface(h, iface)
        Shim.close(h)
      end
    end
  end

  describe "raw async submit/select/reap against gadget zero" do
    @tag :usbfs
    test "a bulk IN URB completes via select + reap" do
      node = System.get_env("CIRCUITS_USB_TEST_NODE") || flunk("set CIRCUITS_USB_TEST_NODE")
      {:ok, dev} = Enumeration.read_descriptors(node)
      {iface, ep_in, _ep_out} = find_bulk_pair(dev) || flunk("no bulk pair")

      {:ok, h} = Shim.open(node, [:rdwr])

      try do
        :ok = Shim.claim_interface(h, iface)
        ref = make_ref()
        assert :ok = Shim.submit_bulk(h, 42, ep_in, 4096)
        assert :ok = Shim.select(h, ref)

        assert_receive {:select, _handle, ^ref, :ready_output}, 2000

        assert [{42, :ok, data}] = Shim.reap(h)
        assert byte_size(data) == 4096
      after
        Shim.release_interface(h, iface)
        Shim.close(h)
      end
    end

    @tag :usbfs
    test "an in-flight bulk URB can be cancelled with discard" do
      node = System.get_env("CIRCUITS_USB_TEST_NODE") || flunk("set CIRCUITS_USB_TEST_NODE")
      {:ok, dev} = Enumeration.read_descriptors(node)
      {iface, ep_in, _ep_out} = find_bulk_pair(dev) || flunk("no bulk pair")

      {:ok, h} = Shim.open(node, [:rdwr])

      try do
        :ok = Shim.claim_interface(h, iface)
        ref = make_ref()

        # A 1 MB read is in flight for ~40ms; cancel it right after submit.
        assert :ok = Shim.submit_bulk(h, 7, ep_in, 1_048_576)
        assert :ok = Shim.discard(h, 7)
        assert :ok = Shim.select(h, ref)

        assert_receive {:select, _handle, ^ref, :ready_output}, 2000

        # The cancelled URB is delivered with a non-:ok (reset) status.
        assert [{7, status, _payload}] = Shim.reap(h)
        assert status != :ok
      after
        Shim.release_interface(h, iface)
        Shim.close(h)
      end
    end
  end

  describe "close during a blocking sync transfer (deferred close)" do
    @tag :usbfs
    test "close returns immediately, the in-flight ioctl finishes, then the fd tears down" do
      node = System.get_env("CIRCUITS_USB_TEST_NODE") || flunk("set CIRCUITS_USB_TEST_NODE")
      {:ok, dev} = Enumeration.read_descriptors(node)
      {iface, ep_in, _ep_out} = find_bulk_pair(dev) || flunk("no bulk pair")

      {:ok, h} = Shim.open(node, [:rdwr])
      :ok = Shim.claim_interface(h, iface)

      # 1 MB is ~40ms through dummy_hcd (and small enough for proc_bulk's
      # contiguous kmalloc): a real window to close mid-ioctl.
      task = Task.async(fn -> Shim.bulk_in(h, ep_in, 1_048_576, 3000) end)
      Process.sleep(10)

      # Deferred close: returns :ok at once, refuses new work, and must NOT
      # close the fd out from under the blocked ioctl.
      assert :ok = Shim.close(h)
      assert {:error, :ebadf} = Shim.bulk_in(h, ep_in, 64, 100)

      # The in-flight transfer still completes (or fails typed), never crashes.
      assert match?({:ok, _}, Task.await(task, 5000))

      # Once the blocking ioctl ended, the deferred teardown ran.
      assert {:error, :ebadf} = Shim.read(h, 4)
      assert {:error, :ebadf} = Shim.fileno(h)
    end
  end

  # First interface exposing both a bulk IN and a bulk OUT endpoint.
  defp find_bulk_pair(dev) do
    Enum.find_value(dev.configurations, fn c ->
      Enum.find_value(c.interfaces, fn i ->
        ep_in = Enum.find(i.endpoints, &(&1.transfer_type == :bulk and &1.direction == :in))
        ep_out = Enum.find(i.endpoints, &(&1.transfer_type == :bulk and &1.direction == :out))
        if ep_in && ep_out, do: {i.number, ep_in.address, ep_out.address}
      end)
    end)
  end
end
