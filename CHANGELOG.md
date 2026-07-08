# Changelog

## v0.1.1

- Scope `nstandard` to the `:dev` and `:test` environments so it is not
  pulled in as a dependency of the released package.

## v0.1.0

Initial release. Host-side USB for Elixir on Linux over a usbfs-scoped
syscall NIF. (Started life as `circuits_usb`; renamed to `bodge_usb` and
split before release: device-side gadget/FunctionFS support lives in the
companion `bodge_usb_gadget` library.)

- One public module: `BodgeUSB`, a per-device engine process. Device
  discovery with parsed descriptors (`list_devices/0`, `find_device/2`),
  open/close, interface claim/release, kernel-driver detach/reattach,
  stall recovery (`clear_halt/2`), reset, and string-descriptor reads.
- Control, bulk, interrupt, and isochronous transfers through an async
  submit/select/reap URB engine driven by `enif_select`: no scheduler is
  ever blocked on a transfer, and per-transfer timeouts and cancellation
  are engine-enforced.
- The async primitive: `submit/3` returns a ref and the completion arrives
  as `{:bodge_usb, ref, result}`; the blocking calls (`bulk_in/4`, ...) are
  submit + await. Isochronous IN results are compacted (received bytes
  concatenated, split by the per-packet actual lengths).
- Defensive descriptor parsing (device/config/interface/endpoint/string)
  into structs; parsing is total (never raises) and fuzz-tested.
- Optional terminating zero-length packet (`zero_packet`) on OUT transfers.
- Hotplug notifications over the kernel netlink uevent socket, with
  kernel-origin verification of every datagram.
