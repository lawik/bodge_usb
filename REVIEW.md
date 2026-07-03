# Code review

Reviewed at commit `a4944c6` (working tree clean). Scope: the full library
(`lib/`, `c_src/`), the ExUnit suite, and the Part A harness + VM rig, with
extra attention on how well the harness exercises USB.

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
