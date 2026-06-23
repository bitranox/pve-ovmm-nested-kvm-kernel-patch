# Nested Hyper-V hypercall relay under OpenVMM on KVM: design, flags, symbols

Status: a stock Windows 11 guest with Hyper-V/VBS enabled boots to the desktop
under OpenVMM on the KVM backend, with storvsc, netvsp and synthvid working, no
Windows guest patch, Secure Boot intact. The fix is entirely L0: OpenVMM
advertises the right capabilities, and KVM relays the L2 root partition's vmbus
hypercalls to L0 via `KVM_CAP_NESTED_HYPERV_HCALL_RELAY`.

## Layering and why L0 is the right destination

The layers:

- **L0** = KVM plus OpenVMM (the userspace VMM). OpenVMM presents a Hyper-V
  platform: synic, the Hv#1 hypercall ABI, a vmbus server on connection id 1.
- **L1** = `hvix64`, the guest's own hypervisor, launched when the guest enables
  Hyper-V/VBS.
- **L2** = the Windows kernel, running as `hvix64`'s root partition.

The root's vmbus control hypercalls, `HvPostMessage` (call code `HVCALL_POST_MESSAGE`,
`0x5c`) and `HvSignalEvent` (`HVCALL_SIGNAL_EVENT`, `0x5d`), are issued as
`VMCALL` instructions with the Hyper-V **nested bit** (`HV_HYPERCALL_NESTED`,
RCX bit 31) set. That bit means "forward this to the parent layer, not the
local one." Because L0 owns the outermost VMCS, the `VMCALL` exits to KVM
first; KVM by default reflects it to L1. L1 (`hvix64`) has no path to forward
it down to the userspace VMM, so the vmbus `InitiateContact` post is dropped,
and the guest bugchecks `0x7B INACCESSIBLE_BOOT_DEVICE`.

On a genuine Hyper-V-on-Hyper-V stack, L1 is the courier: the exit goes to L0,
which reflects it to L1 (Hyper-V), which forwards it to L0's vmbus endpoint.
That L2->L1->L0 route would require `hvix64` to recognize OpenVMM as a
relay-capable Hyper-V parent and engage its nested-vmbus machinery, which it
does not do in our configuration.

L0 is, however, where the post needs to go regardless. OpenVMM holds all the
vmbus device backends: storvsc, netvsp, synthvid. The root's vmbus has nothing
useful at L1; its real server and devices are at L0. The nested bit asks for the
parent, and the parent is OpenVMM. KVM catching the exit and keeping it in L0
delivers it to the destination the guest requested, skipping the L1-forwarding
step that `hvix64` does not perform here.

Empirically the design is correct end to end: the stock guest boots to the
desktop, vmbus channels negotiate, and the reverse direction (OpenVMM writes the
reply into the root's SIMP and signals the SINT) works because the root's synic
pages are L0-visible (KVM sees its SCONTROL/SIMP/SIEFP/SINT MSR writes).

Only the explicitly parent-bound (`HV_HYPERCALL_NESTED`) 0x5c/0x5d calls are
intercepted. Every other hypercall, and every call from a grandchild L2 that L1
did not authorize, still reflects to L1 normally.

## Validation: the nested hypervisor runs real workloads

Booting only proves the root partition's vmbus works. To confirm `hvix64` is
functional as a hypervisor, we ran:

- A bare child VM started with `New-VM`/`Start-VM` reaches `Running` and
  accumulates uptime: `hvix64` allocates the child partition and KVM emulates
  its VMX entry under OpenVMM.
- Hyper-V-isolated Windows containers run (`docker run --isolation=hyperv`),
  each its own utility VM under `hvix64`, with a distinct kernel build number.
- About a dozen Hyper-V-isolated containers (GitHub Actions self-hosted
  runners) run concurrently in production.

The relay's per-L2 authorization gate correctly does not relay grandchild L2s;
they keep their own L1 synic to `hvix64`.

## The KVM capability: KVM_CAP_NESTED_HYPERV_HCALL_RELAY (0x4f564d52)

`KVM_CAP_NESTED_HYPERV_HCALL_RELAY` is a per-VM capability. `args[0]` is a
bitmask selecting which nested Hyper-V hypercall classes to keep in L0:

```
KVM_NESTED_HYPERV_RELAY_POST_MESSAGE   BIT(0)  /* HvPostMessage  */
KVM_NESTED_HYPERV_RELAY_SIGNAL_EVENT   BIT(1)  /* HvSignalEvent  */
```

The userspace VMM (OpenVMM) enables it via `KVM_ENABLE_CAP` on its kvm fd with
`args[0] = 3` when the nested virt path is selected. The bitmask is validated
against the supported bits; unknown bits return `-EINVAL`.

The PVE variant uses `0x4f564d52` ("OVMR"), a high private sentinel above
upstream's cap range, so the out-of-tree cap never collides with a future
upstream assignment; OpenVMM enables the identical value. The mainline RFC
carries a low placeholder (249) that the upstream maintainers replace at merge.

## OpenVMM flags, and why each is needed

All live in the `nested_virt` block of
`vmm_core/virt_kvm/src/arch/x86_64/mod.rs`.

### CPUID 0x40000000-0x40000002

- Vendor `Microsoft Hv`, interface `Hv#1`, a plausible HV version when nesting:
  the guest only loads `vmbus.sys` and runs `hvix64` if these say so. Required.

### CPUID 0x40000003 partition privileges (let hvix64 run)

- `AccessPartitionReferenceTsc` + `AccessReenlightenmentControls`: `hvix64`
  needs the reference-TSC clock and reenlightenment notifications while nested,
  otherwise it resets the partition at a fixed interval during boot.
- `AccessHypercallMsrs`, `AccessVpIndex`, `AccessFrequencyMsrs`,
  `AccessSynicMsrs`, `AccessSyntheticTimerMsrs`, `AccessVpRuntimeMsr`,
  `AccessPartitionReferenceCounter`: the base HV enlightenment surface.
- `AccessApicMsrs`: required for the relay path. With it, `vmbus.sys` uses the
  synic `HvPostMessage(conn 1)` path the relay catches. Without it, `vmbus.sys`
  falls back to the GHCB/SNP tunnel, which needs isolated-partition shared
  memory that `hvix64` cannot back here (boot ends in a `0x7E` memset fault).

### CPUID 0x40000003 partition privileges (let the root post)

- `PostMessages` + `SignalEvents`: the privilege to issue the hypercalls the
  relay intercepts.
- `CreatePort` + `ConnectPort`: vmbus channel setup.
- Not granted: `AccessMemoryPool`, `CreatePartitions`, `StartVirtualProcessor`
  (they push the root onto the isolated-partition path or trip the guest HAL).

### CPUID 0x40000004 enlightenment recommendations

- `use_relaxed_timing`: slackens watchdog deadlines; a nested guest that does
  not get it blows bare-metal timeouts and resets during boot.
- `use_apic_msrs`: pairs with `AccessApicMsrs`.
- `use_hypercall_for_remote_flush_and_local_flush_entire`,
  `use_synthetic_cluster_ipi`, `use_ex_processor_masks`: offload TLB flush and
  cluster IPI to the hypercall path so `hvix64` does not fall back to a storm
  of exits and time out.
- `nested` + `use_vmcs_enlightenments`: direct `hvix64` to use the enlightened
  VMCS page. Without it, roughly 4 million VMREAD and 2 million VMWRITE exits
  accumulate in under a minute; storage times out and the guest fails with
  `INACCESSIBLE_BOOT_DEVICE`.

### KVM-level changes in OpenVMM

- `KVM_CAP_HYPERV_ENLIGHTENED_VMCS` per-vCPU: enables the enlightened VMCS in
  KVM. Without it, `hvix64` retried a failing VM entry roughly 586k times then
  rebooted.
- `nested_state` get/set is made a no-op for the KVM backend: with nesting
  active, `nested_state` is "present" and the backend returned `NotSupported`,
  aborting any guest-initiated reset.
- `KVM_CAP_NESTED_HYPERV_HCALL_RELAY` per-VM: opts the VM into the relay with
  the selected bitmask.

## KVM functions involved

- `nested_vmx_reflect_vmexit` (`arch/x86/kvm/vmx/nested.c`): the relay branch.
  When a VM has `nested_hv_relay_mask != 0`, the exit reason is `VMCALL`, the
  guest `RCX` has `HV_HYPERCALL_NESTED` set and a relayable call code, and
  `nested_evmcs_l2_direct_hypercall_enabled(vcpu)` is true: clear the nested
  bit and return `false` so KVM keeps the exit in L0.

- `nested_evmcs_l2_direct_hypercall_enabled` (`arch/x86/kvm/vmx/hyperv.c`):
  checks the L2's enlightened VMCS `hv_enlightenments_control.nested_flush_hypercall`
  bit AND the L1 VP-assist page `nested_control.features.directhypercall`
  feature. KVM trusts this gate for the L2 TLB-flush hypercall; the relay reuses
  it. A grandchild L2 that L1 did not authorize for direct nested hypercalls is
  never relayed. (Previously named `nested_evmcs_l2_tlb_flush_enabled`; patch 1
  of the RFC renames it to reflect its broader scope.)

- `kvm_hv_hypercall` (`arch/x86/kvm/hyperv.c`): handles the kept-in-L0 call.
  Before the existing `switch (hc.code)`, when `nested_hv_relay_mask` is set
  and the call is `HVCALL_POST_MESSAGE` or `HVCALL_SIGNAL_EVENT` and the MMU is
  nested: translate `hc.ingpa` from L2 GPA to L1 GPA via
  `kvm_x86_ops.nested_ops->translate_nested_gpa(..., PFERR_GUEST_FINAL_MASK, ...)`
  (the same path as the L2 TLB-flush slow path). An `INVALID_GPA` result rejects
  the call with `HV_STATUS_INVALID_HYPERCALL_INPUT`.
  The `mmu_is_nested()` guard (not `is_guest_mode()`) is deliberate:
  `translate_nested_gpa()` has a `BUG_ON(!mmu_is_nested())`, and with shadow
  paging the L2 GPA is already an L1 GPA so the translation is both unsafe to
  call and unnecessary.

- `kvm_vm_ioctl_enable_cap` (`arch/x86/kvm/x86.c`): new case for
  `KVM_CAP_NESTED_HYPERV_HCALL_RELAY`. Validates that `args[0]` contains only
  `KVM_NESTED_HYPERV_RELAY_POST_MESSAGE | KVM_NESTED_HYPERV_RELAY_SIGNAL_EVENT`;
  stores the mask in `kvm->arch.nested_hv_relay_mask`.

## Windows kernel symbols relevant to boot

Public PDBs: `ntkrnlmp.pdb`, `vmbus.pdb` (MS symbol server). RVAs are
build-specific; re-resolve against the PDB for a different build.

- `vmbus.sys!RootDevicePrepareHardwareChild`: always takes the enlightened path
  (`IsInterruptEnlightenmentAvailable` is hardcoded `return 1` here) and calls
  `ntoskrnl!HvlRegisterInterruptCallback(3, XPartEnlightenedIsr)`. If that
  returns `< 0`, the child-FDO bring-up aborts and the boot disk never appears
  (`0x7B`).

- `ntoskrnl!HvlRegisterInterruptCallback` (rva `0x57ffd0`): returns
  `STATUS_NOT_SUPPORTED` if the global byte `ntoskrnl!HvlHypervisorConnected`
  (rva `0xFC6AD7`) is zero. That byte is set to 1 by
  `ntoskrnl!HvlPhase0Initialize` once the kernel has connected to its
  hypervisor. With the current capabilities it is always 1 here (the root
  connects to `hvix64`, which presents Hv#1), so the callback registration
  succeeds. The earlier "needs a guest patch" conclusion was wrong: the
  registration does not fail with the current capability set.

## Correctness items

**Per-L2 authorization.** Only an L2 that L1 explicitly authorized for direct
nested hypercalls is relayed. The gate (`nested_evmcs_l2_direct_hypercall_enabled`)
is the same predicate KVM already trusts for the L2 TLB-flush hypercall. Every
relayed call in our boots reads `evmcs=1 nfh=1 auth=1` at the interception
point; grandchild L2s read `auth=0` and are not relayed.

**GPA translation.** The relayed call's input GPA is translated L2 to L1
synchronously in the faulting vCPU's exit context, result not cached. A page
removed from the L2 root's GPA space makes the walk return `INVALID_GPA`, which
the relay rejects. In our boots the root is identity-mapped, so the translation
is a no-op; it is correct in general (storvsc issued thousands of SCSI commands
with `srb_status: SUCCESS` throughout).

**Translation lifetime.** The translate-to-L1-GPA result is used immediately in
the same exit; it is never stored. For `HvSignalEvent`, KVM reads the call in
the exit. For `HvPostMessage`, KVM hands the translated L1 GPA to userspace for
the payload read, the same exit design as a non-nested post today. A concurrent
enlightened stage-2 flush serializes on the MMU lock against the actual page
operation; the faulting vCPU cannot flush mid-hypercall.

## Prerequisites to reproduce

- Host: Intel VT-x with `kvm_intel nested=Y`; the relay `kvm.ko`/`kvm-intel.ko`
  built and loaded from a matching Proxmox kernel source.
- OpenVMM: launched with `--hypervisor kvm:nested_virt`; the capability block
  above is advertised automatically on the nested path.
- Guest: a stock Hyper-V/VBS-enabled Windows 11 image with the usual Hyper-V
  boot-start drivers (storvsc/vmbus/netvsc). No driver patch, no test-signing;
  Secure Boot on is fine. Boot disk as emulated PCIe NVMe.

## Where the code lives

| Repo | What it is |
|------|-----------|
| [github.com/bitranox/linux-nested-vmbus-relay](https://github.com/bitranox/linux-nested-vmbus-relay) | Fork of `kvm-x86/linux`, branch `nested-vmbus-relay`: the mainline RFC form as a single commit on top of `kvm-x86/next`. |
| [github.com/bitranox/pve-nested-vmbus-relay](https://github.com/bitranox/pve-nested-vmbus-relay) | Proxmox VE kernel variant: a build script (anchored text insertions) plus this design doc, not a fork. |
