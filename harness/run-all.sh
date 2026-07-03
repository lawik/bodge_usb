#!/usr/bin/env bash
# Run the full harness end to end: A1 -> A2 -> A3 -> A4.
# One command, headless, privileged. Aggregates per-case results and exits
# non-zero if any case failed. Artifacts land in harness/artifacts/.
set -uo pipefail
. "$(dirname "$0")/lib/common.sh"
# common.sh sets `-e`; this orchestrator must keep running past a failing stage
# to aggregate results, so turn it back off explicitly (don't rely on every
# stage command being individually guarded).
set +e

require_root

RESULTS="$ARTIFACTS_DIR/results.tsv"
: > "$RESULTS"

SCRIPTS="$HARNESS_ROOT/scripts"
declare -a STAGES=(
  "A1 dummy_hcd loop|$SCRIPTS/a1-dummy-loop.sh"
  "A2 g_zero/usbtest|$SCRIPTS/a2-gzero-usbtest.sh"
  "A3 raw-gadget faults|$SCRIPTS/a3-raw-gadget.sh"
  "A4 usbmon observability|$SCRIPTS/a4-usbmon.sh selftest"
)

overall=0
for stage in "${STAGES[@]}"; do
  name="${stage%%|*}"; cmd="${stage#*|}"
  printf '\n%s========== %s ==========%s\n' "$_c_blu" "$name" "$_c_rst" >&2
  # shellcheck disable=SC2086
  if ! RESULTS_FILE="$RESULTS" bash $cmd; then
    warn "$name reported failures"
    overall=1
  fi
  # Between stages, make sure no harness module is left loaded.
  for m in g_zero usbtest raw_gadget dummy_hcd; do rmmod_quiet "$m"; done
done

printf '\n%s========== SUMMARY ==========%s\n' "$_c_blu" "$_c_rst" >&2
if [ -s "$RESULTS" ]; then
  awk -F'\t' '{c[$1]++; print ($1=="PASS"?"  \033[32mPASS\033[0m ":"  \033[31mFAIL\033[0m ") $2}
              END{printf "\n  %d passed, %d failed\n", c["PASS"], c["FAIL"]}' "$RESULTS" >&2
  grep -q '^FAIL' "$RESULTS" && overall=1
else
  warn "no results recorded"
  overall=1
fi

log "artifacts in $ARTIFACTS_DIR"
exit $overall
