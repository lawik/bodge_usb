# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0

defmodule BodgeUSB.Enumeration do
  @moduledoc false

  # Device enumeration: walks /dev/bus/usb, reads each node's descriptor blob
  # through the NIF, and parses it. A single malformed device never breaks
  # enumeration of the others: each DeviceRef carries either
  # {:ok, %Device{}} or {:error, reason}.

  alias BodgeUSB.Descriptor
  alias BodgeUSB.DeviceRef
  alias BodgeUSB.Nif

  @usbfs_root "/dev/bus/usb"
  # Descriptor blobs are small; this bound is generous.
  @max_descriptor_bytes 65_536

  @spec list_devices(Path.t()) :: [DeviceRef.t()]
  def list_devices(root \\ @usbfs_root) do
    root
    |> node_paths()
    |> Enum.map(&describe_node/1)
  end

  # Open path, read and parse its descriptors, close it.
  @spec read_descriptors(Path.t()) :: {:ok, Descriptor.Device.t()} | {:error, term()}
  def read_descriptors(path) do
    case Nif.open(path, [:rdonly]) do
      {:ok, handle} ->
        try do
          with {:ok, blob} <- Nif.read(handle, @max_descriptor_bytes) do
            Descriptor.parse(blob)
          end
        after
          Nif.close(handle)
        end

      {:error, _} = err ->
        err
    end
  end

  defp node_paths(root) do
    case File.ls(root) do
      {:ok, buses} ->
        for bus <- Enum.sort(buses),
            dev <- ls_sorted(Path.join(root, bus)),
            do: Path.join([root, bus, dev])

      {:error, _} ->
        []
    end
  end

  defp ls_sorted(dir) do
    case File.ls(dir) do
      {:ok, entries} -> Enum.sort(entries)
      {:error, _} -> []
    end
  end

  defp describe_node(path) do
    [bus, address] =
      path |> Path.split() |> Enum.take(-2) |> Enum.map(&safe_int/1)

    %DeviceRef{
      bus: bus,
      address: address,
      path: path,
      descriptor: read_descriptors(path)
    }
  end

  defp safe_int(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> nil
    end
  end
end
