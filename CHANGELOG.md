# Changelog

## v0.1.0

Initial release. Native USB for Elixir on Linux over a usbfs-scoped syscall NIF.

- Device enumeration and defensive descriptor parsing (device/config/interface/
  endpoint/string) into structs; parsing is total (never raises).
- Control, bulk, and interrupt transfers through an async submit/select/reap
  engine (`CircuitsUsb.Transfer`), driven by `enif_select` so no scheduler is
  blocked; per-transfer timeouts and cancellation. Isochronous transfers with
  per-packet descriptors via the lower-level shim (`submit_iso`).
- Interface claim/release and kernel-driver detach/reattach.
- Endpoint-stall recovery (`clear_halt`), device reset, and typed handling of
  mid-transfer disconnect.
- Hotplug notifications over the kernel netlink uevent socket.
- Optional terminating zero-length packet (`zero_packet`) on OUT transfers.
