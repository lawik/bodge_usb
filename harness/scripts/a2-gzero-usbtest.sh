#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0

# A2 -- Reference stress (g_zero + usbtest).
#
# Bind Gadget Zero on the device side over the dummy_hcd loop and exercise it
# with the in-kernel usbtest host driver as a known-good baseline. Captures a
# log artifact. (The library drives the same gadget via harness/vm/verify.sh, which
# runs the mix suite against a live g_zero -- so this stays the kernel baseline.)
#
# Acceptance: usbtest runs bulk source/sink, control-message,
# and halt/clear-halt cases against g_zero and passes; output captured.
set -euo pipefail
. "$(dirname "$0")/../lib/common.sh"

require_root

# Gadget Zero identifiers (source/sink config). usbtest's id_table already
# matches this VID/PID, so it auto-binds when g_zero enumerates.
GZ_VID="0525"
GZ_PID="a4a0"

# Curated known-good cases for gadget-zero source/sink over dummy_hcd:
#   1  bulk write (sink)     10 control queueing   13 set/clear halt (stall recovery)
#   2  bulk read (source)    11 unlink reads       14 control writes (ctrl_out)
#   3  bulk write varied      12 unlink writes
#   5  queued bulk writes      9 ch9 postconfig
# 11/12 (unlink) are the kernel baseline for our async discard/cancel path; 14
# is the baseline for control OUT with a data stage. 15/16 are isochronous,
# which dummy_hcd cannot emulate; B8 exercises isoc against QEMU usb-audio.
TESTS="${TESTS:-1 2 3 5 9 10 11 12 13 14}"
ITER="${ITER:-1000}"
SIZE="${SIZE:-1024}"
# usbtest's ctrl_out (case 14) requires vary < length, but testusb's default
# vary is 1024 == our SIZE, which fails the param check with EINVAL before any
# USB traffic. Keep vary at half the transfer size.
VARY="${VARY:-$((SIZE / 2))}"

TESTUSB_DIR="$HARNESS_ROOT/tools/testusb"
LOG="$ARTIFACTS_DIR/a2.log"

# Locate the gadget-zero host node: "NODE INTERFACE" (e.g. .../usb3 dev + 3-1:1.0)
find_gzero() {
  local vfile dev vid pid busnum devnum
  for vfile in /sys/bus/usb/devices/*/idVendor; do
    [ -r "$vfile" ] || continue
    dev="$(dirname "$vfile")"
    vid="$(cat "$vfile" 2>/dev/null)"
    pid="$(cat "$dev/idProduct" 2>/dev/null)"
    [ "$vid" = "$GZ_VID" ] && [ "$pid" = "$GZ_PID" ] || continue
    busnum="$(cat "$dev/busnum")"
    devnum="$(cat "$dev/devnum")"
    printf '%s %s\n' "$(basename "$dev")" "/dev/bus/usb/$(printf '%03d' "$busnum")/$(printf '%03d' "$devnum")"
    return 0
  done
  return 1
}

# Is any interface of our device bound to the usbtest driver? Gadget Zero's
# active config value is not necessarily 1 (it enumerates as e.g. 1-1:3.0), so
# match on any interface rather than a hardcoded config number.
usbtest_bound() {
  local devname="$1" i
  for i in /sys/bus/usb/devices/"${devname}":*; do
    [ -L "$i/driver" ] || continue
    [ "$(basename "$(readlink "$i/driver")")" = "usbtest" ] && return 0
  done
  return 1
}

bind_usbtest() {
  local devname="$1"
  usbtest_bound "$devname" && return 0
  # Force it if auto-bind did not happen: add the id, then bind each interface.
  echo "0x$GZ_VID 0x$GZ_PID" > /sys/bus/usb/drivers/usbtest/new_id 2>/dev/null || true
  local i
  for i in /sys/bus/usb/devices/"${devname}":*; do
    [ -e "$i" ] || continue
    echo "$(basename "$i")" > /sys/bus/usb/drivers/usbtest/bind 2>/dev/null || true
  done
  usbtest_bound "$devname"
}

main() {
  : > "$LOG"

  # 1. Controller loop up.
  local busnum
  busnum="$("$HARNESS_ROOT/scripts/load-dummy.sh")"
  defer "rmmod_quiet dummy_hcd"
  log "dummy_hcd up on host bus $busnum"

  # 2. Host driver first, so it auto-binds when the gadget enumerates.
  modprobe_checked usbtest || die "usbtest module not available"
  defer "rmmod_quiet usbtest"

  # 3. Gadget Zero on the device side (legacy module binds to the free UDC).
  modprobe_checked g_zero || die "g_zero module not available"
  defer "rmmod_quiet g_zero"

  # 4. Wait for enumeration and bind usbtest.
  if ! wait_for 5 "gadget zero to enumerate" -- find_gzero; then
    dmesg | tail -20 | tee -a "$LOG" >&2
    case_fail "A2 gadget-zero enumeration"
    return 1
  fi
  local info devname node
  info="$(find_gzero)"
  devname="$(printf '%s' "$info" | awk '{print $1}')"
  node="$(printf '%s' "$info" | awk '{print $2}')"
  log "gadget zero at $node (sysfs $devname)"

  if ! wait_for 5 "usbtest to bind" -- bind_usbtest "$devname"; then
    case_fail "A2 usbtest bind"
    return 1
  fi
  case_pass "A2 usbtest bound to gadget zero ($node)"

  # 5. Build testusb and run the curated case list, one test at a time so we
  #    get a clean per-case pass/fail.
  make -C "$TESTUSB_DIR" >>"$LOG" 2>&1 || die "failed to build testusb"
  local bin="$TESTUSB_DIR/testusb" t out
  for t in $TESTS; do
    log "usbtest case $t (iter=$ITER size=$SIZE vary=$VARY)"
    out="$("$bin" -D "$node" -t "$t" -c "$ITER" -s "$SIZE" -v "$VARY" 2>&1)" || true
    printf '=== test %s ===\n%s\n' "$t" "$out" >>"$LOG"
    if ! printf '%s' "$out" | grep -qi 'speed'; then
      # No speed line => testusb did not open/run the device at all.
      case_fail "A2 usbtest case $t: testusb did not run -- $out"
    elif printf '%s' "$out" | grep -q -- "-->"; then
      case_fail "A2 usbtest case $t: $(printf '%s' "$out" | grep -- '-->' | head -1)"
    elif printf '%s' "$out" | grep -q "test $t,"; then
      case_pass "A2 usbtest case $t"
    else
      # Anything else (unrecognized output, or no result line at all): fail
      # loudly. Every case in the curated list is known-good for gadget zero,
      # so a silent skip here would be silently dropped coverage.
      case_fail "A2 usbtest case $t: no recognizable result -- $out"
    fi
  done

  log "log artifact: $LOG"
  case_summary
}

main "$@"
