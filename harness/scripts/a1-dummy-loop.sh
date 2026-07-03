#!/usr/bin/env bash
# A1 -- Virtual USB loop (dummy_hcd).
#
# Load dummy_hcd, bring up a stock CDC-ACM gadget via configfs/libcomposite
# bound to the software UDC, and confirm it enumerates on the host stack under
# /dev/bus/usb. Then tear everything down and confirm nothing is left dangling.
#
# Acceptance: a stock gadget enumerates and is visible under
# /dev/bus/usb; setup and teardown leave no dangling modules or nodes.
set -euo pipefail
. "$(dirname "$0")/../lib/common.sh"

require_root

GADGET_NAME="${GADGET_NAME:-circuits_a1}"
GADGET_DIR="/sys/kernel/config/usb_gadget/$GADGET_NAME"
UDC_NAME="dummy_udc.0"
SERIAL="circuits-usb-a1-$$"       # unique so we can find exactly our device
VID="0x1d6b"                      # Linux Foundation
PID="0x0104"                      # Multifunction Composite Gadget

teardown_gadget() {
  [ -d "$GADGET_DIR" ] || return 0
  log "tearing down gadget $GADGET_NAME"
  # Unbind from UDC first.
  echo "" > "$GADGET_DIR/UDC" 2>/dev/null || true
  # Remove function links from configs.
  find "$GADGET_DIR/configs" -maxdepth 2 -type l -exec rm -f {} + 2>/dev/null || true
  # rmdir the config string dirs, configs, function dirs, gadget strings, gadget.
  rmdir "$GADGET_DIR"/configs/*/strings/* 2>/dev/null || true
  rmdir "$GADGET_DIR"/configs/* 2>/dev/null || true
  rmdir "$GADGET_DIR"/functions/* 2>/dev/null || true
  rmdir "$GADGET_DIR"/strings/* 2>/dev/null || true
  rmdir "$GADGET_DIR" 2>/dev/null || true
}

setup_gadget() {
  ensure_configfs
  modprobe_checked libcomposite || die "libcomposite not available"
  [ -d "$GADGET_DIR" ] && teardown_gadget

  log "creating configfs gadget $GADGET_NAME (serial $SERIAL)"
  mkdir -p "$GADGET_DIR"
  echo "$VID" > "$GADGET_DIR/idVendor"
  echo "$PID" > "$GADGET_DIR/idProduct"
  echo 0x0200 > "$GADGET_DIR/bcdUSB"        # USB 2.0

  mkdir -p "$GADGET_DIR/strings/0x409"
  echo "$SERIAL"        > "$GADGET_DIR/strings/0x409/serialnumber"
  echo "circuits_usb"   > "$GADGET_DIR/strings/0x409/manufacturer"
  echo "A1 loopback ACM" > "$GADGET_DIR/strings/0x409/product"

  mkdir -p "$GADGET_DIR/configs/c.1/strings/0x409"
  echo "cdc" > "$GADGET_DIR/configs/c.1/strings/0x409/configuration"
  echo 120   > "$GADGET_DIR/configs/c.1/MaxPower"

  # CDC-ACM function needs usb_f_acm (pulled by libcomposite on demand).
  mkdir -p "$GADGET_DIR/functions/acm.gs0"
  ln -s "$GADGET_DIR/functions/acm.gs0" "$GADGET_DIR/configs/c.1/"
}

# Find the /dev/bus/usb node for the device carrying our serial. Prints
# "BUS DEV DEVPATH NODE" or returns non-zero.
find_our_node() {
  local sfile dev busnum devnum
  for sfile in /sys/bus/usb/devices/*/serial; do
    [ -r "$sfile" ] || continue
    if [ "$(cat "$sfile" 2>/dev/null)" = "$SERIAL" ]; then
      dev="$(dirname "$sfile")"
      busnum="$(cat "$dev/busnum")"
      devnum="$(cat "$dev/devnum")"
      printf '%s %s %s /dev/bus/usb/%03d/%03d\n' \
        "$busnum" "$devnum" "$dev" "$busnum" "$devnum"
      return 0
    fi
  done
  return 1
}

main() {
  local log_file="$ARTIFACTS_DIR/a1.log"
  : > "$log_file"

  # 1. Bring up the software controller/UDC pair.
  local busnum
  busnum="$("$HARNESS_ROOT/scripts/load-dummy.sh")"
  defer "rmmod_quiet dummy_hcd"
  log "dummy_hcd up on host bus $busnum"

  # 2. Build + bind the gadget.
  setup_gadget
  defer "teardown_gadget"
  log "binding gadget to $UDC_NAME"
  echo "$UDC_NAME" > "$GADGET_DIR/UDC"

  # 3. Verify enumeration on the host side.
  if ! wait_for 5 "gadget to enumerate under /dev/bus/usb" -- find_our_node; then
    dmesg | tail -20 | tee -a "$log_file" >&2
    case_fail "A1 enumeration"
    return 1
  fi

  local info node
  info="$(find_our_node)"
  node="$(printf '%s' "$info" | awk '{print $4}')"
  log "enumerated: $info"
  { echo "device info: $info"; } >> "$log_file"

  # 4. Read the device descriptor back through usbfs (ground truth for B1).
  #    usbfs returns cached descriptors on read(); first 18 bytes = device desc.
  if head -c 18 "$node" 2>/dev/null | od -An -tx1 >> "$log_file"; then
    local bLength bDescType
    bLength=$(head -c 1 "$node" | od -An -tu1 | tr -d ' ')
    bDescType=$(head -c 2 "$node" | tail -c 1 | od -An -tu1 | tr -d ' ')
    if [ "$bLength" = "18" ] && [ "$bDescType" = "1" ]; then
      case_pass "A1 read device descriptor via usbfs ($node)"
    else
      case_fail "A1 device descriptor sanity (bLength=$bLength type=$bDescType)"
    fi
  else
    warn "could not read $node (permissions?), relying on sysfs enumeration"
  fi

  case_pass "A1 gadget enumerated on host bus $busnum ($node)"

  # 5. Explicit teardown now (defers also cover the failure path), then verify.
  teardown_gadget
  rmmod_quiet dummy_hcd
  # Drop the defers we just ran so EXIT does not repeat them.
  _defer_stack=()

  if [ -d "$GADGET_DIR" ]; then
    case_fail "A1 teardown left gadget dir behind"
  elif module_loaded dummy_hcd; then
    case_fail "A1 teardown left dummy_hcd loaded"
  else
    case_pass "A1 clean teardown (no dangling module or configfs node)"
  fi

  case_summary
}

main "$@"
