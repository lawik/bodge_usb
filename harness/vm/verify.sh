#!/usr/bin/env bash
# Runs IN the guest, as root. End-to-end library verification against real usbfs:
#   1. build + host-safe tests of the circuits_usb mix project (guest toolchain)
#   2. bring up a real usbfs node (dummy_hcd + g_zero)
#   3. run the :usbfs integration test (Shim.open -> read descriptor -> close)
#
# Uses the dev user's mise toolchain but runs as root so it can load modules and
# open the usbfs node. Builds guest-local (never in the 9p share) so host build
# products for a different kernel cannot contaminate it.
set -euo pipefail

SRC=/mnt/repo
DEV_HOME=/home/dev
MISE="$DEV_HOME/.local/bin/mise"
PROJ=/root/circuits_usb
HARNESS=/root/harness
ARTIFACTS=/mnt/repo/harness/artifacts  # written back to the host via the 9p share

run_mix() { HOME="$DEV_HOME" "$MISE" exec -- "$@"; }

# Unbind and remove every configfs gadget (leftovers would hold the UDC and
# block the gadgets this script sets up).
teardown_configfs_gadgets() {
  local g
  for g in /sys/kernel/config/usb_gadget/*/; do
    [ -e "$g/UDC" ] && echo "" > "$g/UDC" 2>/dev/null || true
    find "$g/configs" -maxdepth 2 -type l -delete 2>/dev/null || true
    rmdir "$g"/configs/*/strings/* "$g"/configs/* "$g"/functions/* "$g"/strings/* 2>/dev/null || true
    rmdir "$g" 2>/dev/null || true
  done
}

# Start from a known-clean UDC regardless of prior VM state.
preclean() {
  pkill -9 -f /dev/hidg0 2>/dev/null || true
  teardown_configfs_gadgets
  for m in raw_gadget g_zero usbtest usb_f_hid; do rmmod "$m" 2>/dev/null || true; done
  rmmod dummy_hcd 2>/dev/null || true
}

echo "== sync project + harness to guest-local =="
rm -rf "$PROJ" "$HARNESS"
mkdir -p "$PROJ"
for d in lib c_src test config; do [ -e "$SRC/$d" ] && cp -a "$SRC/$d" "$PROJ/"; done
for f in mix.exs mix.lock Makefile .formatter.exs; do [ -e "$SRC/$f" ] && cp -a "$SRC/$f" "$PROJ/"; done
cp -a "$SRC/harness" "$HARNESS"
make -C "$HARNESS" distclean >/dev/null 2>&1 || true

cd "$PROJ"
echo "== deps + compile =="
run_mix mix local.hex --force >/dev/null
run_mix mix local.rebar --force >/dev/null
run_mix mix deps.get
run_mix mix compile

echo "== host-safe shim tests (in guest) =="
run_mix mix test  # device-backed tags are excluded by default (test_helper.exs)

echo "== bring up a usbfs node (dummy_hcd + g_zero) =="
preclean
busnum="$("$HARNESS/scripts/load-dummy.sh")"
hidwriter=""
hidreader=""
cleanup() {
  [ -n "$hidwriter" ] && kill "$hidwriter" 2>/dev/null || true
  [ -n "$hidreader" ] && kill "$hidreader" 2>/dev/null || true
  pkill -f "raw_gadget/a3_device" 2>/dev/null || true
  # Unbind + remove any configfs gadget we stood up (HID etc.) so it releases the
  # UDC; otherwise rmmod dummy_hcd fails as busy and the next harness run on this
  # VM finds the UDC held ("couldn't find an available UDC or it's busy").
  teardown_configfs_gadgets
  rmmod g_zero 2>/dev/null || true
  rmmod raw_gadget 2>/dev/null || true
  rmmod dummy_hcd 2>/dev/null || true
}
trap cleanup EXIT
# pattern=1 makes the source/sink emit a mod-63 ramp instead of all zeros, so the
# bulk data-integrity assertions can actually catch corruption/offset bugs.
modprobe g_zero pattern=1

node=""
for _ in $(seq 1 50); do
  for v in /sys/bus/usb/devices/*/idVendor; do
    d="$(dirname "$v")"
    if [ "$(cat "$v" 2>/dev/null)" = "0525" ] && [ "$(cat "$d/idProduct" 2>/dev/null)" = "a4a0" ]; then
      node="/dev/bus/usb/$(printf '%03d' "$(cat "$d/busnum")")/$(printf '%03d' "$(cat "$d/devnum")")"
      break 2
    fi
  done
  sleep 0.1
done
[ -n "$node" ] || { echo "ERROR: no gadget-zero node appeared"; exit 1; }
echo "usbfs node: $node"

# Phase A -- driver detach/reattach needs a stock driver bound. udev
# auto-loads usbtest (its modalias matches gadget zero) and binds it; make sure.
command -v udevadm >/dev/null 2>&1 && udevadm settle 2>/dev/null || true
modprobe usbtest 2>/dev/null || true
for _ in $(seq 1 30); do
  ls /sys/bus/usb/drivers/usbtest/*:* >/dev/null 2>&1 && break
  sleep 0.1
done
echo "== :usbfs_driver tests (usbtest bound) =="
CIRCUITS_USB_TEST_NODE="$node" run_mix mix test --only usbfs_driver

# Phase B -- bulk/async tests need the interface free, so drop usbtest (whose
# claim on the interface would otherwise block our claim_interface with EBUSY).
modprobe -r usbtest 2>/dev/null || rmmod usbtest 2>/dev/null || true

echo "== :usbfs integration test =="
CIRCUITS_USB_TEST_NODE="$node" run_mix mix test --only usbfs

# Recovery tests that disrupt the gadget, run isolated and in order: reset
# re-enumerates g_zero (it stays up); disconnect then rmmods it. Both discover
# the gadget by VID/PID themselves, tolerant of the node changing after reset.
echo "== :usbfs_reset test =="
run_mix mix test --only usbfs_reset
echo "== :usbfs_disconnect test (removes g_zero) =="
run_mix mix test --only usbfs_disconnect

# Hotplug (B10): scripts g_zero connect/disconnect and observes the uevents.
# dummy_hcd is still loaded; the test loads/unloads g_zero itself.
echo "== :usbfs_hotplug test =="
run_mix mix test --only usbfs_hotplug

# A3-through-the-library (B3/B9): point Enumeration/Transfer at the *live*
# raw-gadget adversarial device and assert the library degrades to typed errors
# (not just synthetic-blob tests). One fault per sub-phase.
run_a3_phase() {
  local fault="$1" tag="$2"
  teardown_configfs_gadgets
  rmmod g_zero 2>/dev/null || true
  modprobe raw_gadget
  make -C "$HARNESS/raw_gadget" >/dev/null 2>&1
  RUN_SECONDS=90 FAULT="$fault" "$HARNESS/raw_gadget/a3_device" "$fault" >"$ARTIFACTS/a3-$fault.log" 2>&1 &
  local a3pid=$! node="" v d
  for _ in $(seq 1 60); do
    for v in /sys/bus/usb/devices/*/idVendor; do
      d="$(dirname "$v")"
      if [ "$(cat "$v" 2>/dev/null)" = "dead" ] && [ "$(cat "$d/idProduct" 2>/dev/null)" = "beef" ]; then
        node="/dev/bus/usb/$(printf '%03d' "$(cat "$d/busnum")")/$(printf '%03d' "$(cat "$d/devnum")")"
        break 2
      fi
    done
    sleep 0.1
  done
  if [ -n "$node" ]; then
    echo "a3 '$fault' node: $node"
    CIRCUITS_USB_TEST_NODE="$node" run_mix mix test --only "$tag"
  else
    echo "ERROR: a3 '$fault' device did not enumerate"; kill "$a3pid" 2>/dev/null || true; exit 1
  fi
  kill "$a3pid" 2>/dev/null || true
  rmmod raw_gadget 2>/dev/null || true
}

echo "== :usbfs_a3_stall (live raw-gadget stall-string) =="
run_a3_phase stall-string usbfs_a3_stall
echo "== :usbfs_a3_blength (live raw-gadget bad-device-blength) =="
run_a3_phase bad-device-blength usbfs_a3_blength
echo "== :usbfs_a3_slow (live raw-gadget slow) =="
run_a3_phase slow usbfs_a3_slow

# The library plays BOTH roles: CircuitsUsb.Gadget defines a HID
# gadget via configfs and binds it to dummy_udc.0, while the host tier of the
# same library enumerates it and exchanges interrupt reports with it.
echo "== :usbfs_gadget tests (library-defined configfs gadget) =="
teardown_configfs_gadgets
rmmod g_zero 2>/dev/null || true
modprobe libcomposite usb_f_hid
run_mix mix test --only usbfs_gadget
teardown_configfs_gadgets

# FunctionFS: the library serves a *custom* function from userspace
# (toy vendor protocol over ep0 + bulk echo over epN) and drives it with its
# own host tier.
echo "== :usbfs_ffs tests (FunctionFS custom function) =="
teardown_configfs_gadgets
modprobe libcomposite usb_f_fs
run_mix mix test --only usbfs_ffs
umount /dev/ffs-circuits 2>/dev/null || true
teardown_configfs_gadgets

# Phase C -- interrupt transfers need an interrupt endpoint; g_zero has
# none, so switch to a configfs HID gadget (interrupt IN + OUT). The gadget
# streams a known 8-byte report which the host reads over the interrupt IN ep.
setup_hid_gadget() {
  local g="$1"
  mkdir -p "$g"
  echo 0x1d6b > "$g/idVendor"; echo 0x0104 > "$g/idProduct"; echo 0x0200 > "$g/bcdUSB"
  mkdir -p "$g/strings/0x409"
  echo "circuits-hid" > "$g/strings/0x409/serialnumber"
  echo "circuits" > "$g/strings/0x409/manufacturer"
  echo "HID interrupt test" > "$g/strings/0x409/product"
  mkdir -p "$g/configs/c.1/strings/0x409"
  echo "hid" > "$g/configs/c.1/strings/0x409/configuration"
  mkdir -p "$g/functions/hid.usb0"
  echo 0 > "$g/functions/hid.usb0/protocol"
  echo 0 > "$g/functions/hid.usb0/subclass"
  echo 8 > "$g/functions/hid.usb0/report_length"
  printf '\x06\x00\xff\x09\x01\xa1\x01\x15\x00\x26\xff\x00\x75\x08\x95\x08\x09\x01\x81\x02\xc0' \
    > "$g/functions/hid.usb0/report_desc"
  ln -s "$g/functions/hid.usb0" "$g/configs/c.1/"
  echo dummy_udc.0 > "$g/UDC"
}

echo "== :usbfs_int tests (HID gadget, interrupt endpoint) =="
rmmod g_zero 2>/dev/null || true
teardown_configfs_gadgets
modprobe libcomposite usb_f_hid
setup_hid_gadget /sys/kernel/config/usb_gadget/circuits_hid
sleep 0.5
command -v udevadm >/dev/null 2>&1 && udevadm settle 2>/dev/null || true

hidnode=""
for _ in $(seq 1 50); do
  for v in /sys/bus/usb/devices/*/idProduct; do
    d="$(dirname "$v")"
    if [ "$(cat "$d/idVendor" 2>/dev/null)" = "1d6b" ] && [ "$(cat "$v" 2>/dev/null)" = "0104" ]; then
      hidnode="/dev/bus/usb/$(printf '%03d' "$(cat "$d/busnum")")/$(printf '%03d' "$(cat "$d/devnum")")"
      break 2
    fi
  done
  sleep 0.1
done
[ -n "$hidnode" ] || { echo "ERROR: no HID node appeared"; exit 1; }
echo "HID node: $hidnode"

# Gadget side: stream the known input report so a host interrupt IN lands on one.
# Writes block on the f_hid FIFO until the host reads, so a report is always
# pending. Killed after the test (also via the EXIT trap).
( while true; do
    printf '\x01\x02\x03\x04\x05\x06\x07\x08' > /dev/hidg0 2>/dev/null || break
  done ) &
hidwriter=$!

# Gadget side, OUT direction: capture the one 8-byte OUT report the
# :usbfs_int interrupt-OUT test sends, to verify content end to end.
out_report="$ARTIFACTS/b7-out-report.bin"
rm -f "$out_report"
( timeout 120 dd if=/dev/hidg0 of="$out_report" bs=8 count=1 2>/dev/null ) &
hidreader=$!

# Capture the wire; interrupt transfers show as 'Ii'/'Io' tokens in usbmon.
mkdir -p "$ARTIFACTS"
trace="$ARTIFACTS/b7-interrupt.usbmon"
"$HARNESS/scripts/a4-usbmon.sh" start "$busnum" "$trace" 2>/dev/null || true

CIRCUITS_USB_TEST_NODE="$hidnode" run_mix mix test --only usbfs_int

"$HARNESS/scripts/a4-usbmon.sh" stop "$trace" 2>/dev/null || true
kill "$hidwriter" 2>/dev/null || true

# The usbmon trace and the gadget-side OUT report are acceptance evidence, not
# hints: their absence means the transfers did not hit the wire -- fail loudly.
grep -aq ' Ii:' "$trace" \
  || { echo "ERROR: no interrupt-IN token in $trace"; exit 1; }
grep -aq ' Io:' "$trace" \
  || { echo "ERROR: no interrupt-OUT token in $trace"; exit 1; }
echo "usbmon: interrupt IN + OUT tokens observed on the wire"

wait "$hidreader" 2>/dev/null || true
expected="$(printf '\x08\x07\x06\x05\x04\x03\x02\x01')"
if [ "$(cat "$out_report" 2>/dev/null)" = "$expected" ]; then
  echo "gadget side: interrupt-OUT report content verified"
else
  echo "ERROR: interrupt-OUT report missing or wrong: $(od -An -tx1 "$out_report" 2>/dev/null)"
  exit 1
fi

# Phase D -- isochronous transfers. dummy_hcd cannot emulate isoc, so this
# targets the QEMU usb-audio device on the emulated xHCI. It is always present
# (VM-level), so the test discovers it itself -- no gadget setup needed.
echo "== :usbfs_iso tests (QEMU usb-audio, isochronous) =="
iso_trace="$ARTIFACTS/b8-iso.usbmon"
"$HARNESS/scripts/a4-usbmon.sh" start 0 "$iso_trace" 2>/dev/null || true  # bus 0 = all
run_mix mix test --only usbfs_iso
"$HARNESS/scripts/a4-usbmon.sh" stop "$iso_trace" 2>/dev/null || true
# Acceptance evidence, not a hint (and -a: usbmon data can trip grep's binary
# detection): no isoc token on the wire means the phase did not do its job.
grep -aqE ' Zo:| Zi:' "$iso_trace" \
  || { echo "ERROR: no isochronous token in $iso_trace"; exit 1; }
echo "usbmon: isochronous tokens observed on the wire"

echo "VERIFY_DONE"
