CC    ?= cc
CFLAGS ?= -O2 -Wall -Wextra

.PHONY: all clean
all: a3_device

a3_device: a3_device.c
	$(CC) $(CFLAGS) -o $@ $<

clean:
	rm -f a3_device
