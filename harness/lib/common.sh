# shellcheck shell=bash
# Shared helpers for the USB test harness (Part A).
# Source this from every harness script:  . "$(dirname "$0")/../lib/common.sh"
#
# Provides: logging, root check, a cleanup-trap stack, wait/poll helpers,
# and a tiny pass/fail case recorder. No side effects on source beyond
# resolving HARNESS_ROOT and installing an EXIT trap.

set -euo pipefail

# --- paths ---------------------------------------------------------------
# HARNESS_ROOT is the directory that contains lib/, scripts/, modules/, etc.
_common_self="${BASH_SOURCE[0]}"
HARNESS_ROOT="$(cd "$(dirname "$_common_self")/.." && pwd)"
export HARNESS_ROOT
ARTIFACTS_DIR="${ARTIFACTS_DIR:-$HARNESS_ROOT/artifacts}"
export ARTIFACTS_DIR
mkdir -p "$ARTIFACTS_DIR"

# --- logging -------------------------------------------------------------
if [ -t 2 ]; then
  _c_red=$'\033[31m'; _c_grn=$'\033[32m'; _c_ylw=$'\033[33m'
  _c_blu=$'\033[34m'; _c_dim=$'\033[2m'; _c_rst=$'\033[0m'
else
  _c_red=; _c_grn=; _c_ylw=; _c_blu=; _c_dim=; _c_rst=
fi

_ts() { date +%H:%M:%S; }
log()  { printf '%s[%s]%s %s\n' "$_c_blu" "$(_ts)" "$_c_rst" "$*" >&2; }
warn() { printf '%s[%s] WARN%s %s\n' "$_c_ylw" "$(_ts)" "$_c_rst" "$*" >&2; }
err()  { printf '%s[%s] ERR%s  %s\n' "$_c_red" "$(_ts)" "$_c_rst" "$*" >&2; }
die()  { err "$*"; exit 1; }
ok()   { printf '%s[%s] OK%s   %s\n' "$_c_grn" "$(_ts)" "$_c_rst" "$*" >&2; }

# --- privilege -----------------------------------------------------------
require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "must run as root (need module load + usbfs/configfs/raw-gadget access). Re-run with sudo."
  fi
}

# --- cleanup trap stack --------------------------------------------------
# Register teardown commands with `defer "<command>"`. They run in reverse
# order on script exit (success or failure), each guarded so one failing
# cleanup does not abort the rest.
_defer_stack=()
defer() { _defer_stack+=("$1"); }
_run_deferred() {
  local rc=$? i
  for (( i=${#_defer_stack[@]}-1 ; i>=0 ; i-- )); do
    eval "${_defer_stack[$i]}" || warn "cleanup step failed: ${_defer_stack[$i]}"
  done
  return $rc
}
trap _run_deferred EXIT

# --- wait / poll ---------------------------------------------------------
# wait_for <timeout-seconds> <description> -- <command...>
# Polls the command (every 100ms) until it succeeds or the timeout elapses.
wait_for() {
  local timeout="$1" desc="$2"; shift 2
  [ "$1" = "--" ] && shift
  local deadline waited=0
  deadline=$(( timeout * 10 ))
  while ! "$@" >/dev/null 2>&1; do
    if [ "$waited" -ge "$deadline" ]; then
      err "timed out after ${timeout}s waiting for: $desc"
      return 1
    fi
    sleep 0.1
    waited=$(( waited + 1 ))
  done
  return 0
}

# --- module helpers ------------------------------------------------------
module_loaded() { lsmod | awk '{print $1}' | grep -qx "$1"; }

modprobe_checked() {
  local m="$1"
  if module_loaded "$m"; then return 0; fi
  if ! modprobe "$m" 2>/dev/null; then
    return 1
  fi
}

rmmod_quiet() { module_loaded "$1" && rmmod "$1" 2>/dev/null || true; }

# --- mounts --------------------------------------------------------------
ensure_configfs() {
  mountpoint -q /sys/kernel/config && return 0
  mkdir -p /sys/kernel/config
  mount -t configfs none /sys/kernel/config
}

ensure_debugfs() {
  mountpoint -q /sys/kernel/debug && return 0
  mount -t debugfs none /sys/kernel/debug
}

# --- case recorder -------------------------------------------------------
# Tracks pass/fail across a run and prints a summary. Result lines are also
# appended to $ARTIFACTS_DIR/results.tsv for CI to parse.
_case_pass=0
_case_fail=0
_results_file="${RESULTS_FILE:-$ARTIFACTS_DIR/results.tsv}"

case_pass() { _case_pass=$((_case_pass+1)); ok "PASS $*"; printf 'PASS\t%s\n' "$*" >>"$_results_file"; }
case_fail() { _case_fail=$((_case_fail+1)); err "FAIL $*"; printf 'FAIL\t%s\n' "$*" >>"$_results_file"; }

# Run a named case: case_run "<name>" cmd args...  (captures rc, records result)
case_run() {
  local name="$1"; shift
  if "$@"; then case_pass "$name"; else case_fail "$name"; fi
}

case_summary() {
  local total=$(( _case_pass + _case_fail ))
  printf '%s---- %d passed, %d failed (of %d) ----%s\n' \
    "$_c_dim" "$_case_pass" "$_case_fail" "$total" "$_c_rst" >&2
  [ "$_case_fail" -eq 0 ]
}
