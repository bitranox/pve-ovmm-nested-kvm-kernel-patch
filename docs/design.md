# Nested Hyper-V vmbus under OpenVMM on KVM: the working solution, the flags, the symbols, and the PR #3721 questions

Status 2026-06-11/12: a **stock** Windows 11 guest with Hyper-V/VBS enabled boots
to the desktop under OpenVMM on the KVM backend, with storvsc, netvsp and
synthvid all working, **no Windows guest patch**, no test-signing, Secure Boot
intact. The fix is entirely L0: OpenVMM advertises the capabilities, and KVM
relays the L2 root partition's vmbus hypercalls to L0. This document records
exactly which flags and KVM functions are involved and why, which Windows kernel
symbols matter, the prerequisite that has to hold for the guest to connect, and
how this maps onto the points raised in PR #3721.

## Preamble: our solution, and why it is the right layering

The layers:

- **L0** = KVM plus OpenVMM (userspace VMM). OpenVMM presents a Hyper-V platform
  (synic, the Hv#1 hypercall ABI, a vmbus server on connection id 1).
- **L1** = hvix64, the guest's own hypervisor, launched when the guest enables
  Hyper-V/VBS.
- **L2** = the Windows kernel, running as hvix64's root partition.

The root's vmbus control hypercalls, `HvPostMessage` (0x5c) and `HvSignalEvent`
(0x5d), are issued as `VMCALL`s with the Hyper-V **nested bit** (RCX bit 31) set,
which is the guest itself saying "forward this to the parent layer, not locally."
Because L0 owns the outermost VMCS, that `VMCALL` exits to **KVM first**, before
hvix64 handles it, and KVM by default reflects it up to hvix64. The kernel's
synic (SIMP/SIEFP/SINT MSRs) is also visible to L0. **Our solution: KVM keeps the
L2 root's nested-bit 0x5c/0x5d posts in L0 and hands them to OpenVMM's vmbus
server (connection id 1), instead of reflecting them to hvix64; OpenVMM answers
and delivers the reply into the kernel's L0-visible SIMP and raises its SINT.**

A fair question is whether the L2 root should be talking to L1 instead of L0.

On real Hyper-V-on-Hyper-V, L1 is the courier: L2 sets the nested bit, the VMCALL
exits to L0, L0 reflects it to L1, and L1 (Hyper-V) forwards it up to L0's vmbus.
So the "pure" design is exactly L2 -> L1 -> L0, with L1 doing the relay.

That path is closed under OpenVMM, and we proved it (8 RE rounds): hvix64 has no
outbound primitive to forward a root's vmbus to a non-Hyper-V parent, and it
classifies our partition so the relay machinery never engages. It cannot be
flipped by any CPUID/MSR/advertisement, and it is closed Microsoft code. So "make
L1 relay to L0" is simply not available to us.

And critically, L0 is where the post actually needs to go anyway. hvix64 under
OpenVMM provides the root no vmbus device backends: storvsc, netvsp and synthvid
all live in OpenVMM (L0). So the root's vmbus has nothing useful to talk to at
L1; its real vmbus server and devices are in L0. The nested bit asked for the
parent (L0), and L0 is genuinely where the boot disk lives.

So KVM catching the nested-bit post and handing it to OpenVMM is delivering it to
the destination the guest requested, just skipping the L1-forwards-it step that
hvix64 refuses to perform. It is not L0 reaching past L1 against the design, it is
L0 fulfilling the role the nested bit names, because the intended courier (hvix64)
will not and the intended destination (the vmbus server plus devices) is L0
regardless.

Empirically it is correct end to end: the stock guest boots to desktop, channels
negotiate, and the reverse direction (reply into the root's L0-visible SIMP plus
SINT) works. It is also the direction jstarks endorsed on the PR ("get KVM to do
the right thing with the nested bit"). The only more pure alternative (L1 relays)
is the one that is provably closed.

Short version: L2 still talks to L1 for everything L1 owns; the vmbus posts are
explicitly tagged for the parent, and L0 is both what the tag means and where the
devices are. Right path. Only the explicitly-parent-bound (nested-bit) 0x5c/0x5d
posts are intercepted; every other hypercall still reflects to hvix64.

## Part 1: the OpenVMM flags, and why each is needed

All live in the `nested_virt` block of
`vmm_core/virt_kvm/src/arch/x86_64/mod.rs`. They do two jobs: (A) let hvix64
**run** as the guest's hypervisor so the L2 root exists at all, and (B) grant the
L2 root **permission** to issue the vmbus hypercalls the relay carries. Nothing
here tries to make hvix64 forward anything; the relay is below hvix64.

### CPUID 0x40000000 / 0x40000001 / 0x40000002

- Vendor `Microsoft Hv`, interface `Hv#1`: the guest only treats the platform as
  Hyper-V (loads vmbus.sys, runs hvix64) if these say so. Required.
- A real-looking HV version (0x40000002) when nesting, not 0.0.0.0: a guest
  hypervisor may gate nested behavior on the parent looking like a current,
  capable Hyper-V. Cheap insurance; keep when nesting.

### CPUID 0x40000003 partition privileges (job A: hvix64 must run)

- `AccessPartitionReferenceTsc` + `AccessReenlightenmentControls`: hvix64 needs
  the reference-TSC clock and the reenlightenment notification when nested, else
  it resets the partition a fixed interval into boot.
- `AccessHypercallMsrs`, `AccessVpIndex`, `AccessFrequencyMsrs`,
  `AccessSynicMsrs`, `AccessSyntheticTimerMsrs`, `AccessVpRuntimeMsr`,
  `AccessPartitionReferenceCounter`: the base HV enlightenment surface. SynicMsrs
  + VpIndex are also what the kernel reads to bring up the synic the relay rides.
- `AccessApicMsrs`: REQUIRED for the relay path. With it, vmbus.sys uses the synic
  `HvPostMessage(conn 1)` path the relay catches. Withholding it pushes vmbus.sys
  onto the GHCB/SNP tunnel, which needs isolated-partition shared memory hvix64
  cannot back here (ends in a 0x7E memset of an unbacked page). Always on; the
  non-nested path already required it.

### CPUID 0x40000003 partition privileges (job B: let the root post)

- `PostMessages` + `SignalEvents`: the privilege to issue the
  `HvPostMessage`/`HvSignalEvent` the relay intercepts.
- `CreatePort` + `ConnectPort`: vmbus channel setup.
- Deliberately NOT granted: `AccessMemoryPool`, `CreatePartitions`,
  `StartVirtualProcessor` (they push the root onto the isolated-partition path or
  trip the guest HAL).

### CPUID 0x40000004 enlightenment recommendations (job A)

- `use_relaxed_timing`: slackens watchdog/spinlock deadlines because virtualized;
  without it a nested guest blows bare-metal timeouts and resets mid-boot.
- `use_apic_msrs`: pairs with the `AccessApicMsrs` privilege (the synic path).
- `use_hypercall_for_remote_flush_and_local_flush_entire`,
  `use_synthetic_cluster_ipi`, `use_ex_processor_masks`: let hvix64 offload TLB
  flush and cluster IPI to the in-kernel hypercall path instead of a storm of
  exits, so it stays fast enough not to time out.
- `nested` + `use_vmcs_enlightenments`: recommend the enlightened-VMCS path so
  hvix64 accesses the VMCS through the enlightened-VMCS page instead of trapping
  every VMREAD/VMWRITE to L0. Without it: ~4.25M VMREAD + ~1.87M VMWRITE exits in
  45s, storage times out, INACCESSIBLE_BOOT_DEVICE. Required, pairs with the KVM
  cap below.
- `deprecate_auto_eoi`, `long_spin_wait_count = 0xffffffff`: standard.

### Dropped: `vp_ghcb_root_mapping` (0x40000003 ECX bit 10)

Advertised earlier to make hvix64 engage its OWN nested-synic relay (its
capability decode enables the nested-synic handlers when the bit is set). The
KVM-side relay catches the root's posts below hvix64 and never uses hvix64's
nested synic, so the bit is irrelevant. Dropped, and the nested guest still boots
to desktop on the synic+relay path (validated).

### KVM-crate / per-vCPU changes

- `KVM_CAP_HYPERV_ENLIGHTENED_VMCS` per-vCPU (`enable_hyperv_evmcs` in `vm/kvm`):
  the reboot-loop fix. Windows uses the enlightened VMCS; without the cap KVM did
  not engage it at VM-enter (`current_vmptr == INVALID_GPA`), so hvix64 retried
  the failing launch ~586K times then rebooted. Required.
- `nested_state` get/set made a no-op for the KVM backend (`vp_state.rs`): with
  nesting the `nested_state` element is "present" and the backend returned
  `NotSupported`, aborting any guest-initiated reset and wedging the VM. Required.
- NEW `KVM_CAP_NESTED_VMBUS_RELAY` per-VM (`Partition::enable_nested_vmbus_relay`,
  called from the nested_virt path): opts this VM into the relay. Tolerant of a
  stock kernel without the cap.

## Part 2: the KVM functions

- `nested_vmx_reflect_vmexit` (`arch/x86/kvm/vmx/nested.c`): the relay branch.
  For a VM that set `kvm->arch.nested_vmbus_relay`, if the L2 exit is a `VMCALL`
  and guest RCX low 16 bits are 0x5c/0x5d with the nested bit (RCX bit 31) set,
  clear the nested bit and `return false` so KVM keeps the exit in L0 rather than
  reflecting to L1.
- `kvm_hv_hypercall` (`arch/x86/kvm/hyperv.c`): handles the kept-in-L0 call.
  `HvPostMessage` exits to userspace (OpenVMM); `HvSignalEvent` is handled
  in-kernel. The nested bit must be cleared first: it sits in
  `HV_HYPERCALL_RSVD0_MASK`, and the dispatcher rejects reserved bits with
  `HV_STATUS_INVALID_HYPERCALL_INPUT` before reaching the call's case.
- `kvm_vm_ioctl_enable_cap` (`arch/x86/kvm/x86.c`) + `struct kvm_arch`
  (`arch/x86/include/asm/kvm_host.h`) + the uapi define
  (`include/uapi/linux/kvm.h`): add `KVM_CAP_NESTED_VMBUS_RELAY`, a per-VM
  `bool nested_vmbus_relay`, and the enable-cap case that sets it. The PoC
  equivalent is the `hvpost_hook` ftrace module on the same function.
- Reverse direction: OpenVMM writes the InitiateContact reply into the kernel's
  SIMP and signals the SINT. The kernel's synic pages are L0-visible (KVM sees
  its SCONTROL/SIMP/SIEFP/SINT writes), so this is reachable without hvix64.

## Part 3: the Windows kernel symbols, and the prerequisite for the check to pass

Public PDBs: `ntkrnlmp.pdb`, `vmbus.pdb` (MS symbol server; extract the
WOF-compressed System32 binaries with the ebiggers ntfs-3g system-compression
plugin). RVAs below are from the build under test; re-resolve via the PDB on a
different build.

- `vmbus.sys!RootDevicePrepareHardwareChild`: always takes the enlightened path
  (`vmbus.sys!IsInterruptEnlightenmentAvailable` is hardcoded `return 1` here) and
  calls `ntoskrnl!HvlRegisterInterruptCallback(3, XPartEnlightenedIsr)`. If that
  returns `< 0` it aborts the child-FDO bring-up (the `JNS` at RVA `0x2b849`) and
  the boot disk never appears (0x7B).
- `ntoskrnl!HvlRegisterInterruptCallback` (rva `0x57ffd0`): three returns:
  `STATUS_INVALID_PARAMETER` if index > 4 (index 3 passes); `STATUS_NOT_SUPPORTED`
  iff the global byte `ntoskrnl!HvlHypervisorConnected` (rva `0xFC6AD7`) is 0;
  else it `lock cmpxchg`s the callback into `ntoskrnl!HvlpInterruptCallback`
  (rva `0xFC5610`, slot = index), returns vector `index + 0x30`, or
  `STATUS_UNSUCCESSFUL` if that slot was already taken.
- `ntoskrnl!HvlPhase0Initialize`: sets `HvlHypervisorConnected = 1` right after
  `HvlpSetupBootProcessorEarlyHypercallPages()` succeeds, i.e. once the kernel has
  connected to its hypervisor.

**The prerequisite for the check to pass:** `HvlHypervisorConnected == 1`. It is
satisfied for free here, because the L2 root connects to hvix64 (which presents
Hv#1 and the hypercall MSRs, rooted in what OpenVMM advertises). So
`HvlRegisterInterruptCallback(3)` SUCCEEDS, with no enlightenment-bit tweak.
Verified at runtime with the OpenVMM gdbstub: `HvlpInterruptCallback` slot 3
holds a `vmbus.sys` handler (registration succeeded) and `HvlHypervisorConnected`
reads 1. This is why the earlier "the SINT3 registration fails, patch vmbus.sys"
conclusion is obsolete: with the current capabilities it does not fail.

Other useful symbols: `vmbus.sys!ChpConnectToParent`, `vmbus.sys!PncSendMessage`,
`vmbus.sys!XPartPncPostInterruptsEnabledChild`. Host-side observation:
`kvm:kvm_hv_synic_set_msr`, `kvm:kvm_hv_hypercall`,
`kprobe:nested_vmx_reflect_vmexit`, and in the OpenVMM log the second `Guest
negotiated version` (the kernel's vmbus.sys connecting, vs the firmware's first),
plus the `netvsp`/`storvsp` negotiation lines.

## Part 4: the PR #3721 points

Your framing, "get KVM to do the right thing with the nested bit; it's not enough
to just pass it through to the VMM": agreed, and the production form is a per-VM
`KVM_CAP_NESTED_VMBUS_RELAY` checked in `nested_vmx_reflect_vmexit`, not an
unconditional pass-through. On your three specifics:

1. **The L1-set "this L2 may make nested hypercalls" bit, set only on the L2 root,
   not on L2 guests.** Done. KVM already carries this exact authorization: the
   helper `nested_evmcs_l2_tlb_flush_enabled(vcpu)` checks the L2's enlightened
   VMCS `hv_enlightenments_control.nested_flush_hypercall` bit AND the L1 VP-assist
   page `nested_control.features.directhypercall` feature, and KVM trusts it to
   decide whether an L2 VMCALL TLB-flush hypercall is handled in L0
   (`nested_vmx_l0_wants_exit`, the `EXIT_REASON_VMCALL` case). The relay branch in
   `nested_vmx_reflect_vmexit` now gates on that same predicate, so a grandchild
   L2 that L1 did not authorize for direct nested hypercalls (`auth` false) is
   never relayed and keeps its own L1 synic. Verified at the interception point on
   our boot: every relayed `0x8000005c` / `0x8001005d` exit reads `evmcs=1 nfh=1
   auth=1`, so the gate passes for the root and does not regress the boot.

2. **Translate the input-page GPA L2 to L1 in KVM, and filter pages removed from
   the L2 root's GPA space.** Done. `kvm_hv_hypercall` now translates the relayed
   synic post's input GPA L2->L1 for `HVCALL_POST_MESSAGE` and the slow
   `HVCALL_SIGNAL_EVENT`, gated on `!hc.fast && mmu_is_nested(vcpu)`, reusing
   `kvm_x86_ops.nested_ops->translate_nested_gpa(..., PFERR_GUEST_FINAL_MASK, ...)`
   exactly as the L2 TLB-flush slow path does. The guard is `mmu_is_nested()`, not
   `is_guest_mode()`: `translate_nested_gpa()` opens with `BUG_ON(!mmu_is_nested())`,
   and with shadow paging (no nested EPT) the L2 GPA is already an L1 GPA, so the
   translation is both unsafe to call and unnecessary there. (Current `kvm-x86/next`
   uses the same `mmu_is_nested()` guard on the TLB-flush path; older trees still say
   `is_guest_mode()`.) A page removed from the L2 root's
   GPA space faults in the walk and returns `INVALID_GPA`, which we reject with
   `HV_STATUS_INVALID_HYPERCALL_INPUT` (the confidential-page filter comes for
   free). Confirmed the L2 root is identity-mapped on our boot (storvsp issues
   thousands of SCSI commands, all `srb_status: SUCCESS`, with OpenVMM reading the
   root's memory by plain L1-GPA access), so the translation is a no-op here and
   the guest still boots to desktop with it in place; it is correct in general.

3. **Translation lifetime vs an enlightened stage-2 TLB invalidation.** Addressed
   for the translation; one residual window is upstream's existing model. The
   enlightened stage-2 flushes exist (`HvCallFlushGuestPhysicalAddressSpace` 0xAF,
   `HvCallFlushGuestPhysicalAddressList` 0xB0, distinct from the stage-1 VA flushes
   0x2/0x3); in our boots only the stage-1 flushes and cluster-IPI reached L0, so
   0xAF/0xB0 is not a steady-state guarantee. The translate in (2) runs
   synchronously in the faulting vCPU's exit context and is never cached: the
   result lives only in the local `hc.ingpa` for that one exit. The slow
   `HvSignalEvent` read happens in-kernel in the same exit, fully synchronous. The
   one remaining window is `HvPostMessage`, whose payload KVM hands to userspace to
   read after the exit, the same way it does for a non-nested post (this is KVM's
   existing userspace-post design, not something the relay introduces). A concurrent
   stage-2 flush serializes on the MMU lock against the actual page operation, and
   the faulting vCPU cannot flush mid-hypercall, so the translated L1 GPA stays
   valid for the read.

### Open question: do we need the in-kernel `HvPostMessage` read at all?

The "safe design" you sketched ends with "translate and read synchronously ...
hand userspace the data." For `HvSignalEvent` we already do (KVM reads it in the
exit). For `HvPostMessage`, KVM hands userspace the translated L1 GPA and the VMM
reads the message after the exit, which is exactly what KVM does for a *non-nested*
post today. Fully matching the sketch means KVM reads the up-to-240-byte payload
in-kernel under the MMU lock and ships the bytes to userspace, which needs a new
`struct kvm_hyperv_exit` field (the payload does not fit in `params[2]`) plus a
matching VMM change. Before doing that, the question we want your read on:

**Is the post-exit userspace read actually a risk here, or only a tidiness item?**
Our analysis says it is not a security risk:

* The address handed to userspace is an **L1 GPA**. It always resolves through the
  guest's own memslots, so even a stale read stays inside the guest's own memory.
  There is no path to host memory or another VM.
* For the read to be stale, the L1 (hvix64) would have to remap the exact L1 page
  backing an `HvPostMessage` it just issued, in the window before its own reply is
  delivered. A guest does not pull the page out from under a synic message it is
  waiting on; a malicious guest that did so would only corrupt **its own** post.
* The VMM's vmbus server validates the message (connection id, length) and a bad
  one is dropped or mis-routed *within the guest's own vmbus namespace*, with no
  effect on the host or other guests.
* This is identical to the non-nested `HvPostMessage` userspace exit that ships in
  KVM today; the relay adds a benign extra translation layer, not a new risk class.

So our position is that the synchronous, uncached translation is sufficient and the
in-kernel read is a tidiness improvement, not a correctness or security fix. If you
disagree, or if upstream would want the in-kernel read as a condition of merge, we
will add it (KVM side plus the VMM consumer). Which way do you want it?

Your other question, "why doesn't the ordinary vmbus init path work once you
handle the nested bit, since it works on Hyper-V-on-Hyper-V": it does work now
with the stock driver. The earlier failure was not the registration; it was the
relay not carrying the post. With the relay in place and the current
capabilities, `HvlRegisterInterruptCallback(3)` succeeds, vmbus.sys posts
InitiateContact, KVM relays it, and OpenVMM's vmbus server answers.

### Summary: solved / not solved / not an issue / can or cannot

- **Solved:** a stock Hyper-V/VBS guest boots to desktop with no guest patch; the
  L0 capability set; the relay mechanism; per-VM scoping via the KVM capability;
  the L1 per-L2 nested-hypercall authorization gate (`nested_evmcs_l2_tlb_flush_enabled`,
  so a grandchild is not relayed); the L2-to-L1 input-page translation inside KVM
  for `HvPostMessage` / `HvSignalEvent` (with the removed-page filter); the
  translation lifetime (synchronous, uncached in the exit context).
- **Remaining follow-up (not a correctness gap for this design):** reading the
  `HvPostMessage` payload in-kernel under the MMU lock and handing userspace the
  bytes instead of the GPA, to close the userspace-read window that KVM's existing
  (non-nested) post path already has. An OpenVMM/KVM ABI change, not needed here.
- **Not an issue:** the L2-GPA translation for the boot path (identity map); the
  assumption that hvix64 must forward the vmbus (it is bypassed, and L0 is the
  correct destination anyway); the SINT3 registration "failing" (it succeeds with
  the current capabilities); needing a Windows guest patch (none is needed).
- **Cannot be done from L0:** nothing fundamental remains for this guest. The
  earlier "needs hvix64 to support a non-Hyper-V parent, Microsoft-only"
  conclusion was wrong: the relay does not need hvix64 at all. (The one thing that
  genuinely cannot be done from L0 is making hvix64 itself forward the post, but
  that path is unnecessary.)

## Part 5: prerequisites to reproduce

- Host: Intel VT-x with `kvm_intel nested=Y`; the relay loaded (the `hvpost_hook`
  ftrace module as a PoC, or the in-tree per-VM `KVM_CAP_NESTED_VMBUS_RELAY` patch
  for production).
- OpenVMM: launched with `--hypervisor kvm:nested_virt`; the `nested_virt` flag
  block above, advertised automatically when nesting.
- Guest: a stock Hyper-V/VBS-enabled Windows 11 image with the usual Hyper-V
  boot-start drivers (storvsc/vmbus/netvsc), the same image that runs non-nested.
  No driver patch, no test-signing; Secure Boot on is fine.

## Part 6: where the code lives, and a request

The KVM change is published as two public repositories so you can read, build, and
comment on it directly:

| Repo | What it is |
|------|------------|
| [github.com/bitranox/linux-nested-vmbus-relay](https://github.com/bitranox/linux-nested-vmbus-relay) | A real fork of `kvm-x86/linux`, branch `nested-vmbus-relay`, a single commit on top of the latest `kvm-x86/next` (the mainline variant). |
| [github.com/bitranox/pve-nested-vmbus-relay](https://github.com/bitranox/pve-nested-vmbus-relay) | The Proxmox VE kernel variant (Proxmox's kernel is not on GitHub, so this is a patch + build script + this design doc, not a fork). |

The capability number `0x4f564d52` is an out-of-tree private sentinel; a real merge
would take an assigned `KVM_CAP_*` value.

**The request.** We would like help getting this into the upstream Linux kernel (and
from there into the Proxmox kernel, which tracks Ubuntu/mainline). It is a small,
self-contained, opt-in per-VM capability that touches only the nested-VMX reflect
path and the Hyper-V hypercall path, and it is gated on the same enlightened-VMCS
authorization KVM already trusts for the L2 TLB-flush hypercall. The natural reviewers
are the KVM x86 and Hyper-V-on-KVM maintainers, and Microsoft's perspective on the
nested-synic semantics would carry weight there. Concretely, we are asking for:

1. A review of the relay's correctness against the nested-Hyper-V model, especially the
   authorization gate and the open question in Part 4 (do we need the in-kernel
   `HvPostMessage` read, or is the synchronous translation enough).
2. Guidance on the right shape for upstream: the per-VM cap as written, or whether the
   capability should be folded into the existing eVMCS / direct-hypercall machinery.
3. If it is acceptable in principle, sponsorship or co-authorship on the LKML posting to
   the KVM list, so it lands as a maintained feature rather than an out-of-tree patch we
   carry for Proxmox.

The goal is a stock, unmodified Windows guest running Hyper-V/VBS on KVM with no
out-of-tree kernel carry, which benefits any KVM-based VMM, not just ours.
