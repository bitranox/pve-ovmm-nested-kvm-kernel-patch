# Nested Hyper-V vmbus relay for KVM (Proxmox VE kernel variant)

A small KVM change that lets a Windows guest which itself turns on Hyper-V / VBS
boot and run under OpenVMM on the KVM backend. Such a guest runs its own kernel
as the root partition of the nested hypervisor (`hvix64`), i.e. as an L2 guest:

```
guest kernel  ->  hvix64 (L1)  ->  KVM (L0)
```

The root's own vmbus never connects, because its `HvPostMessage(InitiateContact)`
is an L2 `VMCALL` that exits to L0 and gets reflected up to `hvix64`, which has no
path to forward it down to the userspace VMM. The guest bugchecks `0x7B
INACCESSIBLE_BOOT_DEVICE` early in boot.

This patch adds an opt-in per-VM capability, `KVM_CAP_NESTED_VMBUS_RELAY`, that
keeps the nested root's synic posts (`HvPostMessage` / `HvSignalEvent`) in L0
instead of reflecting them to `hvix64`, so the userspace VMM's own vmbus server
answers them. No guest patch, no `hvix64` patch.

## Two variants

This repository is the **Proxmox VE kernel** variant. The Proxmox kernel is not
hosted on GitHub (it is an Ubuntu base plus Proxmox patches), so it cannot be a
GitHub fork; the change is provided here as a patch plus a build script.

The **stock mainline** variant is a real kernel fork with the same change applied
as a single commit, on top of the `kvm-x86/linux` development tree:

  https://github.com/bitranox/linux-nested-vmbus-relay (branch `nested-vmbus-relay`)

## What the patch does

* `KVM_CAP_NESTED_VMBUS_RELAY` (`include/uapi/linux/kvm.h`, `arch/x86/kvm/x86.c`):
  an opt-in per-VM capability the VMM enables on its kvm fd.
* `arch/x86/kvm/vmx/nested.c`: in `nested_vmx_reflect_vmexit()`, an L2 `VMCALL`
  carrying `HvPostMessage` (call code `0x5c`) or `HvSignalEvent` (`0x5d`) with the
  Hyper-V nested bit set is kept in L0 instead of reflected to L1. It is gated on
  `nested_evmcs_l2_tlb_flush_enabled()`, the same enlightened-VMCS authorization
  KVM already trusts for the L2 TLB-flush hypercall, so an L2 the L1 did not
  authorize (a grandchild guest of the root) is never relayed.
* `arch/x86/kvm/hyperv.c`: the relayed post's input GPA is translated L2 to L1
  (same as the L2 TLB-flush slow path), which also rejects pages removed from the
  L2 root's GPA space.

The capability number (`0x4f564d52`) is an out-of-tree private sentinel, not an
upstream UAPI assignment.

## Building for a Proxmox VE kernel

`build/kvm_patch_apply_cap.sh` applies the change to a matching Proxmox kernel
source tree (anchored text edits, so it survives point-release drift) and rebuilds
only the KVM modules (`kvm.ko`, `kvm-intel.ko`). It does not touch anything else.
Read the script header for how to obtain the matching source, and
`docs/kernel-source-pins.md` for the exact pve-kernel and Ubuntu-base commits per
kernel version plus the fetch/prepare recipe. Load with
`rmmod kvm_intel kvm && modprobe kvm_intel` (VMs stopped) or a reboot.

`patch/kvm-nested-vmbus-relay-pve.patch` is the same change as a plain unified
diff against a Proxmox 7.0.x kernel source tree, for `git apply` / `patch -p1`.

## Design

`docs/design.md` is the full write-up: the layering, why L0 is the correct
destination, every flag and KVM function involved, the Windows kernel symbols,
and the correctness items (per-L2 authorization, GPA translation, translation
lifetime).
