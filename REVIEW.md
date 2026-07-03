# Code review

Reviewed at commit `a4944c6` (working tree clean). Scope: the full library
(`lib/`, `c_src/`), the ExUnit suite, and the Part A harness + VM rig, with
extra attention on how well the harness exercises USB.

> **Status:** the findings below were addressed in `8006c9f`, `1d721f2`, and
> `56fd922`. See the **Fix review** section at the end for the verified
> per-finding status and the follow-up findings from that verification pass.

Overall: this is a carefully built codebase. The NIF is genuinely narrow and
size-validated, the URB registry is UAF-safe, select-stop-before-close is
handled correctly (including the stop-callback deadlock gotcha), descriptor
parsing is total and defensive, and the harness is a real adversarial rig, not
a smoke test. The issues below are mostly edges and seams, one memory-safety
bug in the isochronous path, and coverage gaps between Part A and Part B.

---

## Test harness assessment

### What it does well

- Layered, fully virtual stack: dummy_hcd loop (A1), in-kernel known-good
  baseline usbtest vs g_zero (A2), raw-gadget adversarial device with a
  10-fault catalog (A3), usbmon as wire ground truth (A4), one-command
  aggregation with per-case `results.tsv` and per-fault artifacts (usbmon
  trace + dmesg delta + gadget log). 22/22 recorded green.
- The KVM VM rig is the right call for NIF work: crash-isolated, root without
  touching the host, guest-local builds so host build products for a different
  kernel cannot contaminate, artifacts written back over 9p.
- Part B verification (`harness/vm/verify.sh`) is properly phased across
  gadget types: usbtest-bound g_zero (driver detach), free g_zero (control,
  bulk, async engine, timeout/cancel), stall via SET_FEATURE(ENDPOINT_HALT)
  then `:epipe` then `clear_halt`, device reset, mid-transfer disconnect via
  `rmmod g_zero`, hotplug churn, HID gadget for interrupt IN (with a usbmon
  `Ii:` assertion), QEMU usb-audio for isochronous OUT (with a `Zo:`
  assertion). The stall-recovery and mid-transfer-disconnect tests are exactly
  the right adversarial cases to run against the library.
- The timeout/cancel trick (1 MB bulk IN takes ~40 ms through dummy_hcd, so a
  10 ms timeout reliably fires mid-flight) makes the discard path
  deterministic without special hardware.

### Gaps (does it exercise USB well?)

At the kernel level, yes. The weak point is the seam between Part A and
Part B:

1. **The A3 adversarial matrix never touches the library.** A3 validates that
   the *kernel* observes/rejects hostile devices. Most faults prevent
   enumeration so no usbfs node exists and the library is shielded, which is a
   fair rationale, but it means PROJECT.md's B3/B9 acceptance ("degrades
   safely on every malformed-descriptor case in A3") is really validated by
   synthetic blobs in `descriptor_test.exs`, not the live A3 device. The two
   faults that *do* enumerate (`slow`, `stall-string`) would exercise the
   library's control-transfer timeout and string-read `:epipe` paths and are
   unused. Suggestion: add a verify.sh phase that runs `a3_device slow` /
   `stall-string` and points `Enumeration`/`Transfer` at it.
2. **`A2_DRIVER_HOOK` is dead code.** It was designed as the seam where Part B
   drives the same gadget usbtest validates, but verify.sh reimplements its
   own phases and nothing sets the hook. `run-all.sh` can pass with a broken
   library. Either wire a mix-driven hook script into A2 or remove the hook.
3. **Data integrity is weakly verified on the library path.** g_zero is loaded
   with its default `pattern=0` (all zeros), so `assert {:ok, ^data}` and
   `byte_size` checks cannot catch buffer corruption, offset bugs, or stale
   memory; any zeroed buffer passes. Only the 18-byte GET_DESCRIPTOR
   round-trip checks real content. Load g_zero with `pattern=1` (mod63) and
   assert content in the bulk tests; that also makes the sink verify OUT data
   nontrivially.
4. **Untested transfer paths:** interrupt OUT (API exists, no device phase);
   isochronous IN (usb-audio is playback-only; note this path currently has
   bug H1); bulk short reads (`actual_length < requested`, the source always
   fills the buffer); control OUT with a data stage against a real device
   (only zero-length SET_FEATURE is exercised).
5. **Concurrency/lifecycle churn is light** relative to the B5 acceptance
   ("no fd/select lifecycle errors under churn"): one 300-transfer IN
   pipeline. No mixed IN/OUT concurrency, no cancel storm, no repeated
   open/claim/transfer/close cycling, no engine-killed-abnormally case (see
   M9). The new mid-transfer `stop` test covers the STOP-teardown path once,
   which is good.
6. **Hotplug** asserts only add/remove; bind/unbind/change parsing and
   event-storm behavior (netlink ENOBUFS overrun) are untested.
7. **CI runs Part A only** (see M6): no workflow builds the NIF or runs even
   the host-safe `mix test`; the verify.sh flow is manual.

Smaller harness notes are in the Low list (L10, L11, L13).

---

## High

- **H1: isochronous IN returns uninitialized heap memory.**
  `nif_submit_iso` allocates the transfer buffer without zeroing it
  (`c_src/circuits_usb_nif.c:899`), and `nif_reap` copies the *entire*
  `buffer_len` back to the caller (`c_src/circuits_usb_nif.c:1049`). Packets
  that complete short (or error) leave gaps that were never written by the
  kernel, so previously-freed allocator contents leak into an Erlang binary.
  Fix: `memset` the buffer for IN iso URBs at submit, or compact per-packet
  data using each `iso_frame_desc[i].actual_length` at reap.

## Medium

- **M1: timeout race can report `{:error, :timeout}` for a transfer that
  completed successfully, dropping its data.** When the engine's timer fires
  it calls `Shim.discard` and marks the URB `timed_out`
  (lib/circuits_usb/transfer.ex:234) regardless of the discard result; the
  NIF maps ENOENT/EINVAL ("already completed") to `:ok`
  (c_src/circuits_usb_nif.c:1109). `result_for/3` then returns `:timeout` for
  any status (lib/circuits_usb/transfer.ex:289), including a reap with
  `status == :ok` and full payload. For IN the received data is discarded;
  for OUT the caller cannot know the bytes hit the wire. Fix: only translate
  to `:timeout` when the reaped status is `:econnreset` (the actual discard
  signature); otherwise return the real result.
- **M2: blocking ioctls hold the per-fd mutex, and sync control transfers
  block the whole engine.** The dirty-scheduler NIFs (control at
  c_src/circuits_usb_nif.c:463, bulk at :580, set_interface, detach/attach,
  clear_halt, reset) hold `r->lock` across the blocking ioctl, which the
  file's own header comment says must not happen. Any concurrent NIF on the
  same handle from another process (including `close/1`, `read`, `reap`, all
  normal-scheduler) blocks a normal scheduler thread for the duration;
  `timeout_ms = 0` makes that unbounded. At the engine level, `control_in/out`
  run synchronously inside `handle_call` (lib/circuits_usb/transfer.ex:195,
  :198) with an `:infinity` GenServer timeout, so a slow/NAKing control
  transfer stalls all reaping and timeout handling, and `timeout_ms = 0`
  wedges the engine permanently. Fix: release the mutex around blocking
  ioctls (refcount the fd or take a dup), reject/clamp `timeout_ms = 0`, and
  consider making engine control transfers non-blocking for the GenServer.
- **M3: endpoint-direction/payload mismatch crashes the engine.**
  `Transfer.bulk_in(eng, 0x02, 512)` (OUT address) or `bulk_out(eng, 0x81,
  data)` reaches the NIF, which raises badarg *inside the GenServer*, killing
  the engine and failing every in-flight caller. Validate bit 7 of the
  endpoint against the payload type in `Transfer` (or rescue in the call) and
  return `{:error, :einval}` instead.
- **M4: the high-level API can only issue standard device-level control
  transfers.** `Shim.control_in/control_out` hardcode `bmRequestType` to
  0x80/0x00 (lib/circuits_usb/shim.ex:94, :101) and `Transfer`/`CircuitsUsb`
  expose only those. Class/vendor/interface/endpoint-recipient requests (HID
  SET_REPORT, CDC line coding, the SET_FEATURE used by the recovery test
  itself...) require dropping to `Shim.control_transfer` on a *separate*
  handle. For a "drive arbitrary USB devices" library this is a core gap:
  plumb `request_type` through `Transfer.control_in/out` and the facade.
- **M5: isochronous is not usable through the engine or facade**, though the
  README claims iso "on an async submit/select/reap engine" (README.md:14-16).
  `submit_iso` exists only on the raw shim; the engine owns the handle and has
  no iso API, and its `deliver/result_for` would mistranslate `{:iso, ...}`
  payloads anyway. Add engine-level iso submit/completion or scope the README.
- **M6: no CI for Part B.** `.github/workflows/harness.yml` runs A1-A4 only.
  Nothing in CI compiles the NIF or runs `mix test` (even the host-safe
  suite), and the in-VM verify.sh flow is manual. PROJECT.md's definition of
  done requires Parts A and B passing in CI. A minimal step (build + host-safe
  `mix test` on ubuntu-latest) would catch most regressions cheaply.
- **M7: `vm.sh up` cannot work on a fresh machine.** Nothing ever downloads
  the base cloud image; `make_overlay` dies with "base image not present"
  (harness/vm/vm.sh:72), while harness/README.md says "first run downloads
  the cloud image". Add the fetch (noble server cloudimg URL + checksum) or
  correct the README.
- **M8: harness/library seam gaps** as detailed in the harness section above:
  A3 never exercised through the library, `A2_DRIVER_HOOK` dead, all-zeros
  pattern makes data-integrity assertions trivial.
- **M9: abnormal engine death can leak the fd.** The engine does not trap
  exits, so a linked caller crashing kills it without `terminate/2` and
  `Shim.close` never runs. GC then reclaims the resource only if select was
  never armed: an armed `enif_select` holds a resource reference until the
  stop callback, so a mid-transfer kill can pin the fd (and its URB memory)
  until VM shutdown. B1's close-on-GC guarantee holds only for never-selected
  handles. Fix: `Process.flag(:trap_exit, true)` in `init/1` so terminate
  runs, and document the caveat.

## Low

- **L1:** `nif_reap`'s ENOMEM fallback returns the actual length as an
  *integer* where the contract promises a binary for IN completions
  (c_src/circuits_usb_nif.c:1046, and the bulk IN equivalent), which would
  crash pattern-matching callers. Prefer failing the whole reap call.
- **L2:** `EXDEV` is missing from the errno map, so partially-completed iso
  URBs surface as `:e18` instead of `:exdev` (c_src/circuits_usb_nif.c:116).
- **L3:** Hotplug: subscribers are never monitored and there is no
  unsubscribe, so dead pids accumulate (lib/circuits_usb/hotplug.ex:62);
  `select_read` failures in `arm/1` are ignored so the watcher can go
  silently deaf (lib/circuits_usb/hotplug.ex:97); a netlink ENOBUFS overrun
  silently drops events; and plain `read()` cannot verify the sender is the
  kernel (libudev checks `nl_pid == 0` via `recvmsg`), worth a comment even
  though group-1 spoofing needs CAP_NET_ADMIN.
- **L4:** Undersized interface/endpoint descriptors (bLength 2..6) silently
  become all-nil structs, violating their typespecs
  (lib/circuits_usb/descriptor.ex:342, :362). Consider routing them to
  `extra` instead.
- **L5:** usbfs converts the device descriptor's multibyte fields
  (bcdUSB/idVendor/idProduct/bcdDevice) to *host* endianness on read, but the
  parser reads little-endian (lib/circuits_usb/descriptor.ex:150). Wrong on
  big-endian hosts; config descriptors are raw little-endian, so those are
  fine. Rare platform, cheap doc note.
- **L6:** `DeviceRef.bus/address` become `nil` for non-numeric path segments
  while the typespec says `pos_integer` (lib/circuits_usb/enumeration.ex:103).
- **L7:** `Shim.read/write` are normal-scheduler NIFs doing potentially
  blocking syscalls. Safe for usbfs descriptor reads and the nonblocking
  netlink socket, but the shim opens arbitrary paths; a blocking fd would
  stall a scheduler. Document, or default `:nonblock` for non-usbfs use.
- **L8:** timeout semantics: `0` means "no timeout" at every layer (no timer
  armed in the engine, infinite in the kernel), but specs say `timeout()` and
  nothing documents it. Reject or document 0 (interacts with M2).
- **L9:** the NIF registers no upgrade callback, so hot code upgrade of
  `CircuitsUsb.Shim` fails (VM restart required). Fine if intended; note it.
- **L10:** A2: a testusb case with unrecognized output is a warn/skip, not a
  failure (harness/scripts/a2-gzero-usbtest.sh:123), so a format change
  silently drops coverage. The curated list also omits unlink (11/12), the
  kernel baseline for the engine's discard path, and control writes (14).
- **L11:** A3: the `config-oversized` "anomaly" acceptance can pass with no
  adverse host observation (fault applied + request seen on the wire,
  harness/scripts/a3-raw-gadget.sh:113); and the "wrong wLength" case from
  PROJECT.md's A3 catalog was never implemented.
- **L12:** `mix.exs` package links to `github.com/TODO/circuits_usb`;
  CHANGELOG.md is a TODO stub. Blockers for the hex release the README
  implies.
- **L13:** `run-all.sh` deliberately sets `set -uo pipefail` (no `-e`), but
  sourcing `lib/common.sh` re-enables `-e`. Currently harmless because every
  failing command is guarded, but fragile against edits.

---

# Fix review

Fixes reviewed at commit `56fd922` (2026-07-03, working tree clean), covering
`8006c9f` (findings batch), `1d721f2` (harness: a3 ep0 ack + byte-exact
config + library-vs-a3 phases), and `56fd922` (fd refcount + async control
URBs).

How this was verified, beyond reading the diffs:

- Rebuilt the NIF from scratch on the host: clean under `-Wall -Wextra`.
- Ran the host suite (52 tests), `mix format --check-formatted`,
  `credo --strict`, and `dialyzer`: all green at `56fd922`.
- Fresh harness artifacts (2026-07-03 10:44-10:55) corroborate the in-VM
  verification: `results.tsv` is 25/25 PASS including the new `overflow`
  fault and unlink cases 11/12; the b7 trace contains the interrupt-IN
  URB pair; the b8 trace contains 40 `Zo:` isochronous submissions.
- Live-tested the riskiest new code in the VM (results below): the async
  control URB path with a real OUT data stage, and timeout/discard of an
  in-flight control URB.

## Verdict

The response is thorough and honest overall. Nothing was waved away with a
comment where code was warranted; two findings were resolved by
documentation (M5, L5/L7/L8) and each is explicitly scoped rather than
buried. The M2/M4 rework went beyond the suggested fix (async control URBs
instead of just caveats), and the harness seam work (M8) surfaced and fixed
two real pre-existing bugs in the adversarial device itself: the ep0 OUT-ack
wedge and the padded config descriptor that would have made even the `none`
device fail a strict parser. That second bug was only findable because the
library now runs against the live a3 device, which is exactly what the
review asked for.

Two genuine lapses found (F1, F2 below), plus a tail of small residuals.

## Per-finding status

| Finding | Status | Note |
|---------|--------|------|
| H1 iso IN heap leak | Fixed | `memset` at submit; correct and commented |
| M1 timeout race | Fixed, verified live | `:timeout` only on the cancel signature (`:econnreset`/`:enoent`); raced `:ok` returns data |
| M2 lock across blocking ioctls | Fixed thoroughly | `begin/end_blocking` refcount + deferred close; all 7 blocking ioctls converted; errno captured before release; close/stop/dtor ordering sound. Engine control moved to async URBs, so control no longer blocks reaping and `timeout=0` no longer wedges |
| M3 badarg crashes engine | Fixed | rescue in `track_async` -> `{:error, :einval}` |
| M4 no class/vendor control | Fixed, verified live | `control_transfer/7` through engine + facade; vendor `0x40`/`0xC0` round-trip confirmed against g_zero |
| M5 iso not in engine | Deferred, documented | README/CHANGELOG rescoped honestly. Largest remaining API gap; see residuals |
| M6 no Part B CI | Fixed | ci.yml: compile -W, format, credo, host tests. Dialyzer missing (4s with a warm PLT; cacheable) |
| M7 vm.sh image download | Fixed | Works; no checksum and unpinned `current` image |
| M8 harness/library seam | Fixed exquisitely | pattern=1 + byte-exact content assert; live a3 phases (stall-string, bad-device-blength, slow) with `adversarial_test.exs`; found+fixed 2 real a3 bugs; A2 hook removed with the seam documented in verify.sh |
| M9 select-pinned fd leak | Fixed | trap_exit + `{:EXIT}` -> stop -> terminate closes |
| L1 reap OOM int payload | Fixed | Empty binary keeps the contract (chose contract-keeping over failing the reap; fine) |
| L2 EXDEV | Fixed | |
| L3 hotplug robustness | Partial | Monitors + DOWN cleanup + arm-failure logging done. ENOBUFS overrun still silently ends `drain/2`; no kernel-sender note |
| L4 all-nil descriptor structs | Fixed | nil -> `extra` routing; no unit test added for the new behavior |
| L5 BE endianness | Documented | As suggested |
| L6 DeviceRef nil typespec | Fixed | |
| L7 blocking read/write | Documented | As suggested |
| L8 timeout=0 semantics | Documented | And defanged by async control |
| L9 NIF upgrade | Fixed | `load` reused; CREATE\|TAKEOVER is the right pattern |
| L10 A2 skip/coverage | Mostly fixed | Loud classification; unlink 11/12 added and passing. Case 14 dropped on a misdiagnosis: see F1 |
| L11 A3 loose acceptance | Fixed | `config-oversized` now strict `absent`; new `overflow` fault covers wrong-wLength; `bad-device-blength` correctly reclassified `present` (Linux ignores device bLength) with a live library-rejects-it test |
| L12 TODO links | Half | CHANGELOG written; `mix.exs` still links `github.com/TODO/circuits_usb` |
| L13 run-all set -e | Fixed | Explicit `set +e` with comment |

## New findings from this pass

- **F1: usbtest case 14 was dropped on a misdiagnosis.** The commit says
  "case 14 (iso, unsupported on g_zero)". Case 14 is *control writes*
  (15/16 are the iso cases), and it fails at A2's defaults because testusb's
  default `vary` is 1024 and kernel usbtest's `ctrl_out` rejects
  `vary >= length` with `-EINVAL` before any USB traffic. Verified live in
  the VM: `testusb -t 14 -s 1024` -> `test 14 --> 22 (Invalid argument)`;
  `testusb -t 14 -s 1024 -v 512` -> passes in 0.4s. The new comment block in
  `a2-gzero-usbtest.sh` even contradicts itself (lists "14 control writes",
  then claims "Cases 14+ are isochronous"). Fix: pass `-v 512` (or raise
  SIZE) and reinstate 14; it is the kernel baseline for exactly the
  control-OUT-with-data path the engine just gained.
- **F2: the a3 `slow` device wedges after a host-side cancel.** Live test:
  `Transfer.control_in(eng, ..., timeout: 100)` against `slow` correctly
  returns `{:error, :timeout}` in ~102ms (engine discards the control URB,
  M1 mapping correct, engine stays healthy), but a follow-up
  `control_in(..., 2000)` gets `{:error, :epipe}` and the gadget log shows
  the second request never reaches its event loop: the device woke from its
  400ms sleep, answered the dead request, and stalled (likely blocked in
  `EP0_WRITE` for a transaction the host had unlinked). The library behaved
  correctly throughout; this is an a3_device robustness gap. Consequence:
  "timeout, then retry succeeds" cannot be exercised against `slow`.
  Per-fault process isolation in `run_a3_phase` contains it today; fixing
  `a3_device` to survive a stale ep0 write would enable the retry scenario.
- **F3: residual gaps, none blocking:**
  - Engine `control_transfer/7` uses an `:infinity` GenServer call timeout
    while bulk/interrupt use `call_timeout/1` (+5s slack backstop). A wedged
    engine hangs control callers forever; use the same backstop.
  - `Shim.close/1` can no longer return `{:error, atom}` but the spec/doc
    still advertise it; and during a deferred close (blocking ioctl in
    flight) `submit`/`read`/`write`/`fileno` still accept work because they
    check only `fd < 0`, not `closing`. Memory-safe, but a post-close submit
    can succeed. Low.
  - `submit_iso` docs do not state the (new) IN semantics: gaps between
    short packets are zero-filled and each packet's data sits at its
    requested-length offset.
  - Still untested transfer paths, unchanged from the original list:
    interrupt OUT, isochronous IN, bulk short reads, engine churn / cancel
    storms / mixed IN+OUT concurrency, hotplug bind/unbind. Two others were
    verified live during this pass but exist as no committed test: the
    control OUT data stage (g_zero vendor `0x5b`/`0x5c` round-trips through
    the engine and echoes byte-exact) and engine-control timeout/discard.
    The 0x5b/0x5c round-trip would make a cheap, high-value `:usbfs` test.
  - CI: add `mix dialyzer` (PLT is cacheable alongside deps/_build).
  - vm.sh: pin the cloud image (dated URL) and record a checksum.
  - `descriptor_test.exs` not extended for the L4 behavior change
    (undersized endpoint/interface descriptors now land in `extra`).

## Bottom line

24 of 26 findings landed properly, most with verification behind them, and
the fixes hold up under adversarial re-testing (host suite, static gates,
and live VM exercises of the newest code paths all pass at `56fd922`).
Credit where due: wiring the library against the live adversarial device
immediately exposed two real pre-existing bugs in the a3 device itself, and
both fixes are correct; the documentation-only resolutions are explicitly
scoped rather than buried.

## Ordered next steps (path to bedrock)

1. **F1: reinstate usbtest case 14** with `-v 512` (or SIZE >= 2048) in
   `a2-gzero-usbtest.sh`, and fix the self-contradicting comment (15/16 are
   the iso cases, not 14). VM-verified to pass in 0.4s.
2. **F2: make a3_device survive a host-side cancel** so "timeout, then retry
   succeeds" becomes testable against `slow`. Until then, per-fault process
   isolation contains the wedge; document it in the fault table.
3. **Commit the live-verified scenarios as tests:**
   - g_zero vendor `0x5b`/`0x5c` control OUT/IN data-stage round-trip
     through the engine (`:usbfs` tag; cheap and high-value, covers the new
     `submit_control` marshalling byte-exact in both directions).
   - Engine control timeout/discard (100ms against a3 `slow` returns
     `{:error, :timeout}` in ~102ms, engine stays healthy).
4. **F3 engine/API tail:** control `GenServer.call` backstop
   (`call_timeout/1` instead of `:infinity`); check `closing` in
   `submit`/`read`/`write`/`fileno`; align `Shim.close/1` spec/doc with the
   always-`:ok` behavior; document `submit_iso` IN gap-zeroing semantics.
5. **F3 coverage tail:** interrupt OUT, isochronous IN, bulk short reads,
   engine churn / cancel storms / mixed IN+OUT concurrency, hotplug
   bind/unbind; extend `descriptor_test.exs` for the L4 undersized-to-extra
   behavior.
6. **F3 infra tail:** `mix dialyzer` in ci.yml (PLT cacheable alongside
   deps/_build); pin the VM cloud image (dated URL + checksum); replace the
   `github.com/TODO` link in mix.exs.
7. **M5, the one deliberate deferral: isochronous through the engine.** Now
   the largest API hole, and the engine already has all the machinery
   (per-URB tracking, `data_off`, discard, timers); it needs a submit path
   and a completion payload shape. This is the last piece before the README
   claim "nice Elixir API over bedrock" holds for every transfer type.

---

# Testing and hardening pass (2026-07-03)

A dedicated pass over "is anything skipped or bypassed", plus additional
tests and hardening. Steps 1-6 of the checklist above were implemented here;
step 7 (engine isochronous) remains the one open feature.

Verified: host gates green (58 tests, format, credo --strict, dialyzer, C
clean under -Wall -Wextra); full in-VM verify.sh green end to end (exit 0,
all ten device phases including the new tests); A2 green 11/11 including the
reinstated case 14 (0.4s).

## Skip/bypass audit results

- No `@tag :skip`, pending, or commented-out tests exist anywhere.
- Every device tag in the suite maps to a verify.sh phase: `usbfs`,
  `usbfs_driver`, `usbfs_int`, `usbfs_iso`, `usbfs_reset`,
  `usbfs_disconnect`, `usbfs_hotplug`, `usbfs_a3_stall`, `usbfs_a3_blength`,
  `usbfs_a3_slow`. None is orphaned.
- A `mix test --only <tag>` phase that matches zero tests (tag typo) exits 1
  on this Elixir version, so verify.sh's `set -e` already fails the run;
  checked empirically, no guard needed.
- Three real bypasses existed and are now closed:
  - The usbmon evidence checks in verify.sh (interrupt `Ii:`/`Io:`, isoc
    `Zo:`/`Zi:`) were print-a-WARNING-and-continue. They are acceptance
    evidence, so they now hard-fail the run (and use `grep -a`: usbmon
    payloads can trip grep's binary detection, which would have skipped the
    check silently).
  - A2's "no clear result" branch logged a skip and moved on. Every case in
    the curated list is known-good for gadget zero, so any unclassifiable
    outcome now records a failure.
  - usbtest case 14 was reinstated (F1): the A2 script now passes
    `-v SIZE/2`, since testusb's default `vary` (1024) trips usbtest's
    `vary >= length` EINVAL check at our default size.

## Implemented in this pass

Library hardening:

- Transfer timeouts are validated at the call site (`defguardp
  valid_timeout`): a negative/float/atom timeout raises instead of silently
  meaning "wait forever". Host test included.
- `control_transfer/7` uses the same `call_timeout/1` backstop as
  bulk/interrupt instead of an `:infinity` GenServer call.
- The NIF refuses all work during a deferred close: `read`/`write`/
  `submit_urb`/`submit_control`/`submit_iso`/`reap`/`discard`/`get_driver`/
  `claim`/`release`/`fileno` now check `closing`, so "close returned :ok but
  a submit still succeeded" can no longer happen; `Shim.close/1` docs/spec
  now match the always-`:ok` behavior.
- Hotplug: unexpected uevent read errors (ENOBUFS overrun) are logged rather
  than swallowed; the kernel-sender trust model is documented on
  `netlink_uevent_open/0`.
- a3_device (F2 fixed): an ep0 I/O watchdog (SIGUSR1 timer, 500 ms) EINTRs a
  stale `EP0_WRITE`/`EP0_READ` after the host cancels an in-flight control
  transfer; raw-gadget's interrupt path dequeues the request and clears
  `ep0_*_pending`, so the device recovers. One nuance, confirmed against the
  6.8 raw_gadget.c source: until that recovery completes (remaining fault
  delay + watchdog, <= ~900 ms for `slow`), raw-gadget *stalls* any new SETUP
  (`gadget_setup` returns -EBUSY), so a retry inside the window sees a typed
  `:epipe` and a retry after it succeeds. The tests settle the device first
  and assert eventual recovery, making timeout-then-retry a verified,
  recoverable sequence.

New tests (host-safe, run everywhere including CI):

- Seeded deterministic fuzz (`fuzz_test.exs`): ~7500 inputs per run against
  `Descriptor.parse/1`, `parse_device/1`, `parse_configuration/1`,
  `decode_string/1`, `language_ids/1`, and `Hotplug.parse_uevent/1`; random
  bytes plus structured mutations (byte tamper, truncation, length-field
  tamper, splice, duplication) of a valid blob. Guards the "total, never
  raises" contract with volume, not just the curated catalog.
- Invalid-timeout and direction/payload-mismatch behavior of the engine.
- `submit_iso` boundaries: 128 packets pass marshalling, 129 reject;
  per-packet length caps at 0xFFFF.

New tests (device, wired into verify.sh phases):

- Control OUT with a real data stage through the engine: vendor 0x5b/0x5c
  round-trip against g_zero, byte-exact echo (the committed version of what
  the fix review verified ad hoc).
- Engine control timeout against the live `slow` device: `:timeout` in
  ~100 ms, engine alive, and the retry succeeds (exercises DISCARDURB on a
  control URB plus the F2 watchdog).
- Mixed IN/OUT/control concurrency with a cancel storm (120 tasks, 40
  concurrent, 5 ms-timeout cancels racing completions), then proves the
  pending map drained.
- 50 open/claim/transfer/close engine cycles with an fd-count assertion (the
  select-stop teardown path under churn).
- Close during a blocking sync bulk: deferred close returns immediately,
  refuses new work, the in-flight ioctl completes, then the fd tears down.
- Interrupt OUT through the engine, with gadget-side content verification:
  verify.sh captures the report from `/dev/hidg0` and byte-compares it.
- Reset test strengthened: the device must come back and parse after
  `USBDEVFS_RESET`, not merely return `:ok`.

Infrastructure:

- ci.yml runs `mix dialyzer` (PLT cached with `_build`).
- vm.sh honors `CIRCUITS_VM_IMAGE_SHA256` to verify the downloaded base
  image, and documents pinning a dated release URL.

## Proposed, not yet implemented (hardening backlog)

1. **ASAN/UBSan lane for the NIF.** Build `circuits_usb_nif.so` with
   `-fsanitize=address,undefined` and run the host suite with
   `LD_PRELOAD=libasan` in a scheduled CI job. The C is small and careful,
   but iso/control buffer arithmetic is exactly where sanitizers earn their
   keep. Highest-value item on this list.
2. **Bulk data-phase support in a3_device** (enable its bulk endpoints and
   serve traffic): unlocks short-read testing (device terminates early,
   `actual_length < requested`), NAK-forever on bulk, and babble at the bulk
   level, none of which g_zero can model.
3. **Isochronous IN device coverage**: QEMU usb-audio is playback-only; a
   raw-gadget isoc IN endpoint (or QEMU audio capture device) would exercise
   the iso IN reap path (including the zero-filled gap semantics) end to end.
4. **Hotplug depth**: assert `bind`/`unbind` actions in the churn test; an
   event-storm test that provokes ENOBUFS and asserts the new warning fires;
   consider a `recvmsg`-based sender check (`nl_pid == 0`) in the NIF rather
   than the documented trust assumption.
5. **Brutal-kill semantics**: `Process.exit(engine, :kill)` bypasses
   `terminate/2`, and an armed select pins the fd until VM shutdown (trap_exit
   only covers exit signals). Document it on `Transfer`, and consider an
   `:erlang.monitor`-based janitor process if it matters in practice.
6. **Soak lane**: hours-long churn (transfer + hotplug + reset cycles) in the
   VM on a schedule, watching fd counts and memory; catches slow leaks the
   50-cycle test cannot.
7. **Kernel-matrix lane**: dispatch the harness workflow across several
   Ubuntu kernels (6.8 HWE variants differ in dummy_hcd/raw-gadget behavior);
   the harness already builds dummy_hcd per-kernel.
8. `mix.exs` still links `github.com/TODO/circuits_usb` (blocked on the real
   repo URL).
