#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0

# A3 -- Adversarial device (raw-gadget).
#
# Run the raw-gadget adversarial device (harness/raw_gadget/a3_device) through
# its fault catalog. For each fault we bring the device up on the dummy_udc UDC,
# capture the wire with usbmon (A4), let the host try to enumerate it, and assert
# the expected host-side observation. Per-fault artifacts (usbmon trace, dmesg
# delta, gadget log) are retained.
#
# Acceptance: each fault case can be triggered on demand and is
# observable on the host side.
#
# Usage:  a3-raw-gadget.sh [fault ...]     (default: full matrix)
set -euo pipefail
. "$(dirname "$0")/../lib/common.sh"

require_root

RAWDIR="$HARNESS_ROOT/raw_gadget"
A3="$RAWDIR/a3_device"
VID="dead"; PID="beef"          # a3_device's device descriptor identifiers
RUN_SECONDS="${RUN_SECONDS:-8}" # gadget self-terminates after this long
ENUM_WAIT="${ENUM_WAIT:-6}"     # how long to wait for host enumeration

# fault -> expectation: present | absent | anomaly
declare -A EXPECT=(
  [none]=present
  [slow]=present
  [stall-string]=present
  # Linux ignores the device descriptor's bLength (it is always treated as 18
  # bytes), so an over-large bLength enumerates fine -- the malformation is still
  # observable on the wire. The *library* is stricter and rejects it (see the
  # :usbfs_a3_blength test), which is the point of keeping this fault.
  [bad-device-blength]=present
  [short-device]=absent
  [stall-config]=absent
  [nak-forever]=absent
  [disconnect-mid]=absent
  [config-truncated]=absent
  [config-oversized]=absent
  [overflow]=absent
)
DEFAULT_ORDER="none slow stall-string bad-device-blength short-device stall-config nak-forever disconnect-mid config-truncated config-oversized overflow"

# Is our adversarial device currently enumerated on the host?
device_present() {
  local vf
  for vf in /sys/bus/usb/devices/*/idVendor; do
    [ -r "$vf" ] || continue
    if [ "$(cat "$vf" 2>/dev/null)" = "$VID" ] && \
       [ "$(cat "$(dirname "$vf")/idProduct" 2>/dev/null)" = "$PID" ]; then
      return 0
    fi
  done
  return 1
}

run_one() {
  local fault="$1" busnum="$2"
  local expect="${EXPECT[$fault]:-anomaly}"
  local trace="$ARTIFACTS_DIR/a3-${fault}.usbmon"
  local devlog="$ARTIFACTS_DIR/a3-${fault}.gadget.log"
  local dmsg="$ARTIFACTS_DIR/a3-${fault}.dmesg.log"

  log "fault '$fault' (expect: $expect)"
  local dmesg_mark; dmesg_mark="$(dmesg | tail -1)"

  "$HARNESS_ROOT/scripts/a4-usbmon.sh" start "$busnum" "$trace"

  # Launch the adversarial device; it self-terminates after RUN_SECONDS.
  RUN_SECONDS="$RUN_SECONDS" FAULT="$fault" "$A3" "$fault" > "$devlog" 2>&1 &
  local a3pid=$!

  # Give the gadget a moment to bind, then let the host enumerate.
  sleep 0.4
  local seen=absent
  if wait_for "$ENUM_WAIT" "enumeration attempt" -- device_present; then
    seen=present
  fi

  # Stop capture and gadget.
  "$HARNESS_ROOT/scripts/a4-usbmon.sh" stop "$trace"
  kill "$a3pid" 2>/dev/null || true
  wait "$a3pid" 2>/dev/null || true

  # dmesg delta since our mark.
  dmesg | awk -v m="$dmesg_mark" 'f{print} $0==m{f=1}' > "$dmsg" 2>/dev/null || true
  [ -s "$dmsg" ] || dmesg | tail -40 > "$dmsg"

  # A kernel-visible enumeration error is a valid "observable" signal even if
  # the device happens to appear briefly (kernel tolerance varies by version).
  local enum_error=1
  grep -qiE 'error -[0-9]+|not accepting|too short|unable to enumerate|cannot|can.?t (set|read)|no configurations|device descriptor read' "$dmsg" && enum_error=0

  # Evaluate.
  case "$expect" in
    present)
      if [ "$seen" = present ]; then
        case_pass "A3 $fault enumerated as expected"
      else
        case_fail "A3 $fault should enumerate but did not (dmesg: $dmsg)"
      fi
      ;;
    absent)
      # Fault must be observable: device did not stably enumerate, or the
      # kernel logged an enumeration error for it.
      if [ "$seen" = absent ] || [ "$enum_error" -eq 0 ]; then
        case_pass "A3 $fault broke enumeration as expected (observable)"
      else
        case_fail "A3 $fault should have broken enumeration but device appeared cleanly"
      fi
      ;;
  esac

  # Ensure the device is gone before the next fault (a3 may still be unbinding).
  local waited=0
  while device_present && [ "$waited" -lt 30 ]; do sleep 0.1; waited=$((waited+1)); done
  sleep 0.3
}

main() {
  local faults=("$@")
  [ ${#faults[@]} -eq 0 ] && read -r -a faults <<< "$DEFAULT_ORDER"

  # Bring up the controller and raw-gadget once for the whole matrix.
  local busnum
  busnum="$("$HARNESS_ROOT/scripts/load-dummy.sh")"
  defer "rmmod_quiet dummy_hcd"
  modprobe_checked raw_gadget || die "raw_gadget module not available"
  defer "rmmod_quiet raw_gadget"

  make -C "$RAWDIR" >/dev/null 2>&1 || die "failed to build a3_device"

  local f
  for f in "${faults[@]}"; do
    run_one "$f" "$busnum"
  done

  case_summary
}

main "$@"
