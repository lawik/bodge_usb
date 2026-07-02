# Out-of-tree build of dummy_hcd against the running kernel.
#
# This kernel ships CONFIG_USB_DUMMY_HCD=n, so we compile the upstream
# dummy_hcd.c ourselves. fetch.sh drops a version-matched dummy_hcd.c next
# to this Makefile; `make` then builds dummy_hcd.ko via kbuild.

obj-m += dummy_hcd.o

KVER ?= $(shell uname -r)
KDIR ?= /lib/modules/$(KVER)/build
PWD  := $(CURDIR)

.PHONY: all fetch clean

all: dummy_hcd.c
	$(MAKE) -C $(KDIR) M=$(PWD) modules

# Fetch the source only if it is not already present.
dummy_hcd.c:
	KVER=$(KVER) ./fetch.sh

fetch:
	KVER=$(KVER) ./fetch.sh

clean:
	-$(MAKE) -C $(KDIR) M=$(PWD) clean
