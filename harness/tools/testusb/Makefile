# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0

# Build the upstream testusb host-side test driver runner.
# fetch.sh drops a version-matched testusb.c next to this Makefile.
KVER ?= $(shell uname -r)
CC   ?= cc

.PHONY: all clean
all: testusb

testusb.c:
	KVER=$(KVER) ./fetch.sh

testusb: testusb.c
	$(CC) -O2 -Wall -o $@ $< -lpthread

clean:
	rm -f testusb
