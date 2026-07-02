# USB-on-BEAM — Project Plan

A native USB library for Erlang/Elixir on Linux, built on a **USB-scoped syscall
NIF** over usbfs. The test harness is built first; the implementation is gated
behind it. No timelines or estimates in this document — sequence and acceptance
criteria only.

---

## 0. Intent

Drive arbitrary USB devices from the BEAM without shelling out to libusb and
without a generic "call any ioctl" gateway. The NIF is deliberately narrowed to
usbfs: a small, fixed, documented set of ioctls whose struct layouts we own and
validate. This keeps the risk profile comparable to a purpose-built NIF
(e.g. the circuits_* family) rather than "sharpest tool in the box."

The hard part of this project is **not** the ioctl call — it is the asynchronous
submit/select/reap concurrency model. Design for that from the start.

---

## 1. Scope and non-goals

**In scope**
- Linux only. usbfs (`/dev/bus/usb/BBB/DDD`) as the sole kernel interface.
- Control, bulk, interrupt, and isochronous transfers.
- Enumeration, descriptor parsing, interface claim/release, kernel-driver
  detach/reattach, endpoint-stall recovery, device reset, hotplug awareness.
- A NIF that exposes only the fixed usbfs ioctls plus the minimal fd shim
  (open/close/read/write, poll integration) needed to use them.

**Explicit non-goals**
- No generic ioctl passthrough. If a request code isn't a known usbfs one with a
  hardcoded, size-validated struct, the NIF rejects it.
- No macOS/Windows backend. (libusb would have given cross-platform for free;
  we are consciously trading that away.)
- No attempt to reimplement all of libusb's convenience surface beyond what's
  listed above.

---

## 2. Architecture

Three layers, bottom to top:

1. **Syscall shim (C NIF).** Owns file descriptors as NIF resources with a
   `close()`-on-GC destructor. Exposes: open, close, read, write, the fixed
   usbfs ioctls, and poll/readiness integration via `enif_select`. Handles
   pointer fixup for the known usbfs structs (`usbdevfs_urb.buffer`,
   `usbdevfs_ctrltransfer.data`) — one level of indirection, hardcoded, not a
   general marshaller. Captures `errno` immediately and maps to atoms
   (`:enoent`, `:eperm`, `:enodev`, ...).
2. **Transfer engine (Erlang/Elixir).** Submit/select/reap loop, per-transfer
   state, timeout handling, stall recovery, reference-counted device/interface
   handles. This is where the concurrency correctness lives.
3. **High-level API (Elixir).** Device discovery, descriptor structs,
   open/claim/transfer ergonomics, hotplug notifications.

Key design decisions to honor throughout:
- **Never block a normal scheduler.** Fast ioctls (submit, non-blocking reap)
  run inline; anything that can wait either runs on a dirty I/O scheduler or,
  preferably, is driven by `enif_select` on the usbfs fd so the BEAM poller
  signals reapability.
- **Tear down `enif_select` before closing an fd** (`ERL_NIF_SELECT_STOP` +
  stop callback). An in-flight select over a closed fd is a bug class.
- **Own every struct layout.** Validate buffer sizes against `_IOC_SIZE` /
  known struct size before the call so the kernel can't write past a short
  binary.
- Request codes exceed `INT_MAX` (the `_IOR`/`_IOWR` direction bits are high) —
  carry them as unsigned/64-bit end to end.

---

## 3. Environment & prerequisites

- Linux with kernel modules available: `dummy_hcd`, `usbtest`, `g_zero`
  (gadget zero), `libcomposite`, `usb_f_*` function modules, `raw_gadget`.
- `configfs` mounted; `debugfs` mounted for usbmon.
- Elixir/Erlang toolchain with a C compiler and `elixir_make` (or equivalent)
  for building the NIF.
- Root or udev rules for usbfs/gadget device nodes. CI runs privileged.
- Optional: QEMU with `qemu-xhci`, usbredir, for controller variety and
  hotplug churn (not required for the minimum rig).

---

# Part A — Test Harness (build first)

The harness must be green and running in CI before any implementation work in
Part B begins. It exists so that every implementation milestone has a concrete,
adversarial target to be validated against.

## A1 — Virtual USB loop (dummy_hcd)

**Deliverable.** Scripts/Makefile targets that load `dummy_hcd`, bring up a
software UDC + host controller pair, and tear it down cleanly. A gadget bound on
the device side appears on the host stack via usbfs on the same machine.

**Acceptance.** A stock gadget (e.g. mass storage or CDC-ACM via
configfs+libcomposite) enumerates and is visible under `/dev/bus/usb`; setup and
teardown leave no dangling modules or nodes.

## A2 — Reference stress (g_zero + usbtest)

**Deliverable.** Automation to bind Gadget Zero on the device side and exercise
it two ways: (a) the in-kernel `usbtest` host driver as a known-good baseline,
(b) a placeholder hook where our own userspace code will later drive the same
gadget.

**Acceptance.** `usbtest` runs its bulk source/sink, control-message, and
halt/clear-halt cases against g_zero over the dummy_hcd loop and passes. Output
is captured to a log artifact. The pattern-verification path (source/sink data
integrity) is confirmed working via the reference driver.

## A3 — Adversarial device (raw-gadget)

**Deliverable.** A `/dev/raw-gadget` harness that emulates arbitrary,
deliberately hostile devices. Catalog of fault injections, each individually
selectable:
- Malformed / truncated / oversized descriptors; wrong `wLength`.
- Endpoints that STALL on demand.
- Devices that NAK indefinitely.
- Disconnect mid-transfer.
- Slow/partial responses; unexpected short packets.

**Acceptance.** Each fault case can be triggered on demand and is observable on
the host side. This is the primary target for Part B's error-handling and
descriptor-parsing acceptance criteria.

## A4 — Observability (usbmon)

**Deliverable.** usbmon capture wired up (raw `/sys/kernel/debug/usb/usbmon/`
and/or pcap for Wireshark), with a helper to attach/detach captures around a
test run.

**Acceptance.** A transfer driven over the loop produces a usbmon trace that
shows the expected setup/data/status phases. This is ground truth for "what did
we actually put on the wire" and is referenced when diagnosing Part B failures.

## A5 — CI wiring

**Deliverable.** The above run headless and privileged in CI. Module loading,
loop setup, stress run, fault-injection matrix, capture, and teardown are one
command. Artifacts (logs, traces) are retained.

**Acceptance.** A clean CI run exercises A1–A4 end to end and reports
pass/fail per case with no manual steps. QEMU-based controller-variety and
hotplug-churn jobs may be added here as optional/extended lanes.

---

# Part B — Implementation (after harness is green)

Every milestone below states what in Part A validates it. Do not consider a
milestone done until its harness target passes.

## B1 — Syscall shim NIF

**Deliverable.** C NIF providing open, close, read, write over a fd wrapped in a
NIF resource with a `close()`-on-GC destructor. errno→atom mapping. Request
codes carried as 64-bit unsigned. No transfers yet.

**Acceptance.** Can open a usbfs node discovered via A1, read raw descriptors
back, and close it. A leaked handle is closed on GC (verify no fd leak under
repeated open/drop). Bad args return `badarg`, not crashes.

## B2 — usbfs marshalling + pointer fixup

**Deliverable.** Hardcoded, size-validated marshalling for the fixed usbfs
struct set: `usbdevfs_ctrltransfer`, `usbdevfs_bulktransfer`, `usbdevfs_urb`,
`usbdevfs_setinterface`, `usbdevfs_ioctl` (for detach/connect), etc. One level
of pointer fixup for `.data`/`.buffer` fields — allocate stable buffer, embed
real address at the known offset, run, read back.

**Acceptance.** Round-trips a control transfer's data buffer correctly against a
known g_zero pattern (A2). Undersized/oversized buffers are rejected before the
syscall, never passed through.

## B3 — Enumeration & descriptor parsing

**Deliverable.** Enumerate devices from `/dev/bus/usb`, read and parse device /
config / interface / endpoint / string descriptors into Elixir structs.

**Acceptance.** Correctly parses well-formed descriptors from A1 gadgets **and**
degrades safely (typed error, no crash) on every malformed-descriptor case in
A3. Cross-checked against usbmon (A4).

## B4 — Control + bulk transfers (synchronous path)

**Deliverable.** Blocking control and bulk transfers using the fast ioctls,
initially on a dirty I/O scheduler (correctness before concurrency polish).

**Acceptance.** Pattern-verified bulk source/sink and control-message exchange
against g_zero (A2) matches the reference behavior established by `usbtest`.

## B5 — Async submit / select / reap engine

**Deliverable.** The core concurrency layer. Fast `SUBMITURB` returns
immediately; `enif_select` on the usbfs fd signals reapability; non-blocking
`REAPURBNDELAY` collects completions. Per-transfer state, timeouts, cancellation
(`DISCARDURB`), and correct `ERL_NIF_SELECT_STOP` teardown before close.

**Acceptance.** Sustained multi-transfer bulk throughput against g_zero (A2)
with no scheduler stalls and no fd/select lifecycle errors under churn.
Cancellation and timeout paths verified against A3's NAK-forever and
slow-response cases.

## B6 — Interface claim + kernel-driver detach/reattach

**Deliverable.** Claim/release interface; detach an existing kernel driver
before claim and reattach after release (`GETDRIVER`, `DISCONNECT`/`CONNECT`
via `usbdevfs_ioctl`).

**Acceptance.** Can take over an interface bound to a stock driver (A1 gadget),
use it, release it, and see the original driver reattach. No leaked claims after
handle GC.

## B7 — Interrupt transfers

**Deliverable.** Interrupt IN/OUT on the async engine from B5.

**Acceptance.** Periodic interrupt-endpoint traffic against a suitable gadget
behaves correctly; timing/queue behavior confirmed via usbmon (A4).

## B8 — Isochronous transfers

**Deliverable.** Isochronous support: variable-length packet descriptor arrays,
per-packet status, the tighter buffer/timing handling. Treated as its own
milestone because it is the transfer type most likely to expose subtle bugs.

**Acceptance.** Isochronous streaming (e.g. against `usb-audio` under QEMU, or a
raw-gadget isoc endpoint) sustains without packet-accounting errors; per-packet
lengths and statuses reconcile with usbmon traces.

## B9 — Error recovery

**Deliverable.** Endpoint-stall detection and `CLEAR_HALT`; device reset;
graceful handling of mid-transfer disconnect surfaced as a typed event, not a
crash.

**Acceptance.** Every A3 fault case (stall, NAK, mid-transfer disconnect,
malformed response) produces a defined, typed outcome and leaves the engine in a
usable state. No scheduler thread is left blocked; no resource is leaked.

## B10 — High-level Elixir API + hotplug

**Deliverable.** Ergonomic device discovery, open/claim/transfer API, descriptor
structs, and hotplug notifications (netlink uevent watch — note this is awkward
from the BEAM and may itself sit behind the shim or a small port).

**Acceptance.** A representative end-to-end example (open a gadget, claim,
transfer, handle a scripted disconnect/reconnect via A5 hotplug churn) runs
cleanly. Public API documented.

---

## Cross-cutting concerns (apply to all Part B milestones)

- **Scheduler discipline.** Audit every NIF entry point: is it fast-and-inline,
  dirty-I/O, or select-driven? No blocking call on a normal scheduler, ever.
- **Resource lifecycle.** fd resources, in-flight URBs, and `enif_select`
  registrations must all have correct destruction ordering. Select-stop before
  close is a recurring failure mode — assert it.
- **Size validation.** No syscall runs with a buffer whose size hasn't been
  checked against the target struct / `_IOC_SIZE`.
- **Observability.** When a milestone's harness target fails, the first
  diagnostic is the usbmon trace (A4), not guesswork.
- **Permissions.** Document the udev rules / capabilities needed so the library
  is usable unprivileged where possible.

## Definition of done

- Parts A and B complete with all stated acceptance criteria passing in CI.
- The full A3 fault matrix is survived with typed errors and no VM instability.
- Sustained bulk and isochronous throughput against g_zero / QEMU devices
  without scheduler stalls or resource leaks.
- No generic-ioctl escape hatch exists in the shipped NIF.

## Reference points

- libusb's Linux backend URB submit/reap handling — study before finalizing the
  B5 design; it is the part implementations get subtly wrong.
- The circuits_* NIFs — model for a narrow, validated, purpose-built NIF.
- Linux kernel docs: usbfs ioctl interface, gadget/raw-gadget, dummy_hcd,
  usbtest, gadget zero, usbmon.
