#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0

# Fetch a dummy_hcd.c that matches the running kernel closely enough to build.
#
# The kernel here is CONFIG_USB_DUMMY_HCD=n, so we grab upstream source. The
# dummy_hcd driver uses only exported gadget/udc-core symbols (present in this
# kernel's Module.symvers), so the mainline source for the matching major.minor
# tag builds cleanly out-of-tree.
#
# Override the source ref with DUMMY_HCD_REF (e.g. an Ubuntu tag or a commit).
# Override the whole file by dropping your own dummy_hcd.c here before build.
set -euo pipefail

cd "$(dirname "$0")"

if [ -f dummy_hcd.c ]; then
  echo "dummy_hcd.c already present, skipping fetch" >&2
  exit 0
fi

KVER="${KVER:-$(uname -r)}"
# Ubuntu release "7.0.0-22-generic" is based on mainline v7.0 -> tag "v7.0".
majmin="$(printf '%s' "$KVER" | grep -oE '^[0-9]+\.[0-9]+')"
REF="${DUMMY_HCD_REF:-v${majmin}}"

base="https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/plain/drivers/usb/gadget/udc"
url="${base}/dummy_hcd.c?h=${REF}"

echo "fetching dummy_hcd.c for kernel ${KVER} (ref ${REF})" >&2
if ! curl -fsSL --max-time 30 -o dummy_hcd.c.tmp "$url"; then
  echo "ERROR: failed to fetch $url" >&2
  echo "Set DUMMY_HCD_REF to a valid ref, or drop a dummy_hcd.c here manually." >&2
  rm -f dummy_hcd.c.tmp
  exit 1
fi

# Sanity check: must look like the driver, not an HTML error page.
if ! grep -q 'Dummy/Loopback USB host and device emulator' dummy_hcd.c.tmp; then
  echo "ERROR: fetched file does not look like dummy_hcd.c (ref ${REF} wrong?)" >&2
  rm -f dummy_hcd.c.tmp
  exit 1
fi

mv dummy_hcd.c.tmp dummy_hcd.c
echo "ok: $(wc -l < dummy_hcd.c) lines" >&2
