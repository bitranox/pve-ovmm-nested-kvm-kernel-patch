# Forward-porting the mainline patches to newer kvm-x86

The `patch/linux/` patches are authored against a pinned `kvm-x86/next` base (the
same base the upstream RFC branches sit on). `kvm-x86/next` rebases onto newer
mainline often, so the patches need a small rebase before an upstream submission.

Last verified 2026-06-24 against `kvm-x86/next` at `9d4853b044bee` (about 1.3M
commits past the pinned base). Both patches apply and the kvm + kvm-intel modules
compile with exactly two trivial deltas in the relay patch; the timer-guard patch
needs none.

## Deltas when rebasing the relay onto current kvm-x86

1. **`include/uapi/linux/kvm.h` (context drift).** Upstream keeps adding
   `KVM_CAP_*` entries, so the cap-define insertion anchor moves. Re-anchor to
   insert after the current last `KVM_CAP_*` (at this writing, after
   `KVM_CAP_S390_HPAGE_2G 249`). The cap value stays `0x4f564d52`, a high private
   sentinel that does not collide with the sequential upstream range. Note `249`
   is now taken upstream (`KVM_CAP_S390_HPAGE_2G`), so a low placeholder would
   collide today; the sentinel does not.

2. **`arch/x86/kvm/vmx/nested.c` (API rename).** `kvm_rcx_write()` was removed and
   the GPR accessors gained a `_raw` suffix (`kvm_cache_regs.h` was also renamed
   to `regs.h`). Use `kvm_rcx_write_raw()`.

The timer-guard patch (`arch/x86/kvm/hyperv.c`, `arch/x86/include/asm/kvm_host.h`)
applies and compiles unchanged.

## Build note

An out-of-tree `make M=arch/x86/kvm` against a tree prepared only with
`modules_prepare` links `kvm.o`/`kvm-intel.o` but then reports unresolved core
symbols at `modpost` (`xa_load`, `mutex_lock`, `noop_llseek`, ...). That is the
missing full `vmlinux` / `Module.symvers`, not the patches; stock kvm shows the
same in that setup. A full in-tree build resolves them.
