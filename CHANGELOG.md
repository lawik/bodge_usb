# Changelog

## v0.1.0

Initial release. Native USB for Elixir on Linux over a usbfs-scoped syscall NIF.

- Device enumeration and defensive descriptor parsing (device/config/interface/
  endpoint/string) into structs; parsing is total (never raises).
- Control, bulk, interrupt, and isochronous transfers through an async
  submit/select/reap engine (`CircuitsUsb.Transfer`), driven by `enif_select`
  so no scheduler is blocked; per-transfer timeouts and cancellation.
- An asynchronous primitive API: `submit/3` returns a ref and the completion
  arrives as `{:circuits_usb, ref, result}`; `cancel/2` discards in flight;
  the blocking calls (`bulk_in/4`, ...) are submit + await. The raw
  `CircuitsUsb.Shim` tier (handle + select/reap, no processes) is also a
  supported API.
- Interface claim/release and kernel-driver detach/reattach.
- Endpoint-stall recovery (`clear_halt`), device reset, and typed handling of
  mid-transfer disconnect.
- Hotplug notifications over the kernel netlink uevent socket.
- Optional terminating zero-length packet (`zero_packet`) on OUT transfers.
- Device-side gadgets over configfs (`CircuitsUsb.Gadget`): declarative
  define/bind/unbind/remove, device-node and network-interface resolution
  for kernel function drivers (HID, ACM, ECM, ...).
