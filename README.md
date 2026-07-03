# CircuitsUsb

Native USB for Erlang/Elixir on Linux, built on a USB-scoped syscall NIF over
usbfs. It drives arbitrary USB devices from the BEAM without shelling out to
libusb and without a generic "call any ioctl" gateway: the NIF exposes only a
small, fixed, size-validated set of usbfs ioctls whose struct layouts it owns.

Linux only. See `PROJECT.md` for the design and `harness/` for the fully virtual
test rig (dummy_hcd, g_zero/usbtest, raw-gadget fault injection, usbmon).

## Features

- Enumeration and defensive descriptor parsing (device/config/interface/
  endpoint/string) into structs.
- Control, bulk, interrupt, and isochronous transfers through an async
  submit/select/reap engine (`enif_select`-driven, no blocked schedulers),
  with per-transfer timeouts and cancellation.
- An asynchronous primitive under the blocking calls: `submit/3` returns a
  ref, the completion arrives as a `{:circuits_usb, ref, result}` message;
  `bulk_in/4` and friends are just submit + await.
- Interface claim/release and kernel-driver detach/reattach.
- Endpoint-stall recovery (`clear_halt`), device reset, and typed handling of
  mid-transfer disconnect.
- Hotplug notifications over the kernel netlink uevent socket.
- Device-side (gadget) definition over configfs (`CircuitsUsb.Gadget`): act
  as a HID/serial/ethernet/mass-storage/... device on UDC-capable hardware,
  with chardev functions driven through the same shim tier.
- Custom device functions over FunctionFS (`CircuitsUsb.FunctionFs`): serve
  your own protocol from Elixir (vendor control requests as handler
  callbacks, endpoint files driven via the shim's blocking I/O).

Three supported tiers: `CircuitsUsb.Shim` (raw handle + submit/select/reap,
no processes), `CircuitsUsb.Transfer` (one engine process per device), and
the `CircuitsUsb` facade below.

## Example

```elixir
{:ok, dev} = CircuitsUsb.open(0x0525, 0xA4A0)
CircuitsUsb.detach_driver(dev, 0)
:ok = CircuitsUsb.claim_interface(dev, 0)
{:ok, data} = CircuitsUsb.bulk_in(dev, 0x81, 512)
{:ok, _n} = CircuitsUsb.bulk_out(dev, 0x02, data)

# Async: pipeline transfers from one process, completions as messages.
{:ok, ref} = CircuitsUsb.submit(dev, {:bulk_in, 0x81, 4096}, timeout: 1000)
receive do
  {:circuits_usb, ^ref, {:ok, bytes}} -> byte_size(bytes)
end

CircuitsUsb.close(dev)

{:ok, _hp} = CircuitsUsb.watch_hotplug()
receive do
  {:usb_hotplug, %{action: :add, busnum: b, devnum: d}} -> IO.inspect({b, d})
end
```

## Permissions

Accessing `/dev/bus/usb` and the netlink uevent socket needs root or appropriate
udev rules / capabilities.

## Installation

```elixir
def deps do
  [
    {:circuits_usb, "~> 0.1.0"}
  ]
end
```
