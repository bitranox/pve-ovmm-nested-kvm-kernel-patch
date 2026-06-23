# Nested Hyper-V hypercall relay for KVM (Proxmox VE kernel variant)

A small KVM change that lets a Windows guest with Hyper-V/VBS enabled boot and
run under OpenVMM on the KVM backend, without any guest patch.

Such a guest runs its own kernel as the root partition of the nested hypervisor
(`hvix64`), i.e. as an L2 guest:

```
guest kernel  ->  hvix64 (L1)  ->  KVM (L0)
```

The root's vmbus never connects without this change. Its
`HvPostMessage(InitiateContact)` is an L2 `VMCALL` that exits to L0 and is
reflected up to `hvix64`, which has no path to forward it to the userspace VMM.
The guest bugchecks `0x7B INACCESSIBLE_BOOT_DEVICE` early in boot.

## The fix: KVM_CAP_NESTED_HYPERV_HCALL_RELAY (cap 0x4f564d52)

The patch adds a per-VM capability, `KVM_CAP_NESTED_HYPERV_HCALL_RELAY`, with
value `0x4f564d52` (a high private sentinel above upstream's cap range, so this
out-of-tree cap never collides with a future upstream assignment; OpenVMM enables
the identical value). The mainline RFC carries a low placeholder (249) that the
upstream maintainers replace at merge. Its `args[0]` is a bitmask of hypercall
classes to keep in L0. The userspace VMM enables it with
`args[0] = KVM_NESTED_HYPERV_RELAY_POST_MESSAGE | KVM_NESTED_HYPERV_RELAY_SIGNAL_EVENT`.

What changes in the kernel:

- `KVM_CAP_NESTED_HYPERV_HCALL_RELAY` cap + bitmask bits
  (`include/uapi/linux/kvm.h`, `arch/x86/include/uapi/asm/kvm.h`): the UAPI.
- `u64 nested_hv_relay_mask` in `struct kvm_arch`
  (`arch/x86/include/asm/kvm_host.h`): the per-VM relay state.
- `kvm_vm_ioctl_enable_cap` (`arch/x86/kvm/x86.c`): validates the bitmask and
  stores it.
- `nested_vmx_reflect_vmexit` (`arch/x86/kvm/vmx/nested.c`): when the VM has a
  relay mask set, an L2 `VMCALL` with the Hyper-V nested bit set
  (`HV_HYPERCALL_NESTED`) and a relayable call code (`HVCALL_POST_MESSAGE` /
  `HVCALL_SIGNAL_EVENT`) is kept in L0 instead of reflected to L1. Gated on
  `nested_evmcs_l2_direct_hypercall_enabled()`, the same eVMCS authorization
  KVM already trusts for the L2 TLB-flush hypercall, so a grandchild L2 that L1
  did not authorize is never relayed.
- `kvm_hv_hypercall` (`arch/x86/kvm/hyperv.c`): for a relayed call running
  under nested EPT, translates the L2 GPA in the input parameter to an L1 GPA
  via the nested MMU (same as the L2 TLB-flush slow path) and rejects pages
  removed from the L2 root's GPA space with
  `HV_STATUS_INVALID_HYPERCALL_INPUT`.

Patch 1 also renames `nested_evmcs_l2_tlb_flush_enabled()` to
`nested_evmcs_l2_direct_hypercall_enabled()`, since the predicate covers more
than TLB flush and a second caller now uses it. This is a pure rename with no
functional change.

Both `kvm.ko` and `kvm-intel.ko` are rebuilt; the relay touches both modules
(cap handling in `kvm.ko`, the reflect-vmexit branch in `kvm-intel.ko`). The
upstream RFC is two patches, corresponding to the rename and the relay
respectively.

## Two variants

This repository is the **Proxmox VE kernel** variant. The Proxmox kernel is not
hosted on GitHub, so the change is provided here as a build script (anchored
text insertions) rather than as a fork.

The **mainline** variant is an RFC posted to the KVM list; the corresponding
patch-repo fork against `kvm-x86/linux` is at:

  https://github.com/bitranox/linux-nested-vmbus-relay (branch `nested-vmbus-relay`)

## Building for a Proxmox VE kernel

`build/kvm_patch_apply_hcall_relay.sh` applies the change to a matching
Proxmox kernel source tree and rebuilds only the KVM modules (`kvm.ko`,
`kvm-intel.ko`). The edits are anchored text insertions, so they survive minor
source drift across point releases. The script header explains the environment
variables; `docs/kernel-source-pins.md` lists the exact pve-kernel and
Ubuntu-base git commits per kernel version, plus the fetch-and-prepare recipe.

Key steps:

```bash
# Obtain the matching source (see docs/kernel-source-pins.md).
# Then:
KVM_RELAY_SRC=/path/to/linux-source \
    ./build/kvm_patch_apply_hcall_relay.sh

# On a host without VMX TSC scaling, also apply the timer-storm guard:
GUARD=1 KVM_RELAY_SRC=/path/to/linux-source \
    ./build/kvm_patch_apply_hcall_relay.sh

# Activate (stop all VMs first):
rmmod kvm_intel kvm && modprobe kvm_intel
```

The script builds and installs both modules. Use `INSTALL=0` to build without
installing. After loading, the userspace VMM (OpenVMM) enables the capability
per-VM via `KVM_CAP_NESTED_HYPERV_HCALL_RELAY` with
`args[0] = POST_MESSAGE | SIGNAL_EVENT` when nested virt is selected.

## Timer-storm guard (non-TSC-scaling hosts)

The relay gets a nested Hyper-V guest booting, but on a host without VMX TSC
scaling that is not enough on its own. There the L1 root partition's direct-mode
one-shot synthetic timer can re-arm in a storm (the deadline reads as past on the
arming vCPU because the per-vCPU TSC phase is not exact), which pegs a host CPU
and hangs the guest at a no-taskbar desktop. The guard bounds the re-arm in the
kernel's `stimer_start()` with an adaptive forward dwell.

The guard is gated on `!kvm_caps.has_tsc_control`, so it is inert and costs
nothing on a TSC-scaling (modern) CPU. Two sysfs module parameters control it:

- `hv_stimer_guard_enabled` (default on): the master switch.
- `hv_stimer_imm_dwell_max_ns` (default 2000000, i.e. 2 ms): the cap the adaptive
  dwell backs off to. This is the one performance lever. Lower it (around 250 us)
  for an IO-bound nested guest (about +56% in-guest container disk IOPS); raise it
  (around 8 ms) for a CPU-bound one (about +12% CPU); 2 ms is a balanced default.

Build the modules with the guard by setting `GUARD=1`:

```bash
GUARD=1 KVM_RELAY_SRC=/path/to/linux-source ./build/kvm_patch_apply_hcall_relay.sh
```

That applies `patch/kernel-timer-guard-pve.patch` after the relay edits, then
builds both modules. `docs/timer-guard.md` covers the root cause, the adaptive
dwell, the TSC-scaling gate, and the measured IO-versus-CPU trade in full.

## Patch files

`patch/kvm-nested-vmbus-relay-pve.patch` (the relay) and
`patch/kernel-timer-guard-pve.patch` (the timer-storm guard) are the current
PVE-form diffs (cap `0x4f564d52`), provided as point-in-time snapshots. The build
script (`build/kvm_patch_apply_hcall_relay.sh`) remains the source of truth for
what gets applied: it inserts the relay by anchored text edits that track
point-release drift where a static patch would not, and applies the guard patch
when `GUARD=1`. The mainline-form patches (the upstream RFC, cap 249) are at
`github.com/bitranox/linux-nested-vmbus-relay` on branch `nested-vmbus-relay`.

## Design

`docs/design.md` covers the layering, why L0 is the right destination for the
relay, every OpenVMM flag and KVM function involved, the Windows kernel symbols
that are relevant to boot, and the correctness points (per-L2 authorization,
GPA translation, translation lifetime).
