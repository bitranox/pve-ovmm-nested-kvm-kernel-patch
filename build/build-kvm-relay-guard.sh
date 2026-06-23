#!/bin/bash
#
# build-kvm-relay-guard.sh
#
# Build + install the nested-Hyper-V hypercall relay AND the timer-storm guard
# into the running Proxmox VE kernel's kvm.ko / kvm-intel.ko. This repo is the
# single source: it makes a fresh worktree of the matching PVE kernel branch,
# then runs kvm_patch_apply_hcall_relay.sh with GUARD=1 (relay anchored edits +
# the timer-guard patch + build + install).
#
# Run ON the target PVE host. The kernel source MUST match `uname -r` EXACTLY: a
# version-mismatched build loads (modversions tolerates it) but the kvm struct
# layouts differ, so nested guests SIGSEGV at ~0.1 s. The per-release PVE source
# is the git repo PVE_KERNEL_REPO, one branch per release (7.0.2-7, ...).
#
# Env:
#   PVE_KERNEL_REPO  PVE kernel git repo (default /usr/src/pve-x86-v7-build/repo)
#   KVM_RELAY_SRC    build worktree path (default /usr/src/kvm-guard)
#
# After it finishes, activate (with 0 running VMs, Tasmota ready):
#   rmmod kvm_intel kvm && modprobe kvm_intel
#   cat /sys/module/kvm/srcversion   # must change to the new build
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="${PVE_KERNEL_REPO:-/usr/src/pve-x86-v7-build/repo}"
SRC="${KVM_RELAY_SRC:-/usr/src/kvm-guard}"
BR="$(uname -r | sed 's/-pve$//')"

[ "$(id -u)" = 0 ] || { echo "error: run as root" >&2; exit 1; }
[ -d "$REPO/.git" ] || { echo "error: PVE kernel git repo not found: $REPO" >&2; exit 1; }

echo "== fresh worktree of branch ${BR} =="
rm -rf "$SRC"
git -C "$REPO" worktree prune
git -C "$REPO" worktree add --detach "$SRC" "$BR"

echo "== apply relay + guard, build + install =="
KVM_RELAY_SRC="$SRC" GUARD=1 bash "$HERE/kvm_patch_apply_hcall_relay.sh"

echo "== build artefacts =="
echo "  vermagic=$(modinfo -F vermagic "$SRC/arch/x86/kvm/kvm.ko" 2>/dev/null)"
echo "  srcversion=$(modinfo -F srcversion "$SRC/arch/x86/kvm/kvm.ko" 2>/dev/null)"
echo "  cap=$(grep -c '0x4f564d52' "$SRC/include/uapi/linux/kvm.h" 2>/dev/null) (relay) ; guard params=$(modinfo -p "$SRC/arch/x86/kvm/kvm.ko" 2>/dev/null | grep -c hv_stimer)"
echo "== installed for $(uname -r). Activate (0 VMs): rmmod kvm_intel kvm && modprobe kvm_intel =="
