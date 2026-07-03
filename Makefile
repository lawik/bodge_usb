# Build the circuits_usb NIF. Invoked by elixir_make during `mix compile`.
#
# elixir_make provides MIX_APP_PATH, ERTS_INCLUDE_DIR and ERL_EI_INCLUDE_DIR.
# Linux only: undefined ERTS symbols are resolved by the VM at NIF load time.

PREFIX = $(MIX_APP_PATH)/priv
NIF    = $(PREFIX)/circuits_usb_nif.so

SRC     = c_src/circuits_usb_nif.c
HEADERS = $(wildcard c_src/*.h)

CFLAGS ?= -O2 -Wall -Wextra
CFLAGS += -std=c11 -fPIC -Ic_src

# erts include dir: prefer what elixir_make passes, else ask erl directly.
ifdef ERTS_INCLUDE_DIR
CFLAGS += -I$(ERTS_INCLUDE_DIR)
else
CFLAGS += -I$(shell erl -noshell -eval 'io:format("~ts/erts-~ts/include", [code:root_dir(), erlang:system_info(version)])' -s init stop)
endif
ifdef ERL_EI_INCLUDE_DIR
CFLAGS += -I$(ERL_EI_INCLUDE_DIR)
endif

LDFLAGS += -shared

# Optional AddressSanitizer + UndefinedBehaviorSanitizer build (SANITIZE=1).
# The .so is instrumented; run the suite with the ASan runtime preloaded into
# the BEAM (it is not itself instrumented):
#   LD_PRELOAD=$(gcc -print-file-name=libasan.so) SANITIZE=1 mix test
# Used by the scheduled sanitizer CI lane, never by normal builds.
ifdef SANITIZE
SAN_FLAGS = -fsanitize=address,undefined -fno-omit-frame-pointer -fno-sanitize-recover=undefined
CFLAGS  += $(SAN_FLAGS) -g -O1
LDFLAGS += $(SAN_FLAGS)
endif

all: $(NIF)

$(NIF): $(SRC) $(HEADERS)
	@mkdir -p $(PREFIX)
	$(CC) $(CFLAGS) $(SRC) $(LDFLAGS) -o $@

clean:
	$(RM) $(NIF)

.PHONY: all clean
