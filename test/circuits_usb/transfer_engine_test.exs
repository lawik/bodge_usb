defmodule CircuitsUsb.TransferEngineTest do
  use ExUnit.Case, async: false

  alias CircuitsUsb.Enumeration
  alias CircuitsUsb.Transfer

  describe "engine plumbing (no device)" do
    test "starts on a node, and a submit that the kernel rejects surfaces the errno" do
      {:ok, eng} = Transfer.start_link(node: "/dev/null")
      # /dev/null is not usbfs, so SUBMITURB fails with ENOTTY -- surfaced, not a crash.
      assert {:error, :enotty} = Transfer.bulk_in(eng, 0x81, 64, 500)
      assert :ok = Transfer.stop(eng)
    end

    test "start fails cleanly for a missing node" do
      Process.flag(:trap_exit, true)
      assert {:error, :enoent} = Transfer.start_link(node: "/no/such/node")
    end
  end

  # Integration against gadget-zero source/sink (usbtest removed by verify.sh).
  describe "against gadget zero" do
    @tag :usbfs
    test "sustained concurrent bulk IN throughput, all complete correctly" do
      node = System.get_env("CIRCUITS_USB_TEST_NODE") || flunk("set CIRCUITS_USB_TEST_NODE")
      {:ok, dev} = Enumeration.read_descriptors(node)
      {iface, ep_in, _ep_out} = find_bulk_pair(dev) || flunk("no bulk pair")

      {:ok, eng} = Transfer.start_link(node: node)

      try do
        assert :ok = Transfer.claim_interface(eng, iface)

        # Many concurrent transfers pipelined through the one engine/fd.
        results =
          1..300
          |> Task.async_stream(fn _ -> Transfer.bulk_in(eng, ep_in, 4096, 2000) end,
            max_concurrency: 32,
            timeout: 15_000
          )
          |> Enum.map(fn {:ok, r} -> r end)

        assert length(results) == 300
        assert Enum.all?(results, &match?({:ok, <<_::4096-bytes>>}, &1))
      after
        Transfer.release_interface(eng, iface)
        Transfer.stop(eng)
      end
    end

    @tag :usbfs
    test "a slow transfer times out, and the engine stays healthy" do
      node = System.get_env("CIRCUITS_USB_TEST_NODE") || flunk("set CIRCUITS_USB_TEST_NODE")
      {:ok, dev} = Enumeration.read_descriptors(node)
      {iface, ep_in, _ep_out} = find_bulk_pair(dev) || flunk("no bulk pair")

      {:ok, eng} = Transfer.start_link(node: node)

      try do
        :ok = Transfer.claim_interface(eng, iface)

        # A 1 MB bulk IN takes ~40ms through dummy_hcd; a 10 ms timeout fires
        # first, so the engine cancels (discard) the URB and reports :timeout.
        assert {:error, :timeout} = Transfer.bulk_in(eng, ep_in, 1_048_576, 10)

        # The engine is still usable after a timed-out transfer.
        assert {:ok, <<_::4096-bytes>>} = Transfer.bulk_in(eng, ep_in, 4096, 2000)
      after
        Transfer.release_interface(eng, iface)
        Transfer.stop(eng)
      end
    end

    @tag :usbfs
    test "bulk OUT then IN through the engine" do
      node = System.get_env("CIRCUITS_USB_TEST_NODE") || flunk("set CIRCUITS_USB_TEST_NODE")
      {:ok, dev} = Enumeration.read_descriptors(node)
      {iface, ep_in, ep_out} = find_bulk_pair(dev) || flunk("no bulk pair")

      {:ok, eng} = Transfer.start_link(node: node)

      try do
        :ok = Transfer.claim_interface(eng, iface)
        {:ok, data} = Transfer.bulk_in(eng, ep_in, 4096, 2000)
        assert {:ok, 4096} = Transfer.bulk_out(eng, ep_out, data, 2000)
      after
        Transfer.release_interface(eng, iface)
        Transfer.stop(eng)
      end
    end
  end

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
