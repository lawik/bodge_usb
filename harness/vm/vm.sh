#!/usr/bin/env bash
# Manage a disposable, SSH-driven QEMU VM for running the USB harness as root
# without touching the host. Ubuntu cloud image + cloud-init + a virtio-9p share
# of this repo. KVM-accelerated. State lives outside the repo.
#
# Subcommands:
#   up          create disk/seed if needed and boot the VM (waits for SSH)
#   provision   install kernel headers/modules-extra/build tools, mount the repo
#   ssh [cmd]   run a command in the VM as user dev (interactive if no cmd)
#   run <stage> run a harness stage in the VM as root (e.g. run all, run a1)
#   status      show VM/ssh state
#   down        power the VM off cleanly
#   destroy     power off and delete the disk overlay (keeps base image + seed)
set -euo pipefail

STATE="${CIRCUITS_VM_STATE:-$HOME/.local/share/circuits-usb-vm}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KEY="$STATE/id_ed25519"
BASE="$STATE/noble-cloudimg.qcow2"
OVERLAY="$STATE/disk.qcow2"
SEED="$STATE/seed.iso"
SERIAL="$STATE/serial.log"
PIDFILE="$STATE/qemu.pid"
MONITOR="$STATE/monitor.sock"
SSH_PORT="${CIRCUITS_VM_SSH_PORT:-2222}"
MEM="${CIRCUITS_VM_MEM:-8192}"
CPUS="${CIRCUITS_VM_CPUS:-8}"
MOUNT_TAG=repo
GUEST_REPO=/mnt/repo
GUEST_HARNESS=/home/dev/harness
GUEST_ARTIFACTS="$GUEST_REPO/harness/artifacts"

SSHOPTS=(-i "$KEY" -p "$SSH_PORT"
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR -o ConnectTimeout=5)
SSH_HOST=dev@127.0.0.1

log() { printf '[vm] %s\n' "$*" >&2; }
die() { printf '[vm] ERROR: %s\n' "$*" >&2; exit 1; }

vm_running() { [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }

make_seed() {
  [ -f "$SEED" ] && return 0
  [ -f "$KEY.pub" ] || die "missing ssh key $KEY.pub (run 'up' which generates it)"
  local pub; pub="$(cat "$KEY.pub")"
  local tmp; tmp="$(mktemp -d)"
  cat > "$tmp/meta-data" <<EOF
instance-id: usbvm-001
local-hostname: usbvm
EOF
  cat > "$tmp/user-data" <<EOF
#cloud-config
hostname: usbvm
users:
  - name: dev
    groups: [sudo]
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - $pub
EOF
  genisoimage -output "$SEED" -volid cidata -joliet -rock \
    "$tmp/user-data" "$tmp/meta-data" >/dev/null 2>&1
  rm -rf "$tmp"
  log "created cloud-init seed $SEED"
}

BASE_IMAGE_URL="${CIRCUITS_VM_IMAGE_URL:-https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img}"

fetch_base_image() {
  [ -f "$BASE" ] && return 0
  command -v curl >/dev/null 2>&1 || die "curl needed to download the base image"
  log "downloading base cloud image (~600MB, one time): $BASE_IMAGE_URL"
  curl -L --fail --retry 3 -C - -o "$BASE.part" "$BASE_IMAGE_URL" || die "image download failed"
  mv "$BASE.part" "$BASE"
}

make_overlay() {
  [ -f "$OVERLAY" ] && return 0
  fetch_base_image
  qemu-img create -f qcow2 -F qcow2 -b "$BASE" "$OVERLAY" 20G >/dev/null
  log "created disk overlay $OVERLAY (20G, backed by base)"
}

cmd_up() {
  mkdir -p "$STATE"
  [ -f "$KEY" ] || ssh-keygen -t ed25519 -N '' -C circuits-usb-vm -f "$KEY" >/dev/null
  if vm_running; then log "VM already running (pid $(cat "$PIDFILE"))"; wait_ssh; return; fi
  make_seed
  make_overlay
  log "booting VM (kvm, ${CPUS} cpu, ${MEM}MB, ssh -> 127.0.0.1:${SSH_PORT})"
  # An emulated xHCI + usb-audio device gives the guest a real isochronous
  # endpoint (dummy_hcd cannot emulate isoc), for the B8 isochronous tests.
  qemu-system-x86_64 \
    -enable-kvm -cpu host -smp "$CPUS" -m "$MEM" \
    -drive file="$OVERLAY",if=virtio,format=qcow2 \
    -drive file="$SEED",if=virtio,format=raw,readonly=on \
    -netdev user,id=net0,hostfwd=tcp:127.0.0.1:"$SSH_PORT"-:22 \
    -device virtio-net-pci,netdev=net0 \
    -fsdev local,id=repo,path="$REPO",security_model=none \
    -device virtio-9p-pci,fsdev=repo,mount_tag="$MOUNT_TAG" \
    -audiodev none,id=snd0 \
    -device qemu-xhci,id=xhci \
    -device usb-audio,audiodev=snd0,bus=xhci.0 \
    -display none -serial file:"$SERIAL" \
    -monitor unix:"$MONITOR",server,nowait \
    -pidfile "$PIDFILE" -daemonize
  wait_ssh
}

wait_ssh() {
  log "waiting for SSH (cloud-init first boot can take ~30-60s)..."
  local i
  for i in $(seq 1 120); do
    if ssh "${SSHOPTS[@]}" "$SSH_HOST" true 2>/dev/null; then
      log "SSH is up"; return 0
    fi
    sleep 2
  done
  die "SSH did not come up; see serial log: $SERIAL"
}

cmd_ssh() {
  if [ $# -eq 0 ]; then ssh "${SSHOPTS[@]}" "$SSH_HOST"; else ssh "${SSHOPTS[@]}" "$SSH_HOST" "$@"; fi
}

cmd_provision() {
  vm_running || die "VM not running (run 'up' first)"
  log "mounting repo share in guest at $GUEST_REPO"
  cmd_ssh "sudo mkdir -p $GUEST_REPO && sudo mount -t 9p -o trans=virtio,version=9p2000.L,msize=262144 $MOUNT_TAG $GUEST_REPO || true"
  log "installing kernel headers, modules-extra and build tools (guest kernel: \$(uname -r))"
  cmd_ssh 'sudo DEBIAN_FRONTEND=noninteractive apt-get update -y && \
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      build-essential curl kmod usbutils \
      "linux-headers-$(uname -r)" "linux-modules-extra-$(uname -r)"'
  log "provision complete"
}

ensure_mount() {
  cmd_ssh "sudo mountpoint -q $GUEST_REPO || sudo mount -t 9p -o trans=virtio,version=9p2000.L,msize=262144 $MOUNT_TAG $GUEST_REPO"
}

# Sync the harness subtree from the 9p share to guest-local storage. We build and
# run guest-local (not in the 9p share) so kbuild is fast and host build products
# for a different kernel can't contaminate the guest build. `distclean` drops any
# copied-in .ko/binaries/fetched sources so everything rebuilds for the guest.
cmd_sync() {
  vm_running || die "VM not running (run 'up' first)"
  ensure_mount
  cmd_ssh "rm -rf $GUEST_HARNESS && cp -a $GUEST_REPO/harness $GUEST_HARNESS && make -C $GUEST_HARNESS distclean >/dev/null 2>&1 || true"
  log "synced harness -> guest $GUEST_HARNESS"
}

cmd_run() {
  vm_running || die "VM not running (run 'up' first)"
  local stage="${1:-all}"
  cmd_sync
  # Artifacts are written back to the host through the 9p share.
  cmd_ssh "sudo mkdir -p $GUEST_ARTIFACTS"
  case "$stage" in
    all) cmd_ssh "cd $GUEST_HARNESS && sudo ARTIFACTS_DIR=$GUEST_ARTIFACTS ./run-all.sh" ;;
    *)   cmd_ssh "cd $GUEST_HARNESS && sudo ARTIFACTS_DIR=$GUEST_ARTIFACTS make $stage" ;;
  esac
}

cmd_provision_elixir() {
  vm_running || die "VM not running (run 'up' first)"
  ensure_mount
  cmd_ssh "bash $GUEST_REPO/harness/vm/provision-elixir.sh"
}

cmd_verify() {
  vm_running || die "VM not running (run 'up' first)"
  ensure_mount
  cmd_ssh "sudo bash $GUEST_REPO/harness/vm/verify.sh"
}

cmd_status() {
  if vm_running; then log "VM running (pid $(cat "$PIDFILE"))"; else log "VM not running"; fi
  ssh "${SSHOPTS[@]}" "$SSH_HOST" 'echo guest: $(uname -r); uptime' 2>/dev/null || log "SSH not reachable"
}

cmd_down() {
  vm_running || { log "VM not running"; return 0; }
  log "powering off"
  ssh "${SSHOPTS[@]}" "$SSH_HOST" 'sudo poweroff' 2>/dev/null || true
  local i; for i in $(seq 1 30); do vm_running || { log "VM down"; rm -f "$PIDFILE"; return 0; }; sleep 1; done
  log "forcing off"; kill "$(cat "$PIDFILE")" 2>/dev/null || true; rm -f "$PIDFILE"
}

cmd_destroy() { cmd_down; rm -f "$OVERLAY"; log "removed overlay $OVERLAY"; }

case "${1:-}" in
  up)              shift; cmd_up "$@" ;;
  provision)       shift; cmd_provision "$@" ;;
  provision-elixir) shift; cmd_provision_elixir "$@" ;;
  verify)          shift; cmd_verify "$@" ;;
  sync)            shift; cmd_sync "$@" ;;
  ssh)             shift; cmd_ssh "$@" ;;
  run)             shift; cmd_run "$@" ;;
  status)          shift; cmd_status "$@" ;;
  down)            shift; cmd_down "$@" ;;
  destroy)         shift; cmd_destroy "$@" ;;
  *) echo "usage: $0 {up|provision|provision-elixir|verify|sync|ssh [cmd]|run [stage]|status|down|destroy}" >&2; exit 2 ;;
esac
