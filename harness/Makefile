# USB test harness (Part A) orchestration.
#
# Most targets need root (module load, usbfs/configfs/raw-gadget, usbmon).
# Build targets (dummy_hcd, testusb, a3_device) do not.

SHELL   := /bin/bash
SCRIPTS := scripts
KVER    ?= $(shell uname -r)

.PHONY: help build modules testusb a3 \
        a1 a2 a3-run a4 all clean distclean check-root

help:
	@echo "USB harness (Part A) targets:"
	@echo "  make build      build dummy_hcd.ko, testusb, a3_device (no root)"
	@echo "  make a1         A1 dummy_hcd virtual loop            (root)"
	@echo "  make a2         A2 g_zero + usbtest reference stress (root)"
	@echo "  make a3-run     A3 raw-gadget fault matrix           (root)"
	@echo "  make a4         A4 usbmon observability selftest     (root)"
	@echo "  make all        run A1..A4 end to end                (root)"
	@echo "  make clean      remove build products"
	@echo "  make distclean  clean + drop fetched sources"

# ---- build (no root) ----
build: modules testusb a3

modules:
	$(MAKE) -C modules/dummy_hcd KVER=$(KVER)

testusb:
	$(MAKE) -C tools/testusb KVER=$(KVER)

a3:
	$(MAKE) -C raw_gadget

# ---- run (root) ----
check-root:
	@if [ "$$(id -u)" -ne 0 ]; then echo "this target needs root (sudo make ...)"; exit 1; fi

a1: check-root
	$(SCRIPTS)/a1-dummy-loop.sh

a2: check-root
	$(SCRIPTS)/a2-gzero-usbtest.sh

a3-run: check-root
	$(SCRIPTS)/a3-raw-gadget.sh

a4: check-root
	$(SCRIPTS)/a4-usbmon.sh selftest

all: check-root
	./run-all.sh

# ---- cleanup ----
clean:
	-$(MAKE) -C modules/dummy_hcd clean
	-$(MAKE) -C tools/testusb clean
	-$(MAKE) -C raw_gadget clean
	rm -rf artifacts

distclean: clean
	rm -f modules/dummy_hcd/dummy_hcd.c tools/testusb/testusb.c
