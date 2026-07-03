defmodule CircuitsUsb.Enumeration do
  @moduledoc """
  Device enumeration.

  Walks `/dev/bus/usb`, reads each node's descriptor blob through the shim, and
  parses it. A single malformed device never breaks enumeration of the others:
  each device carries either `{:ok, %Device{}}` or `{:error, reason}`.
  """

  alias CircuitsUsb.{Descriptor, Shim}

  @usbfs_root "/dev/bus/usb"
  # Descriptor blobs are small; this bound is generous.
  @max_descriptor_bytes 65_536

  defmodule DeviceRef do
    @moduledoc "A discovered usbfs device node and its parsed descriptors."
    defstruct [:bus, :address, :path, :descriptor]

    @type t :: %__MODULE__{
            bus: pos_integer() | nil,
            address: pos_integer() | nil,
            path: String.t(),
            descriptor: {:ok, CircuitsUsb.Descriptor.Device.t()} | {:error, term()}
          }
  end

  @doc """
  List all devices under `/dev/bus/usb`, each with parsed descriptors. Returns
  `[]` if usbfs is not present. Devices that cannot be opened/read carry the
  error in their `:descriptor` field rather than aborting the scan.
  """
  @spec list_devices(Path.t()) :: [DeviceRef.t()]
  def list_devices(root \\ @usbfs_root) do
    root
    |> node_paths()
    |> Enum.map(&describe_node/1)
  end

  @doc """
  Open `path`, read and parse its descriptors, and close it. Returns
  `{:ok, %Device{}}` or `{:error, reason}`.
  """
  @spec read_descriptors(Path.t()) :: {:ok, Descriptor.Device.t()} | {:error, term()}
  def read_descriptors(path) do
    case Shim.open(path, [:rdonly]) do
      {:ok, handle} ->
        try do
          with {:ok, blob} <- Shim.read(handle, @max_descriptor_bytes) do
            Descriptor.parse(blob)
          end
        after
          Shim.close(handle)
        end

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Read and decode a string descriptor by index from an open handle. Index 0 is
  reserved (LANGID list); returns `{:error, :no_string}` for index 0 or a device
  with no such string.
  """
  @spec string(Shim.handle(), 0..255, 0..0xFFFF) :: {:ok, String.t()} | {:error, term()}
  def string(handle, index, langid \\ 0x0409)
  def string(_handle, 0, _langid), do: {:error, :no_string}

  def string(handle, index, langid) when index in 1..255 do
    # GET_DESCRIPTOR(String, index): wValue = STRING type (0x03) in the high byte,
    # index in the low byte; wIndex = langid.
    <<wvalue::16>> = <<0x03, index>>

    case Shim.control_in(handle, 0x06, wvalue, langid, 255, 1000) do
      {:ok, <<_len, 0x03, _::binary>> = bytes} -> Descriptor.decode_string(bytes)
      {:ok, _} -> {:error, :not_a_string_descriptor}
      {:error, _} = err -> err
    end
  end

  # ---- internal ----------------------------------------------------------

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
