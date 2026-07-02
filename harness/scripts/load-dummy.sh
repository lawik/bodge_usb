#!/usr/bin/env bash
# Build (if needed) and load dummy_hcd, then print the host-side bus number
# of the emulated controller on stdout. Idempotent: a no-op if already loaded.
#
# Usage:  busnum=$(scripts/load-dummy.sh)
#
# dummy_hcd registers a gadget-side UDC "dummy_udc.0" and a host-side HCD
# "dummy_hcd.0" whose root hub shows up as a fresh /sys/bus/usb/devices/usbN.
set -euo pipefail
. "$(dirname "$0")/../lib/common.sh"

require_root

MODDIR="$HARNESS_ROOT/modules/dummy_hcd"

build_and_load() {
  if module_loaded dummy_hcd; then
    log "dummy_hcd already loaded"
    return 0
  fi
  # Prefer an in-tree module if this kernel actually ships one.
  if modinfo dummy_hcd >/dev/null 2>&1; then
    log "loading in-tree dummy_hcd"
    modprobe dummy_hcd && return 0
  fi
  # Otherwise build it out-of-tree against the running kernel's headers.
  # udc-core is a dependency; pull it in first (usually auto-loaded).
  modprobe_checked udc_core || modprobe_checked libcomposite || true

  if [ ! -f "$MODDIR/dummy_hcd.ko" ]; then
    log "building dummy_hcd.ko out-of-tree"
    make -C "$MODDIR" >&2
  fi
  log "inserting dummy_hcd.ko"
  insmod "$MODDIR/dummy_hcd.ko" 2>/dev/null || die "failed to load dummy_hcd"
}

# The dummy_hcd root hub shows up as /sys/bus/usb/devices/usbN whose resolved
# device path runs through the dummy_hcd platform device. Match on that so we
# do not depend on the exact platform-device name.
find_bus() {
  local rh
  for rh in /sys/bus/usb/devices/usb*; do
    [ -e "$rh/busnum" ] || continue
    if readlink -f "$rh" | grep -q dummy_hcd; then
      cat "$rh/busnum"
      return 0
    fi
  done
  return 1
}

build_and_load
wait_for 5 "dummy_hcd root hub to appear" -- find_bus

busnum="$(find_bus)" || die "could not locate dummy_hcd host bus"
log "dummy_hcd host bus = $busnum, gadget UDC = dummy_udc.0"
printf '%s\n' "$busnum"
