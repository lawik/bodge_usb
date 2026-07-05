# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0

defmodule BodgeUSB.DeviceRef do
  @moduledoc """
  A discovered usbfs device node and its parsed descriptors, as returned by
  `BodgeUSB.list_devices/0`. Pass it to `BodgeUSB.open/1`.

  Devices that could not be opened or parsed carry the error in `:descriptor`
  rather than breaking enumeration.
  """

  defstruct [:bus, :address, :path, :descriptor]

  @type t :: %__MODULE__{
          bus: pos_integer() | nil,
          address: pos_integer() | nil,
          path: String.t(),
          descriptor: {:ok, BodgeUSB.Descriptor.Device.t()} | {:error, term()}
        }
end
