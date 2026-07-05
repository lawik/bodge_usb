# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0

defmodule BodgeUSB.TestHelpers do
  @moduledoc false

  # First interface exposing both a bulk IN and a bulk OUT endpoint, as
  # `{interface_number, in_address, out_address}`, or nil.
  @spec find_bulk_pair(BodgeUSB.Descriptor.Device.t()) ::
          {non_neg_integer(), 0..255, 0..255} | nil
  def find_bulk_pair(dev) do
    Enum.find_value(dev.configurations, fn c ->
      Enum.find_value(c.interfaces, fn i ->
        ep_in = Enum.find(i.endpoints, &(&1.transfer_type == :bulk and &1.direction == :in))
        ep_out = Enum.find(i.endpoints, &(&1.transfer_type == :bulk and &1.direction == :out))
        if ep_in && ep_out, do: {i.number, ep_in.address, ep_out.address}
      end)
    end)
  end
end
