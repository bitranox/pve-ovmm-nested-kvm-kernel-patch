#!/bin/bash
#
# kvm_patch_apply_linux.sh
#
# Mainline-kernel counterpart to kvm_patch_apply_hcall_relay.sh. That script
# applies the relay to a Proxmox VE kernel by anchored text insertions (so it
# survives PVE point-release drift); this one applies the git-format patch files
# in patch/linux/ to a mainline / kvm-x86 kernel source tree, where they apply
# cleanly, and then builds the KVM modules.
#
# Applies:
#   patch/linux/kvm-nested-vmbus-relay-linux.patch   (rename + relay; cap 0x4f564d52)
#   patch/linux/kernel-timer-guard-linux.patch       (only with GUARD=1)
#
# It uses `patch -p1` (not `git am`), so the target need not be a git tree and no
# commits are created; the tree is just modified in place, then built. If you
# prefer commits on a git tree, `git am patch/linux/*.patch` does the same.
#
# Env vars (same as the PVE applier):
#   KVM_RELAY_SRC=<dir>   kernel source tree (searched for arch/x86/kvm/vmx/nested.c)
#   GUARD=1               also apply the timer-storm guard (default off)
#   INSTALL=0             build only, do not install (default installs)
#   KVM_RELAY_WORK=<dir>  fallback search root (default /usr/src/kvm-nested-relay)
#
# Rebuilds kvm.ko + kvm-intel.ko. No Windows guest patch. openvmm enables the cap
# per-VM (args[0] = POST_MESSAGE | SIGNAL_EVENT) when nested virt is on; the cap
# value (0x4f564d52) must match the openvmm side (vm/kvm/src/lib.rs).
set -euo pipefail

KREL="$(uname -r)"
WORK="${KVM_RELAY_WORK:-/usr/src/kvm-nested-relay}"
GUARD="${GUARD:-0}"
INSTALL="${INSTALL:-1}"
JOBS="$(nproc)"
HERE="$(cd "$(dirname "$0")" && pwd)"
PATCHDIR="$HERE/../patch/linux"

[ "$(id -u)" = 0 ] || { echo "error: run as root" >&2; exit 1; }
[ -f "/boot/config-${KREL}" ] || { echo "error: /boot/config-${KREL} missing" >&2; exit 1; }
command -v make >/dev/null || { echo "error: install build-essential bc flex bison libelf-dev libssl-dev dwarves" >&2; exit 1; }
command -v patch >/dev/null || { echo "error: install patch" >&2; exit 1; }

echo "== running kernel: ${KREL} =="
find_src() { find "${1:-$WORK}" -maxdepth 7 -path '*/arch/x86/kvm/vmx/nested.c' -printf '%h\n' 2>/dev/null \
             | sed 's,/arch/x86/kvm/vmx,,' | head -1 || true; }
SRC=""
[ -n "${KVM_RELAY_SRC:-}" ] && SRC="$(find_src "$KVM_RELAY_SRC")"
[ -z "$SRC" ] && SRC="$(find_src "$WORK")"
[ -n "$SRC" ] && [ -d "$SRC" ] || { echo "error: kernel source tree not found; set KVM_RELAY_SRC" >&2; exit 1; }
echo "== source tree: ${SRC} =="

# Apply one patch file, idempotent under set -e: apply if it applies cleanly,
# skip if already applied (reverse applies), error only on real source drift.
apply_patch() {
    local p="$1"
    [ -f "$p" ] || { echo "error: patch not found: $p" >&2; exit 1; }
    if patch -p1 -d "$SRC" -N --dry-run < "$p" >/dev/null 2>&1; then
        patch -p1 -d "$SRC" -N < "$p"
        echo "  applied: $(basename "$p")"
    elif patch -R -p1 -d "$SRC" --dry-run < "$p" >/dev/null 2>&1; then
        echo "  already applied, skipping: $(basename "$p")"
    else
        echo "error: $(basename "$p") does not apply (kernel source drift?)" >&2
        exit 1
    fi
}

echo "== applying relay =="
apply_patch "$PATCHDIR/kvm-nested-vmbus-relay-linux.patch"
if [ "$GUARD" = 1 ]; then
    echo "== applying timer-storm guard =="
    apply_patch "$PATCHDIR/kernel-timer-guard-linux.patch"
fi

# --- configure to the running kernel and build the KVM modules -------------- #
cd "$SRC"
cp -f "/boot/config-${KREL}" .config
[ -f "/usr/src/linux-headers-${KREL}/Module.symvers" ] && cp -f "/usr/src/linux-headers-${KREL}/Module.symvers" Module.symvers || true
make olddefconfig
make modules_prepare
echo "== building kvm + kvm-intel =="
make -j"$JOBS" M=arch/x86/kvm

if [ "$INSTALL" = 1 ]; then
    DEST="/lib/modules/${KREL}/kernel/arch/x86/kvm"
    mkdir -p "$DEST"
    for ko in kvm.ko kvm-intel.ko; do
        [ -f "arch/x86/kvm/${ko}" ] && cp -v "arch/x86/kvm/${ko}" "${DEST}/${ko}"
    done
    depmod -a
    echo "== installed kvm + kvm-intel for ${KREL}. rmmod kvm_intel kvm && modprobe kvm_intel to activate. =="
fi
