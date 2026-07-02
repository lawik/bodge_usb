#!/usr/bin/env bash
# A4 -- Observability (usbmon).
#
# Attach/detach a usbmon capture around a test run. usbmon exposes a text
# stream per USB bus at /sys/kernel/debug/usb/usbmon/<bus>u ("0u" = all buses).
# Each line records a URB: 'S' submit / 'C' complete, with 'Ci'/'Co' for control
# transfers and the 8-byte setup packet -- ground truth for what hit the wire.
#
# Subcommands:
#   start <bus> <outfile>   begin capturing bus <bus> into <outfile>
#   stop  <outfile>         stop the capture started for <outfile>
#   selftest                A4 acceptance: prove a trace shows setup/data/status
#
# Acceptance (PROJECT.md A4): a transfer over the loop produces a usbmon trace
# that shows the expected setup/data/status phases.
set -euo pipefail
. "$(dirname "$0")/../lib/common.sh"

USBMON_DIR="/sys/kernel/debug/usb/usbmon"

cap_start() {
  local bus="$1" out="$2"
  require_root
  ensure_debugfs
  modprobe_checked usbmon || die "usbmon module not available"
  local node="$USBMON_DIR/${bus}u"
  [ -r "$node" ] || die "usbmon node $node not readable (bus $bus up?)"
  : > "$out"
  # Stream in the background; record the reader PID next to the output.
  cat "$node" > "$out" &
  echo $! > "${out}.pid"
  log "usbmon capture started: bus $bus -> $out (pid $(cat "${out}.pid"))"
}

cap_stop() {
  local out="$1"
  local pidf="${out}.pid"
  if [ -f "$pidf" ]; then
    local pid; pid="$(cat "$pidf")"
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    rm -f "$pidf"
    log "usbmon capture stopped ($out, $(wc -l < "$out" 2>/dev/null || echo 0) lines)"
  fi
}

selftest() {
  require_root
  local trace="$ARTIFACTS_DIR/a4-selftest.usbmon"
  local busnum
  busnum="$("$HARNESS_ROOT/scripts/load-dummy.sh")"
  defer "rmmod_quiet dummy_hcd"

  cap_start "$busnum" "$trace"
  defer "cap_stop '$trace'"

  # Generate control traffic: bring up a gadget and let the host enumerate it,
  # which is a textbook GET_DESCRIPTOR control transfer (setup/data/status).
  modprobe_checked g_zero || die "g_zero not available for selftest traffic"
  defer "rmmod_quiet g_zero"
  wait_for 5 "gadget zero to enumerate" -- bash -c \
    'grep -rlq a4a0 /sys/bus/usb/devices/*/idProduct 2>/dev/null'
  # A moment for the enumeration URBs to be flushed into the capture.
  sleep 0.5

  cap_stop "$trace"   # deferred cap_stop then becomes a no-op (pidfile gone)

  log "captured $(wc -l < "$trace") usbmon lines -> $trace"
  # Control-transfer setup phase: a submit ('S') of a control-in ('Ci') URB
  # carrying the standard GET_DESCRIPTOR setup packet '80 06'.
  if grep -Eq ' S Ci:' "$trace" && grep -Eq ' 80 06 ' "$trace" && grep -Eq ' C Ci:' "$trace"; then
    case_pass "A4 usbmon trace shows control setup/data/status"
  else
    case_fail "A4 usbmon trace missing expected control phases (see $trace)"
    warn "first trace lines:"; head -20 "$trace" >&2 || true
  fi
  case_summary
}

usage() { echo "usage: $0 {start <bus> <outfile>|stop <outfile>|selftest}" >&2; exit 2; }

cmd="${1:-}"; shift || true
case "$cmd" in
  start)    [ $# -eq 2 ] || usage; cap_start "$1" "$2" ;;
  stop)     [ $# -eq 1 ] || usage; cap_stop "$1" ;;
  selftest) selftest ;;
  *)        usage ;;
esac
