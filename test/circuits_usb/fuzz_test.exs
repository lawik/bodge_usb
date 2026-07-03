defmodule CircuitsUsb.FuzzTest do
  use ExUnit.Case, async: true

  alias CircuitsUsb.Descriptor
  alias CircuitsUsb.Hotplug

  @moduledoc """
  Seeded, deterministic fuzz of the parsing surfaces (host-safe, no device).

  These parsers are the part of the library that consumes bytes a hostile
  device controls, so "total, never raises" is a hard contract (PROJECT.md B3).
  descriptor_test.exs covers the curated malformation catalog; this module adds
  volume: random bytes, plus structured mutations of a valid blob (bit flips,
  truncations, length-field tampering, splices), which find edge cases curation
  misses. The seed is fixed so failures reproduce.
  """

  # Same well-formed blob as descriptor_test.exs.
  @device <<18, 1, 0x00, 0x02, 0, 0, 0, 64, 0x25, 0x05, 0xA0, 0xA4, 0x01, 0x00, 1, 2, 3, 1>>
  @config <<9, 2, 32::little-16, 1, 1, 0, 0x80, 60>>
  @interface <<9, 4, 0, 0, 2, 0xFF, 0, 0, 0>>
  @ep_in <<7, 5, 0x81, 0x02, 512::little-16, 0>>
  @ep_out <<7, 5, 0x01, 0x02, 512::little-16, 0>>
  @full @device <> @config <> @interface <> @ep_in <> @ep_out

  defp assert_total(fun, input) do
    result = fun.(input)

    assert match?({:ok, _}, result) or match?({:error, _}, result),
           "parser returned #{inspect(result)} for #{inspect(input, limit: 24)}"
  rescue
    e in ExUnit.AssertionError ->
      reraise e, __STACKTRACE__

    e ->
      flunk("parser raised #{inspect(e)} for #{inspect(input, limit: 24)}")
  end

  defp random_binary do
    case :rand.uniform(513) - 1 do
      0 -> <<>>
      size -> :rand.bytes(size)
    end
  end

  # One random structured mutation of the valid blob. Chained mutations can
  # shrink the input, so every arm must tolerate any current size.
  defp mutate(blob) when byte_size(blob) == 0, do: random_binary()

  defp mutate(blob) do
    size = byte_size(blob)

    case :rand.uniform(5) do
      # overwrite one random byte with a random value
      1 ->
        pos = :rand.uniform(size) - 1
        <<pre::binary-size(^pos), _b, post::binary>> = blob
        <<pre::binary, :rand.uniform(256) - 1, post::binary>>

      # truncate at a random point
      2 ->
        keep = :rand.uniform(size) - 1
        binary_part(blob, 0, keep)

      # tamper a plausible length byte (start of a descriptor) to 0/1/255/random
      3 ->
        pos =
          [0, 18, 27, 36, 43]
          |> Enum.filter(&(&1 < size))
          |> Enum.random()

        val = Enum.random([0, 1, 2, 255, :rand.uniform(256) - 1])
        <<pre::binary-size(^pos), _b, post::binary>> = blob
        <<pre::binary, val, post::binary>>

      # splice random garbage into the middle
      4 ->
        pos = :rand.uniform(size) - 1
        <<pre::binary-size(^pos), post::binary>> = blob
        pre <> random_binary() <> post

      # duplicate a random slice (repeated/nested descriptors)
      5 ->
        start = :rand.uniform(size) - 1
        len = min(size - start, :rand.uniform(32))
        blob <> binary_part(blob, start, len)
    end
  end

  test "Descriptor.parse/1 and friends are total under seeded fuzz" do
    :rand.seed(:exsss, {20_260_703, 42, 7})

    for _ <- 1..1500 do
      assert_total(&Descriptor.parse/1, random_binary())
    end

    for _ <- 1..1500 do
      input = Enum.reduce(1..:rand.uniform(3), @full, fn _, acc -> mutate(acc) end)
      assert_total(&Descriptor.parse/1, input)
      assert_total(&Descriptor.parse_device/1, input)
      assert_total(&Descriptor.parse_configuration/1, input)
    end
  end

  test "string-descriptor decoding is total under seeded fuzz" do
    :rand.seed(:exsss, {20_260_703, 43, 7})

    for _ <- 1..1500 do
      input = random_binary()
      assert_total(&Descriptor.decode_string/1, input)
      assert_total(&Descriptor.language_ids/1, input)

      # Descriptor-framed variant: a lying bLength over random UTF-16ish bytes.
      framed = <<:rand.uniform(256) - 1, 3>> <> input
      assert_total(&Descriptor.decode_string/1, framed)
      assert_total(&Descriptor.language_ids/1, framed)
    end
  end

  test "Hotplug.parse_uevent/1 is total under seeded fuzz" do
    :rand.seed(:exsss, {20_260_703, 44, 7})

    valid =
      "add@/devices/x\0ACTION=add\0DEVPATH=/devices/x\0SUBSYSTEM=usb\0" <>
        "DEVTYPE=usb_device\0BUSNUM=003\0DEVNUM=002\0DEVNAME=bus/usb/003/002\0"

    total = fn input ->
      result = Hotplug.parse_uevent(input)

      assert match?({:ok, _}, result) or result == :skip,
             "parse_uevent returned #{inspect(result)}"
    end

    for _ <- 1..1000 do
      total.(random_binary())

      # Mutate the valid datagram: drop/garble fields, inject NULs and equals.
      mutated =
        valid
        |> String.split(<<0>>)
        |> Enum.reject(fn _ -> :rand.uniform(4) == 1 end)
        |> Enum.map(fn field ->
          if :rand.uniform(5) == 1, do: random_binary(), else: field
        end)
        |> Enum.join(<<0>>)

      total.(mutated)
    end
  end
end
