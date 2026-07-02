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

run_mix() { HOME="$DEV_HOME" "$MISE" exec -- "$@"; }

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
run_mix mix test --exclude usbfs --exclude usbfs_driver

echo "== bring up a usbfs node (dummy_hcd + g_zero) =="
busnum="$("$HARNESS/scripts/load-dummy.sh")"
cleanup() { rmmod g_zero 2>/dev/null || true; rmmod dummy_hcd 2>/dev/null || true; }
trap cleanup EXIT
modprobe g_zero

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

# Phase A -- driver detach/reattach (B6) needs a stock driver bound. udev
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

echo "VERIFY_DONE"
