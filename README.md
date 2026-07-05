# BodgeUSB

Talk to USB devices from Elixir on Linux, built on a USB-scoped syscall NIF
over usbfs. It drives arbitrary USB devices from the BEAM without shelling out
to libusb and without a generic "call any ioctl" gateway: the NIF exposes only
a small, fixed, size-validated set of usbfs ioctls whose struct layouts it
owns.

Each open device is one `BodgeUSB` process running an asynchronous URB engine
(`enif_select`-driven, no blocked schedulers). The blocking calls (`bulk_in/4`
and friends) are submit + await over that engine, so one process can also
pipeline many transfers and receive completions as messages.

Device-side USB (being a gadget, configfs/FunctionFS) lives in the companion
library [`bodge_usb_gadget`](https://github.com/lawik/bodge_usb_gadget).

Linux only. See `harness/` for the fully virtual test rig (dummy_hcd,
g_zero/usbtest, raw-gadget fault injection, usbmon).

## Features

- Enumeration and defensive descriptor parsing (device/config/interface/
  endpoint/string) into structs; parsing is total (never raises).
- Control, bulk, interrupt, and isochronous transfers, with per-transfer
  timeouts and cancellation.
- The async primitive under the blocking calls: `submit/3` returns a ref, the
  completion arrives as a `{:bodge_usb, ref, result}` message.
- Interface claim/release and kernel-driver detach/reattach.
- Endpoint-stall recovery (`clear_halt`), device reset, and typed handling of
  mid-transfer disconnect.
- Hotplug notifications over the kernel netlink uevent socket.

## Example

```elixir
{:ok, dev} = BodgeUSB.open(0x0525, 0xA4A0)
BodgeUSB.detach_driver(dev, 0)
:ok = BodgeUSB.claim_interface(dev, 0)
{:ok, data} = BodgeUSB.bulk_in(dev, 0x81, 512)
{:ok, _n} = BodgeUSB.bulk_out(dev, 0x02, data)

# Async: pipeline transfers from one process, completions as messages.
{:ok, ref} = BodgeUSB.submit(dev, {:bulk_in, 0x81, 4096}, timeout: 1000)
receive do
  {:bodge_usb, ^ref, {:ok, bytes}} -> byte_size(bytes)
end

BodgeUSB.close(dev)

{:ok, _hp} = BodgeUSB.watch_hotplug()
receive do
  {:usb_hotplug, %{action: :add, busnum: b, devnum: d}} -> IO.inspect({b, d})
end
```

## Permissions

Accessing `/dev/bus/usb` and the netlink uevent socket needs root or
appropriate udev rules / capabilities.

## Installation

```elixir
def deps do
  [
    {:bodge_usb, "~> 0.1.0"}
  ]
end
```
