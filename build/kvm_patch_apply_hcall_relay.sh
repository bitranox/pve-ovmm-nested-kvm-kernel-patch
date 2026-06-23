#!/bin/bash
#
# kvm_patch_apply_hcall_relay.sh
#
# Per-VM nested-Hyper-V hypercall relay, aligned to the upstream RFC
# (KVM_CAP_NESTED_HYPERV_HCALL_RELAY). This is the production form for the
# proxmox kernel: the same relay logic as the RFC, applied by anchored text
# insertion so it survives point-release drift. openvmm enables the cap per-VM
# (Partition::enable_nested_hyperv_hcall_relay, args[0] = POST_MESSAGE |
# SIGNAL_EVENT) when nested virt is on.
#
# Six edits + one rename, matching the RFC patches:
#   rename nested_evmcs_l2_tlb_flush_enabled -> nested_evmcs_l2_direct_hypercall_enabled
#   include/uapi/linux/kvm.h          + KVM_CAP_NESTED_HYPERV_HCALL_RELAY 0x4f564d52
#   arch/x86/include/uapi/asm/kvm.h   + the args[0] relay bits
#   arch/x86/include/asm/kvm_host.h   + u64 nested_hv_relay_mask in struct kvm_arch
#   arch/x86/kvm/x86.c                + KVM_ENABLE_CAP case validates+stores the mask
#   arch/x86/kvm/vmx/nested.c         + the relay branch (named constants) + the
#                                       hvgdk_mini include for them
#   arch/x86/kvm/hyperv.c             + translate the relayed L2 synic post GPA
#
# Rebuilds kvm.ko + kvm-intel.ko. No Windows guest patch.
#
# Optional timer-storm guard (GUARD=1, default off): on a host without VMX TSC
# scaling the relay gets a nested Hyper-V guest booting, but the L1 root's
# past-dated direct-mode one-shot synthetic timer can re-arm in a storm and hang
# the guest. GUARD=1 applies patch/pve/kernel-timer-guard-pve.patch after the relay
# edits, bounding the re-arm with an adaptive forward dwell. The guard is gated on
# !kvm_caps.has_tsc_control, so it is inert and costs nothing on a TSC-scaling
# (modern) CPU. See docs/timer-guard.md.
set -euo pipefail

KREL="$(uname -r)"
WORK="${KVM_RELAY_WORK:-/usr/src/kvm-nested-relay}"
GUARD="${GUARD:-0}"
JOBS="$(nproc)"

[ "$(id -u)" = 0 ] || { echo "error: run as root" >&2; exit 1; }
[ -f "/boot/config-${KREL}" ] || { echo "error: /boot/config-${KREL} missing" >&2; exit 1; }
command -v make >/dev/null || { echo "error: install build-essential bc flex bison libelf-dev libssl-dev dwarves" >&2; exit 1; }

echo "== running kernel: ${KREL} =="
find_src() { find "${1:-$WORK}" -maxdepth 7 -path '*/arch/x86/kvm/vmx/nested.c' -printf '%h\n' 2>/dev/null \
             | sed 's,/arch/x86/kvm/vmx,,' | head -1 || true; }
SRC=""
[ -n "${KVM_RELAY_SRC:-}" ] && SRC="$(find_src "$KVM_RELAY_SRC")"
[ -z "$SRC" ] && SRC="$(find_src "$WORK")"
[ -n "$SRC" ] && [ -d "$SRC" ] || { echo "error: kernel source tree not found; set KVM_RELAY_SRC" >&2; exit 1; }
echo "== source tree: ${SRC} =="

# --- rename the eVMCS L2 nested-hypercall gate to its upstream name ---------- #
for f in arch/x86/kvm/vmx/hyperv.c arch/x86/kvm/vmx/hyperv.h arch/x86/kvm/vmx/nested.c; do
    sed -i 's/nested_evmcs_l2_tlb_flush_enabled/nested_evmcs_l2_direct_hypercall_enabled/g' "$SRC/$f"
done
echo "  renamed gate -> nested_evmcs_l2_direct_hypercall_enabled"

# --- anchored, idempotent edits --------------------------------------------- #
python3 - "$SRC" <<'PY'
import sys, io, re, os
src = sys.argv[1]
def edit(path, fn):
    p = os.path.join(src, path)
    with io.open(p, encoding="utf-8") as f: t = f.read()
    nt = fn(t)
    if nt is None:
        print("  unchanged (already applied): %s" % path); return
    with io.open(p, "w", encoding="utf-8") as f: f.write(nt)
    print("  edited: %s" % path)

def cap_def(t):
    if "KVM_CAP_NESTED_HYPERV_HCALL_RELAY" in t: return None
    anchor = "\n\nstruct kvm_irq_routing_irqchip {"
    if anchor not in t: raise SystemExit("kvm.h: kvm_irq_routing_irqchip anchor not found")
    # 0x4f564d52 ("OVMR"): a high private sentinel WELL above upstream's sequential
    # KVM_CAP_* range, so this out-of-tree cap never collides with a future upstream
    # cap (a low number like 249 clashes the moment upstream assigns it). The openvmm
    # side (vm/kvm/src/lib.rs) MUST use the identical value. The upstream RFC keeps a
    # low placeholder; the maintainers assign the real number at merge.
    return t.replace(anchor, "\n#define KVM_CAP_NESTED_HYPERV_HCALL_RELAY 0x4f564d52" + anchor, 1)

def bits_def(t):
    if "KVM_NESTED_HYPERV_RELAY_POST_MESSAGE" in t: return None
    m = re.search(r'^#define KVM_EXIT_HYPERCALL_LONG_MODE.*$', t, re.M)
    if not m: raise SystemExit("asm/kvm.h: KVM_EXIT_HYPERCALL_LONG_MODE anchor not found")
    ins = ("\n\n/* Relayable nested Hyper-V hypercalls for KVM_CAP_NESTED_HYPERV_HCALL_RELAY. */\n"
           "#define KVM_NESTED_HYPERV_RELAY_POST_MESSAGE\t_BITULL(0)\n"
           "#define KVM_NESTED_HYPERV_RELAY_SIGNAL_EVENT\t_BITULL(1)")
    return t[:m.end()] + ins + t[m.end():]

def kvm_host_h(t):
    if "nested_hv_relay_mask" in t: return None
    m = re.search(r'^struct kvm_arch \{\n', t, re.M)
    if not m: raise SystemExit("kvm_host.h: struct kvm_arch anchor not found")
    ins = ("\t/* Relayable nested Hyper-V hypercalls "
           "(KVM_CAP_NESTED_HYPERV_HCALL_RELAY args[0] bitmask). */\n"
           "\tu64 nested_hv_relay_mask;\n")
    return t[:m.end()] + ins + t[m.end():]

def x86_c(t):
    if "nested_hv_relay_mask" in t: return None
    f = t.find("kvm_vm_ioctl_enable_cap(struct kvm *kvm")
    if f < 0: raise SystemExit("x86.c: kvm_vm_ioctl_enable_cap not found")
    s = t.find("switch (cap->cap) {", f)
    if s < 0: raise SystemExit("x86.c: switch in enable_cap not found")
    nl = t.find("\n", s) + 1
    case = ("\tcase KVM_CAP_NESTED_HYPERV_HCALL_RELAY:\n"
            "\t\tr = -EINVAL;\n"
            "\t\tif (cap->args[0] & ~(KVM_NESTED_HYPERV_RELAY_POST_MESSAGE |\n"
            "\t\t\t\t     KVM_NESTED_HYPERV_RELAY_SIGNAL_EVENT))\n"
            "\t\t\tbreak;\n"
            "\t\tkvm->arch.nested_hv_relay_mask = cap->args[0];\n"
            "\t\tr = 0;\n"
            "\t\tbreak;\n")
    return t[:nl] + case + t[nl:]

def nested_c_include(t):
    if "hvgdk_mini.h" in t: return None
    anchor = '#include "hyperv.h"'
    if anchor not in t: raise SystemExit("nested.c: hyperv.h include anchor not found")
    return t.replace(anchor, anchor + "\n#include <hyperv/hvgdk_mini.h>", 1)

def nested_c_relay_param(t):
    if "nested_hv_relay_enabled" in t: return None
    anchor = '#include <hyperv/hvgdk_mini.h>'
    if anchor not in t: raise SystemExit("nested.c: hvgdk_mini include anchor not found")
    # Master on/off for the relay (debug/test, default on). Lives in nested.c so it
    # registers under kvm_intel (the relay decision below is VMX-specific); set it to
    # 0 to make every VM reflect the L2 root's posts to L1 (stock behaviour), e.g. to
    # A/B the relay without building a relay-less kernel. The hyperv.c GPA-translation
    # path is downstream of this gate, so disabling it here is sufficient.
    ins = ("\n\n/* Master switch for the nested Hyper-V hypercall relay (default on). */\n"
           "static bool nested_hv_relay_enabled = true;\n"
           "module_param(nested_hv_relay_enabled, bool, 0644);\n"
           "MODULE_PARM_DESC(nested_hv_relay_enabled,\n"
           '\t"Relay nested Hyper-V root posts to L0 (default on; 0 = reflect to L1)");')
    return t.replace(anchor, anchor + ins, 1)

def nested_c(t):
    if "nested_hv_relay_mask" in t: return None
    anchor = "trace_kvm_nested_vmexit(vcpu, KVM_ISA_VMX);"
    i = t.find(anchor)
    if i < 0: raise SystemExit("nested.c: trace_kvm_nested_vmexit anchor not found")
    nl = t.find("\n", i) + 1
    blk = (
"\n"
"\t/*\n"
"\t * Relay a nested Hyper-V root partition's enlightened synic posts to L0\n"
"\t * rather than reflecting them to L1.  A Windows guest that enables\n"
"\t * Hyper-V/VBS runs its kernel as the root partition of a nested\n"
"\t * hypervisor (an L2 guest), whose HvPostMessage/HvSignalEvent VMCALLs\n"
"\t * would otherwise be reflected to L1, which has no path to forward them\n"
"\t * to the userspace VMM.  When userspace selected the call class via\n"
"\t * KVM_CAP_NESTED_HYPERV_HCALL_RELAY and L1 authorized this L2 for direct\n"
"\t * nested hypercalls (the same eVMCS gate honored for the L2 TLB-flush\n"
"\t * hypercall), handle the post in L0: clear the nested bit so the standard\n"
"\t * hypercall path accepts the call, and return false to keep the exit in\n"
"\t * L0.  An L2 that L1 did not authorize (a grandchild of the root) is\n"
"\t * never relayed and keeps its own L1 synic.\n"
"\t */\n"
"\tif (nested_hv_relay_enabled && vcpu->kvm->arch.nested_hv_relay_mask &&\n"
"\t    exit_reason.basic == EXIT_REASON_VMCALL &&\n"
"\t    nested_evmcs_l2_direct_hypercall_enabled(vcpu)) {\n"
"\t\tu64 mask = vcpu->kvm->arch.nested_hv_relay_mask;\n"
"\t\tu64 input = kvm_rcx_read(vcpu);\n"
"\t\tu16 code = input & 0xffff;\n"
"\t\tbool relay = false;\n"
"\n"
"\t\tif (input & HV_HYPERCALL_NESTED) {\n"
"\t\t\tif (code == HVCALL_POST_MESSAGE)\n"
"\t\t\t\trelay = mask & KVM_NESTED_HYPERV_RELAY_POST_MESSAGE;\n"
"\t\t\telse if (code == HVCALL_SIGNAL_EVENT)\n"
"\t\t\t\trelay = mask & KVM_NESTED_HYPERV_RELAY_SIGNAL_EVENT;\n"
"\t\t}\n"
"\n"
"\t\tif (relay) {\n"
"\t\t\tkvm_rcx_write(vcpu, input & ~HV_HYPERCALL_NESTED);\n"
"\t\t\treturn false;\n"
"\t\t}\n"
"\t}\n")
    return t[:nl] + blk + t[nl:]

def hyperv_c(t):
    if "nested-Hyper-V root's HvPostMessage" in t: return None
    anchor = ("\t\tkvm_hv_hypercall_read_xmm(&hc);\n"
              "\t}\n"
              "\n"
              "\tswitch (hc.code) {\n")
    if anchor not in t:
        raise SystemExit("hyperv.c: kvm_hv_hypercall switch anchor not found")
    blk = (
"\t\tkvm_hv_hypercall_read_xmm(&hc);\n"
"\t}\n"
"\n"
"\t/*\n"
"\t * A relayed nested-Hyper-V root's HvPostMessage / HvSignalEvent (see\n"
"\t * nested_vmx_reflect_vmexit()) runs on nested EPT and carries an L2 GPA\n"
"\t * in ingpa.  Translate it to an L1 GPA, mirroring the L2 TLB-flush slow\n"
"\t * path and gating on mmu_is_nested(): translate_nested_gpa() requires an\n"
"\t * active nested MMU, and with shadow paging the L2 GPA is already an L1\n"
"\t * GPA.  The walk rejects pages removed from the L2 root's GPA space.\n"
"\t */\n"
"\tif (vcpu->kvm->arch.nested_hv_relay_mask && !hc.fast && mmu_is_nested(vcpu) &&\n"
"\t    (hc.code == HVCALL_POST_MESSAGE || hc.code == HVCALL_SIGNAL_EVENT)) {\n"
"\t\thc.ingpa = kvm_x86_ops.nested_ops->translate_nested_gpa(\n"
"\t\t\t\tvcpu, hc.ingpa, PFERR_GUEST_FINAL_MASK, NULL, 0);\n"
"\t\tif (unlikely(hc.ingpa == INVALID_GPA)) {\n"
"\t\t\tret = HV_STATUS_INVALID_HYPERCALL_INPUT;\n"
"\t\t\tgoto hypercall_complete;\n"
"\t\t}\n"
"\t}\n"
"\n"
"\tswitch (hc.code) {\n")
    return t.replace(anchor, blk, 1)

edit("include/uapi/linux/kvm.h", cap_def)
edit("arch/x86/include/uapi/asm/kvm.h", bits_def)
edit("arch/x86/include/asm/kvm_host.h", kvm_host_h)
edit("arch/x86/kvm/x86.c", x86_c)
edit("arch/x86/kvm/vmx/nested.c", nested_c_include)
edit("arch/x86/kvm/vmx/nested.c", nested_c_relay_param)
edit("arch/x86/kvm/vmx/nested.c", nested_c)
edit("arch/x86/kvm/hyperv.c", hyperv_c)
print("edits done")
PY

# --- optional timer-storm guard (GUARD=1) ----------------------------------- #
if [ "$GUARD" = 1 ]; then
    GUARD_PATCH="$(dirname "$0")/../patch/pve/kernel-timer-guard-pve.patch"
    [ -f "$GUARD_PATCH" ] || { echo "error: guard patch not found: $GUARD_PATCH" >&2; exit 1; }
    # Idempotent under set -e: apply if it applies cleanly, skip if already
    # applied (reverse applies), error only on real source drift.
    if patch -p1 -d "$SRC" -N --dry-run < "$GUARD_PATCH" >/dev/null 2>&1; then
        patch -p1 -d "$SRC" -N < "$GUARD_PATCH"
        echo "  applied timer-storm guard"
    elif patch -R -p1 -d "$SRC" --dry-run < "$GUARD_PATCH" >/dev/null 2>&1; then
        echo "  timer-storm guard already applied; skipping"
    else
        echo "error: timer-storm guard does not apply (kernel source drift?)" >&2; exit 1
    fi
fi

# --- configure to the running kernel and build the KVM modules -------------- #
cd "$SRC"
cp -f "/boot/config-${KREL}" .config
[ -f "/usr/src/linux-headers-${KREL}/Module.symvers" ] && cp -f "/usr/src/linux-headers-${KREL}/Module.symvers" Module.symvers || true
make olddefconfig
make modules_prepare
echo "== building kvm + kvm-intel =="
make -j"$JOBS" M=arch/x86/kvm

if [ "${INSTALL:-1}" = 1 ]; then
    DEST="/lib/modules/${KREL}/kernel/arch/x86/kvm"
    mkdir -p "$DEST"
    for ko in kvm.ko kvm-intel.ko; do
        [ -f "arch/x86/kvm/${ko}" ] && cp -v "arch/x86/kvm/${ko}" "${DEST}/${ko}"
    done
    depmod -a
    echo "== installed kvm + kvm-intel (hcall relay) for ${KREL}. rmmod kvm_intel kvm && modprobe kvm_intel to activate. =="
fi
