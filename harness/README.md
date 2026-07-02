# USB test harness (Part A)

The adversarial target that Part B (the actual USB library) is validated
against. It stands up a fully virtual USB stack on one machine using the
kernel's software UDC (`dummy_hcd`), drives it with known-good in-kernel
drivers, injects faults with a raw-gadget device, and captures the wire with
usbmon. See `../PROJECT.md` for the full plan.

Everything here runs against emulated USB only. No physical devices are
touched.

## Layout

```
harness/
  lib/common.sh              shared shell helpers (logging, root, cleanup, cases)
  modules/dummy_hcd/         out-of-tree build of dummy_hcd (kernel ships it =n)
  tools/testusb/             upstream testusb.c fetch + build (A2)
  raw_gadget/a3_device.c     adversarial device over /dev/raw-gadget (A3)
  scripts/
    load-dummy.sh            build+load dummy_hcd, print host bus number
    a1-dummy-loop.sh         A1 virtual loop + CDC-ACM gadget enumeration
    a2-gzero-usbtest.sh      A2 g_zero driven by the in-kernel usbtest baseline
    a3-raw-gadget.sh         A3 fault-injection matrix
    a4-usbmon.sh             A4 usbmon capture helper + selftest
  run-all.sh                 A1..A4 end to end, aggregated pass/fail
  Makefile                   build + per-stage targets
  artifacts/                 logs and usbmon traces (created on run)
```

## Why dummy_hcd is built here

This kernel is configured `CONFIG_USB_DUMMY_HCD=n`, so there is no
`dummy_hcd.ko` to load. `dummy_hcd` uses only exported gadget/udc-core symbols
(present in the running kernel's `Module.symvers`), so we compile the upstream
source out-of-tree against the installed kernel headers. `modules/dummy_hcd/
fetch.sh` pulls a `dummy_hcd.c` matching the running kernel's `major.minor`
(override with `DUMMY_HCD_REF`, or drop your own `dummy_hcd.c` in that dir).

## Requirements

- Linux with kernel headers for the running kernel (`linux-headers-$(uname -r)`)
  and a C compiler, for the out-of-tree module build.
- These modules available (typically `linux-modules-extra-$(uname -r)`):
  `raw_gadget`, `g_zero`, `usbtest`, `libcomposite`, `usb_f_acm`, `udc-core`,
  `usbmon`.
- `configfs` and `debugfs` (the scripts mount them if needed).
- Root for every run stage (module load, usbfs/configfs/raw-gadget, usbmon).

## Running in a VM (recommended)

The privileged stages (module load, raw-gadget, device resets) are best run in a
throwaway KVM VM: root without touching the host, and crash-isolated for when
Part B's NIF starts oopsing kernels. `vm/vm.sh` manages an Ubuntu cloud-image VM
with this repo shared in over virtio-9p. It builds and runs guest-local and
writes artifacts back to `harness/artifacts/` on the host.

```
harness/vm/vm.sh up          # boot the VM (first run downloads the cloud image)
harness/vm/vm.sh provision   # install headers, modules-extra, build tools (once)
harness/vm/vm.sh run all     # sync + run A1..A4 in the VM, artifacts on the host
harness/vm/vm.sh run a1      # a single stage (a1/a2/a3-run/a4)
harness/vm/vm.sh ssh         # shell into the guest
harness/vm/vm.sh down        # power off
```

VM state (image, disk overlay, ssh key) lives in
`~/.local/share/circuits-usb-vm/`, outside the repo. Needs `qemu-system-x86_64`,
`genisoimage`, and access to `/dev/kvm`. This is verified green on Ubuntu 24.04 /
kernel 6.8 (22/22 cases).

## Usage (directly, on a host you have root on)

Build (no root):

```
make -C harness build
```

Run stages (root):

```
sudo harness/scripts/a1-dummy-loop.sh      # A1
sudo harness/scripts/a2-gzero-usbtest.sh   # A2
sudo harness/scripts/a3-raw-gadget.sh      # A3 (all faults; or pass fault names)
sudo harness/scripts/a4-usbmon.sh selftest # A4
sudo harness/run-all.sh                    # A1..A4, aggregated
```

or via make: `sudo make -C harness all`.

Artifacts (per-case logs, dmesg deltas, usbmon traces, `results.tsv`) are
written to `harness/artifacts/`.

## A3 fault catalog

`a3-raw-gadget.sh [fault ...]` runs the whole matrix by default. Individual
faults (see `raw_gadget/a3_device.c`):

| fault                | injected behavior                              | expected host observation |
|----------------------|------------------------------------------------|---------------------------|
| `none`               | fully functional reference device              | enumerates                |
| `slow`               | delays every descriptor response               | enumerates (slowly)       |
| `stall-string`       | STALLs string descriptor reads                 | enumerates, no strings    |
| `bad-device-blength` | device descriptor with wrong `bLength`         | enumeration error         |
| `short-device`       | device descriptor returned as a short packet   | enumeration error         |
| `stall-config`       | STALLs the config descriptor read              | enumeration error         |
| `config-truncated`   | config sent shorter than its `wTotalLength`    | enumeration error         |
| `config-oversized`   | config `wTotalLength` claims far more than sent| anomaly on the wire       |
| `nak-forever`        | never answers the device descriptor read       | enumeration timeout       |
| `disconnect-mid`     | disconnects mid-enumeration                     | disconnect during setup   |

## The Part B hook

`a2-gzero-usbtest.sh` honors `A2_DRIVER_HOOK`: an executable that receives the
gadget-zero device node and drives it with our own userspace code. That is the
seam where Part B's transfer engine gets exercised against the same gadget the
in-kernel `usbtest` validates today.

## CI

`.github/workflows/harness.yml` installs headers + modules-extra, builds, and
runs A1..A4 under `sudo`, always uploading `harness/artifacts/`. Hosted runners
work when the kernel provides the gadget modules; otherwise dispatch the
workflow onto a self-hosted privileged runner via the `runner` input.
