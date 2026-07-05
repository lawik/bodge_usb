#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0

# Fetch upstream tools/usb/testusb.c matching the running kernel's major.minor.
# Override with TESTUSB_REF; drop your own testusb.c here to skip the fetch.
set -euo pipefail
cd "$(dirname "$0")"

if [ -f testusb.c ]; then
  echo "testusb.c already present, skipping fetch" >&2
  exit 0
fi

KVER="${KVER:-$(uname -r)}"
majmin="$(printf '%s' "$KVER" | grep -oE '^[0-9]+\.[0-9]+')"
REF="${TESTUSB_REF:-v${majmin}}"
url="https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/plain/tools/usb/testusb.c?h=${REF}"

echo "fetching testusb.c (ref ${REF})" >&2
curl -fsSL --max-time 30 -o testusb.c.tmp "$url" || {
  echo "ERROR: failed to fetch $url" >&2; rm -f testusb.c.tmp; exit 1; }
grep -q 'USBTEST_REQUEST' testusb.c.tmp || {
  echo "ERROR: fetched file is not testusb.c" >&2; rm -f testusb.c.tmp; exit 1; }
mv testusb.c.tmp testusb.c
echo "ok: $(wc -l < testusb.c) lines" >&2
