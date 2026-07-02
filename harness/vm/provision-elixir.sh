#!/usr/bin/env bash
# Install a matching Erlang/Elixir toolchain in the guest via mise, so the
# circuits_usb library (Part B) can be built and run against the harness inside
# the VM. Runs IN the guest. Idempotent. The OTP build is from source (~10-15
# min); a trimmed configure keeps it lean.
#
# Target versions match the host: OTP 29.0.2, Elixir 1.20.2-otp-29.
set -euo pipefail

ERLANG_VERSION="${ERLANG_VERSION:-29.0.2}"
ELIXIR_VERSION="${ELIXIR_VERSION:-1.20.2-otp-29}"

echo "== installing OTP build dependencies =="
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -y
sudo apt-get install -y --no-install-recommends \
  build-essential autoconf m4 libncurses-dev libssl-dev \
  git curl unzip ca-certificates

if [ ! -x "$HOME/.local/bin/mise" ]; then
  echo "== installing mise =="
  curl -fsSL https://mise.run | sh
fi
export PATH="$HOME/.local/bin:$PATH"
eval "$("$HOME/.local/bin/mise" activate bash)"

# Trim the OTP build: no GUI/debugger/odbc/etc.
export KERL_CONFIGURE_OPTIONS="--without-wx --without-javac --without-odbc \
  --without-debugger --without-observer --without-et --without-megaco \
  --without-jinterface"

echo "== installing erlang@$ERLANG_VERSION (source build, be patient) =="
mise install "erlang@$ERLANG_VERSION"
# Activate erlang before installing elixir: the elixir launcher shells out to
# `erl`, and mise's post-install check fails with 127 if it isn't on PATH yet.
mise use -g "erlang@$ERLANG_VERSION"
eval "$("$HOME/.local/bin/mise" activate bash)"
echo "== installing elixir@$ELIXIR_VERSION =="
mise install "elixir@$ELIXIR_VERSION"
mise use -g "elixir@$ELIXIR_VERSION"

echo "== versions =="
"$HOME/.local/bin/mise" exec -- elixir --version

echo "TOOLCHAIN_DONE"
