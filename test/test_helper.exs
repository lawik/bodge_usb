# Device-backed tests are tagged and excluded by default so `mix test` runs the
# host-safe suite anywhere. The harness (harness/vm/verify.sh) re-includes each
# phase with `--only <tag>` against the appropriate gadget:
#   :usbfs        - gadget zero (descriptors, control, bulk, async engine)
#   :usbfs_driver - gadget zero with usbtest bound (kernel-driver detach)
#   :usbfs_int    - HID gadget (interrupt transfers)
#   :usbfs_iso    - QEMU usb-audio device (isochronous transfers)
ExUnit.start(exclude: [:usbfs, :usbfs_driver, :usbfs_int, :usbfs_iso])
