# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0

defmodule BodgeUSB.RawEngineTest do
  use ExUnit.Case, async: false

  import BodgeUSB.TestHelpers

  alias BodgeUSB.Enumeration
  alias BodgeUSB.Nif

  # Integration against the live gadget-zero source/sink (no usbtest bound so
  # the interface can be claimed). Set BODGE_USB_TEST_NODE.
  describe "bulk source/sink through the engine" do
    @tag :usbfs
    test "claim + bulk IN/OUT round-trips the device's pattern" do
      node = System.get_env("BODGE_USB_TEST_NODE") || flunk("set BODGE_USB_TEST_NODE")
      {:ok, dev} = Enumeration.read_descriptors(node)
      {iface, ep_in, ep_out} = find_bulk_pair(dev) || flunk("no bulk in/out pair found")

      {:ok, eng} = BodgeUSB.open(node)

      try do
        assert :ok = BodgeUSB.claim_interface(eng, iface)

        # Source endpoint produces the device's pattern.
        assert {:ok, data} = BodgeUSB.bulk_in(eng, ep_in, 4096, 1000)
        assert byte_size(data) == 4096

        # Writing those exact bytes back to the sink matches whatever pattern
        # the gadget is checking for (source and sink share it), so no stall.
        assert {:ok, 4096} = BodgeUSB.bulk_out(eng, ep_out, data, 1000)

        # A second read is consistent with the first (same per-buffer pattern).
        assert {:ok, ^data} = BodgeUSB.bulk_in(eng, ep_in, 4096, 1000)
      after
        BodgeUSB.release_interface(eng, iface)
        BodgeUSB.close(eng)
      end
    end
  end

  # The raw NIF discipline BodgeUSB automates: submit -> select -> reap.
  describe "raw async submit/select/reap against gadget zero" do
    @tag :usbfs
    test "a bulk IN URB completes via select + reap" do
      node = System.get_env("BODGE_USB_TEST_NODE") || flunk("set BODGE_USB_TEST_NODE")
      {:ok, dev} = Enumeration.read_descriptors(node)
      {iface, ep_in, _ep_out} = find_bulk_pair(dev) || flunk("no bulk pair")

      {:ok, h} = Nif.open(node, [:rdwr])

      try do
        :ok = Nif.claim_interface(h, iface)
        ref = make_ref()
        assert :ok = Nif.submit_bulk(h, 42, ep_in, 4096)
        assert :ok = Nif.select(h, ref)

        assert_receive {:select, _handle, ^ref, :ready_output}, 2000

        assert [{42, :ok, data}] = Nif.reap(h)
        assert byte_size(data) == 4096
      after
        Nif.release_interface(h, iface)
        Nif.close(h)
      end
    end

    @tag :usbfs
    test "an in-flight bulk URB can be cancelled with discard" do
      node = System.get_env("BODGE_USB_TEST_NODE") || flunk("set BODGE_USB_TEST_NODE")
      {:ok, dev} = Enumeration.read_descriptors(node)
      {iface, ep_in, _ep_out} = find_bulk_pair(dev) || flunk("no bulk pair")

      {:ok, h} = Nif.open(node, [:rdwr])

      try do
        :ok = Nif.claim_interface(h, iface)
        ref = make_ref()

        # A 1 MB read is in flight for ~40ms; cancel it right after submit.
        assert :ok = Nif.submit_bulk(h, 7, ep_in, 1_048_576)
        assert :ok = Nif.discard(h, 7)
        assert :ok = Nif.select(h, ref)

        assert_receive {:select, _handle, ^ref, :ready_output}, 2000

        # The cancelled URB is delivered with a non-:ok (reset) status.
        assert [{7, status, _payload}] = Nif.reap(h)
        assert status != :ok
      after
        Nif.release_interface(h, iface)
        Nif.close(h)
      end
    end

    @tag :usbfs
    test "close with a URB in flight tears down cleanly (deferred close)" do
      node = System.get_env("BODGE_USB_TEST_NODE") || flunk("set BODGE_USB_TEST_NODE")
      {:ok, dev} = Enumeration.read_descriptors(node)
      {iface, ep_in, _ep_out} = find_bulk_pair(dev) || flunk("no bulk pair")

      {:ok, h} = Nif.open(node, [:rdwr])
      :ok = Nif.claim_interface(h, iface)

      # A slow 1 MB URB is in flight when the handle is closed: close cancels
      # every kernel URB, refuses new work, and must never crash or leak.
      assert :ok = Nif.submit_bulk(h, 9, ep_in, 1_048_576)
      assert :ok = Nif.close(h)
      assert {:error, :ebadf} = Nif.submit_bulk(h, 10, ep_in, 64)
      assert [] = Nif.reap(h)
      assert {:error, :ebadf} = Nif.fileno(h)
    end
  end
end
