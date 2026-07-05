# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0

defmodule BodgeUSB.EngineTest do
  use ExUnit.Case, async: false

  import BodgeUSB.TestHelpers

  alias BodgeUSB.Enumeration

  describe "engine plumbing (no device)" do
    test "starts on a node, and a submit that the kernel rejects surfaces the errno" do
      {:ok, eng} = BodgeUSB.start_link(node: "/dev/null")
      # /dev/null is not usbfs, so SUBMITURB fails with ENOTTY -- surfaced, not a crash.
      assert {:error, :enotty} = BodgeUSB.bulk_in(eng, 0x81, 64, 500)
      assert :ok = BodgeUSB.close(eng)
    end

    test "start fails cleanly for a missing node" do
      Process.flag(:trap_exit, true)
      assert {:error, :enoent} = BodgeUSB.start_link(node: "/no/such/node")
    end

    test "invalid timeouts raise at the call site, never mean wait-forever" do
      {:ok, eng} = BodgeUSB.start_link(node: "/dev/null")

      # apply/3 keeps the deliberately-wrong types away from the compiler's
      # type checker; the guards must reject them at runtime.
      try do
        for {fun, args} <- [
              {:bulk_in, [eng, 0x81, 64, -1]},
              # 0 is no longer a spelling of "no timeout"; :infinity is.
              {:bulk_in, [eng, 0x81, 64, 0]},
              {:bulk_out, [eng, 0x01, "x", 1.5]},
              {:interrupt_in, [eng, 0x81, 8, :forever]},
              {:control_in, [eng, 0x06, 0x0100, 0, 18, -100]}
            ] do
          assert_raise FunctionClauseError, fn -> apply(BodgeUSB, fun, args) end
        end
      after
        BodgeUSB.close(eng)
      end
    end

    test "a direction/payload mismatch raises in the caller, never reaches the engine" do
      {:ok, eng} = BodgeUSB.start_link(node: "/dev/null")

      try do
        # OUT endpoint address with an IN-style length, and vice versa.
        assert_raise ArgumentError, fn -> BodgeUSB.bulk_in(eng, 0x02, 512, 500) end
        assert_raise ArgumentError, fn -> BodgeUSB.bulk_out(eng, 0x81, "data", 500) end
        assert_raise ArgumentError, fn -> BodgeUSB.interrupt_out(eng, 0x81, "data", 500) end
        # The engine never saw any of it and keeps serving.
        assert {:error, :enotty} = BodgeUSB.bulk_in(eng, 0x81, 64, 500)
      after
        BodgeUSB.close(eng)
      end
    end

    test "submit/3 surfaces submission errors synchronously and validates its input" do
      {:ok, eng} = BodgeUSB.start_link(node: "/dev/null")

      try do
        # A refused submission returns the error at once: no ref, no message.
        assert {:error, :enotty} = BodgeUSB.submit(eng, {:bulk_in, 0x81, 64})
        refute_receive {:bodge_usb, _, _}, 50

        # Unknown request shapes raise in the caller.
        assert_raise ArgumentError, fn -> BodgeUSB.submit(eng, {:warp_drive, 0x81, 64}) end

        # Bad options raise at the call site.
        assert_raise ArgumentError, fn ->
          BodgeUSB.submit(eng, {:bulk_in, 0x81, 64}, timeout: -5)
        end

        assert_raise ArgumentError, fn ->
          BodgeUSB.submit(eng, {:bulk_in, 0x81, 64}, reply_to: :not_a_pid)
        end

        # Cancelling a ref the engine does not know is a typed error.
        assert {:error, :not_found} = BodgeUSB.cancel(eng, make_ref())
      after
        BodgeUSB.close(eng)
      end
    end
  end

  # Integration against gadget-zero source/sink (usbtest removed by verify.sh).
  describe "against gadget zero" do
    @tag :usbfs
    test "sustained concurrent bulk IN throughput, all complete correctly" do
      node = System.get_env("BODGE_USB_TEST_NODE") || flunk("set BODGE_USB_TEST_NODE")
      {:ok, dev} = Enumeration.read_descriptors(node)
      {iface, ep_in, _ep_out} = find_bulk_pair(dev) || flunk("no bulk pair")

      {:ok, eng} = BodgeUSB.start_link(node: node)

      try do
        assert :ok = BodgeUSB.claim_interface(eng, iface)

        # Many concurrent transfers pipelined through the one engine/fd.
        results =
          1..300
          |> Task.async_stream(fn _ -> BodgeUSB.bulk_in(eng, ep_in, 4096, 2000) end,
            max_concurrency: 32,
            timeout: 15_000
          )
          |> Enum.map(fn {:ok, r} -> r end)

        assert length(results) == 300
        assert Enum.all?(results, &match?({:ok, <<_::4096-bytes>>}, &1))
      after
        BodgeUSB.release_interface(eng, iface)
        BodgeUSB.close(eng)
      end
    end

    @tag :usbfs
    test "a slow transfer times out, and the engine stays healthy" do
      node = System.get_env("BODGE_USB_TEST_NODE") || flunk("set BODGE_USB_TEST_NODE")
      {:ok, dev} = Enumeration.read_descriptors(node)
      {iface, ep_in, _ep_out} = find_bulk_pair(dev) || flunk("no bulk pair")

      {:ok, eng} = BodgeUSB.start_link(node: node)

      try do
        :ok = BodgeUSB.claim_interface(eng, iface)

        # A 1 MB bulk IN takes ~40ms through dummy_hcd; a 10 ms timeout fires
        # first, so the engine cancels (discard) the URB and reports :timeout.
        assert {:error, :timeout} = BodgeUSB.bulk_in(eng, ep_in, 1_048_576, 10)

        # The engine is still usable after a timed-out transfer.
        assert {:ok, <<_::4096-bytes>>} = BodgeUSB.bulk_in(eng, ep_in, 4096, 2000)
      after
        BodgeUSB.release_interface(eng, iface)
        BodgeUSB.close(eng)
      end
    end

    @tag :usbfs
    test "bulk OUT then IN through the engine, incl. a terminating zero packet" do
      node = System.get_env("BODGE_USB_TEST_NODE") || flunk("set BODGE_USB_TEST_NODE")
      {:ok, dev} = Enumeration.read_descriptors(node)
      {iface, ep_in, ep_out} = find_bulk_pair(dev) || flunk("no bulk pair")

      {:ok, eng} = BodgeUSB.start_link(node: node)

      try do
        :ok = BodgeUSB.claim_interface(eng, iface)
        {:ok, data} = BodgeUSB.bulk_in(eng, ep_in, 4096, 2000)
        assert {:ok, 4096} = BodgeUSB.bulk_out(eng, ep_out, data, 2000)
        # ZLP (USBFS_URB_ZERO_PACKET) on a multiple-of-maxpacket OUT.
        assert {:ok, 4096} = BodgeUSB.bulk_out(eng, ep_out, data, 2000, zero_packet: true)
      after
        BodgeUSB.release_interface(eng, iface)
        BodgeUSB.close(eng)
      end
    end

    @tag :usbfs
    test "control OUT with a data stage round-trips through the engine (vendor 0x5b/0x5c)" do
      node = System.get_env("BODGE_USB_TEST_NODE") || flunk("set BODGE_USB_TEST_NODE")
      {:ok, eng} = BodgeUSB.start_link(node: node)

      try do
        # f_sourcesink implements usbtest's vendor requests: 0x5b stores the
        # control-OUT data stage, 0x5c returns it. This exercises the async
        # control URB's OUT marshalling and IN read-back byte-exact (no
        # interface claim needed; it is all ep0).
        data = for i <- 0..63, into: <<>>, do: <<i>>
        assert {:ok, 64} = BodgeUSB.control_transfer(eng, 0x40, 0x5B, 0, 0, data, 1000)
        assert {:ok, ^data} = BodgeUSB.control_transfer(eng, 0xC0, 0x5C, 0, 0, 64, 1000)
      after
        BodgeUSB.close(eng)
      end
    end

    @tag :usbfs
    test "mixed IN/OUT/control concurrency with a cancel storm leaves the engine consistent" do
      node = System.get_env("BODGE_USB_TEST_NODE") || flunk("set BODGE_USB_TEST_NODE")
      {:ok, dev} = Enumeration.read_descriptors(node)
      {iface, ep_in, ep_out} = find_bulk_pair(dev) || flunk("no bulk pair")

      {:ok, eng} = BodgeUSB.start_link(node: node)

      try do
        :ok = BodgeUSB.claim_interface(eng, iface)
        {:ok, pattern} = BodgeUSB.bulk_in(eng, ep_in, 4096, 2000)

        results =
          1..120
          |> Task.async_stream(
            fn i ->
              case rem(i, 4) do
                0 -> {:in, BodgeUSB.bulk_in(eng, ep_in, 4096, 3000)}
                1 -> {:out, BodgeUSB.bulk_out(eng, ep_out, pattern, 3000)}
                2 -> {:ctrl, BodgeUSB.control_in(eng, 0x06, 0x0100, 0, 18, 3000)}
                # 256 KB takes ~10ms through dummy_hcd; a 5ms timeout races
                # completion, so both outcomes are legal (a raced :ok must
                # deliver the data, never drop it).
                3 -> {:cancel, BodgeUSB.bulk_in(eng, ep_in, 262_144, 5)}
              end
            end,
            max_concurrency: 40,
            timeout: 20_000
          )
          |> Enum.map(fn {:ok, r} -> r end)

        for {kind, r} <- results do
          case kind do
            :in -> assert {:ok, <<_::4096-bytes>>} = r
            :out -> assert {:ok, 4096} = r
            :ctrl -> assert {:ok, <<18, 1, _::binary>>} = r
            :cancel -> assert r == {:error, :timeout} or match?({:ok, <<_::262_144-bytes>>}, r)
          end
        end

        # Nothing leaked in the pending map; the engine still serves transfers.
        assert {:ok, <<_::512-bytes>>} = BodgeUSB.bulk_in(eng, ep_in, 512, 2000)
      after
        BodgeUSB.release_interface(eng, iface)
        BodgeUSB.close(eng)
      end
    end

    @tag :usbfs
    test "repeated open/claim/transfer/close cycles do not leak fds" do
      node = System.get_env("BODGE_USB_TEST_NODE") || flunk("set BODGE_USB_TEST_NODE")
      {:ok, dev} = Enumeration.read_descriptors(node)
      {iface, ep_in, _ep_out} = find_bulk_pair(dev) || flunk("no bulk pair")

      fdcount = fn -> length(File.ls!("/proc/self/fd")) end
      before = fdcount.()

      for _ <- 1..50 do
        {:ok, eng} = BodgeUSB.start_link(node: node)
        :ok = BodgeUSB.claim_interface(eng, iface)
        {:ok, <<_::4096-bytes>>} = BodgeUSB.bulk_in(eng, ep_in, 4096, 2000)
        :ok = BodgeUSB.release_interface(eng, iface)
        :ok = BodgeUSB.close(eng)
      end

      # The select-stop teardown closes the fd from the poller thread; give the
      # last one a moment before counting.
      Process.sleep(100)
      leaked = fdcount.() - before
      assert leaked < 5, "leaked #{leaked} fds across 50 engine open/close cycles"
    end

    @tag :usbfs
    test "async submit: completions arrive as messages, cancel works, dead receivers clean up" do
      node = System.get_env("BODGE_USB_TEST_NODE") || flunk("set BODGE_USB_TEST_NODE")
      {:ok, dev} = Enumeration.read_descriptors(node)
      {iface, ep_in, _ep_out} = find_bulk_pair(dev) || flunk("no bulk pair")

      {:ok, eng} = BodgeUSB.start_link(node: node)

      try do
        :ok = BodgeUSB.claim_interface(eng, iface)

        # One process pipelines many transfers without blocking; completions
        # come back as messages tagged with each submit's ref.
        refs =
          for _ <- 1..16 do
            {:ok, ref} = BodgeUSB.submit(eng, {:bulk_in, ep_in, 4096}, timeout: 3000)
            ref
          end

        for ref <- refs do
          assert_receive {:bodge_usb, ^ref, {:ok, <<_::4096-bytes>>}}, 3000
        end

        # await/3 is the blocking convenience over the same mechanism.
        {:ok, ref} = BodgeUSB.submit(eng, {:bulk_in, ep_in, 512}, timeout: 2000)
        assert {:ok, <<_::512-bytes>>} = BodgeUSB.await(eng, ref, 3000)

        # Explicit cancel of an in-flight slow transfer: the completion still
        # arrives, as :cancelled (or the real data if the cancel raced it).
        {:ok, slow} = BodgeUSB.submit(eng, {:bulk_in, ep_in, 1_048_576})
        assert :ok = BodgeUSB.cancel(eng, slow)
        assert_receive {:bodge_usb, ^slow, result}, 3000
        assert result == {:error, :cancelled} or match?({:ok, _}, result)

        # A dead reply_to must not strand its URB: the engine discards it and
        # keeps serving (the submission had no timeout, so only the receiver
        # monitor can clean it up).
        victim = spawn(fn -> Process.sleep(:infinity) end)
        {:ok, _orphan} = BodgeUSB.submit(eng, {:bulk_in, ep_in, 1_048_576}, reply_to: victim)
        Process.exit(victim, :kill)
        assert {:ok, <<_::512-bytes>>} = BodgeUSB.bulk_in(eng, ep_in, 512, 2000)
      after
        BodgeUSB.release_interface(eng, iface)
        BodgeUSB.close(eng)
      end
    end

    @tag :usbfs
    test "stopping the engine mid-transfer replies :closed (no caller crash)" do
      node = System.get_env("BODGE_USB_TEST_NODE") || flunk("set BODGE_USB_TEST_NODE")
      {:ok, dev} = Enumeration.read_descriptors(node)
      {iface, ep_in, _ep_out} = find_bulk_pair(dev) || flunk("no bulk pair")

      {:ok, eng} = BodgeUSB.start_link(node: node)
      :ok = BodgeUSB.claim_interface(eng, iface)

      # A slow read with no timeout; stopping the engine must reply, not crash us.
      task = Task.async(fn -> BodgeUSB.bulk_in(eng, ep_in, 1_048_576, :infinity) end)
      Process.sleep(3)
      assert :ok = BodgeUSB.close(eng)
      assert {:error, :closed} = Task.await(task, 5000)
    end
  end
end
