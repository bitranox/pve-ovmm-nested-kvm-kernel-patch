# Bounding past-dated one-shot Hyper-V timer re-arm storms

Status: with the hypercall relay alone, a nested Hyper-V guest boots on a host
without VMX TSC scaling, but it can hang at a no-taskbar desktop. The cause is a
synthetic-timer re-arm storm in the L1 root partition. This guard bounds the
storm in `stimer_start()` and is needed alongside the relay on such hosts; on a
TSC-scaling host it is inert.

## When the guard is needed

The hypercall relay gets a Windows guest with Hyper-V/VBS enabled to boot under
OpenVMM on KVM (see `design.md`). On a host whose CPU can scale the guest TSC
(any modern CPU), that is all you need. On an older host without VMX TSC scaling,
the boot reaches the desktop but then freezes: the desktop comes up with no
taskbar and the guest stops responding, while one host CPU sits pegged at 100%.

The freeze is a synthetic-timer re-arm storm, not a relay fault. The relay and
the guard are independent: the relay makes the root vmbus connect; the guard
keeps the root's timer use from pegging a CPU.

## Root cause

A Windows guest that enables Hyper-V/VBS runs its own kernel as the root
partition of a nested hypervisor (an L2 guest):

```
guest kernel  ->  hvix64 (L1)  ->  KVM (L0)
```

The root partition uses a direct-mode auto-enable one-shot synthetic timer as a
short spin-delay. It arms a deadline a few hundred microseconds out, takes the
direct interrupt when it expires, and re-arms the same deadline.

By the time KVM evaluates the armed deadline (in `stimer_start()`), it is already
in the past, so per TLFS v4 section 15.3.1 the one-shot expires immediately: KVM
marks it pending with zero delay, the guest EOIs, the auto-enable re-arms the same
deadline, and the timer fires in a tight loop that pegs the vCPU in VM-exit
handling so the spin-wait never advances and the guest hangs (~96k re-arms/s/vCPU).

This is not a clock error. The per-vCPU TSC offsets are synchronized (measured:
identical across all vCPUs) and the Hyper-V reference TSC page tracks kvmclock to
under a microsecond (measured, both idle and under nested load), so the reference
counter the guest reads is accurate; forcing KVM's internal counter onto kvmclock
does not stop the storm either. The deadline is genuinely past, not skewed: the
near-term spin-delay outruns the nested arm-and-evaluate round-trip. It is seen
only on hosts without VMX TSC scaling, so the guard is gated on
`!kvm_caps.has_tsc_control`.

This is in-kernel KVM emulation. The synthetic timer fires entirely inside KVM
(the SynIC timer code), with no userspace exit on the fire path, so a userspace
VMM cannot see or rate-limit the storm. The firing decision is a kernel-only
primitive, which is why the guard belongs in the kernel and not in OpenVMM.

## The fix

In `stimer_start()`, on the past-dated one-shot path and only when
`!kvm_caps.has_tsc_control`, the guard detects the immediate-fire loop and arms a
small forward dwell instead of firing with zero delay. Wall-clock and thus the
reference counter advance during the dwell, so the deadline is genuinely reached
and the loop breaks.

The dwell is adaptive:

- It starts at a small minimum and backs off toward a cap while the storm
  persists, so a brief burst dwells little and a sustained storm dwells more.
- It is sticky while a timer is throttled: a backoff dwell that grows past the
  detect window does not reset the counter and drop the throttle, which would let
  the storm burst back through between dwells.
- It is released after a run of genuinely-future arms, with hysteresis: the
  occasional future arm a guest interleaves into a storm (a timer reconfig, say)
  does not drop the dwell and let the storm resume.

An isolated past-dated one-shot still fires immediately. The TLFS-visible
behaviour is unchanged for any non-storming use; only a sustained immediate-fire
loop is slowed.

## The TSC-scaling gate

The guard is gated on `!kvm_caps.has_tsc_control`. On a TSC-scaling host that
capability is set, the gate is false, the loop never forms, and the guarded
branch is never entered. So the guard has no effect and no
cost on a modern CPU, whether or not it is enabled. It does anything only on the
older hosts where the storm is possible.

## Parameters

Two sysfs-writable module parameters control the guard:

| Parameter                    | Default            | What it does                                                          |
|------------------------------|--------------------|----------------------------------------------------------------------|
| `hv_stimer_guard_enabled`    | on                 | Master switch (bool). Inert on a TSC-scaling host regardless.        |
| `hv_stimer_imm_dwell_max_ns` | 2000000 (2 ms)     | Caps how far the adaptive dwell backs off (nanoseconds).             |

The detection thresholds, the initial dwell, the backoff factor, and the release
hysteresis are fixed constants. Tuning across idle and nested-container load
showed that only the cap changes useful behaviour, so the rest are not exposed.

## The cap is the one performance lever

`hv_stimer_imm_dwell_max_ns` trades host CPU spent on the storm against the
latency of each skew-caught guest spin-wait. Measured in a nested Windows 11
guest running an in-guest Windows container benchmark (7-Zip CPU, diskspd 4K
random), sweeping the cap:

- Default 2 ms: the storm settles to a low steady rate (down from about 1.3M
  expirations/s), a balanced point that needs no per-host tuning.
- Lower cap (about 250 us): each spin-wait finishes sooner, about +56% in-guest
  container disk IOPS, at a higher storm rate (more host CPU).
- Higher cap (about 8 ms): less host CPU, about +12% container CPU throughput, at
  the cost of longer spin-waits (lower disk).

So lower the cap for an IO-bound nested guest, raise it for a CPU-bound one, and
leave it at the default for mixed or unknown work. The guest stayed responsive
across the whole range. The storm rate measures host overhead, not guest
throughput: the best-IO setting ran the higher storm.

## Kernel guard versus the userland ovm-timer-guard

OpenVMM also ships a userland alternative, the per-VM `--ovm-timer-guard`. It
drops the Hyper-V reference TSC page so KVM serves time from kvmclock; the storm
then never forms, with no kernel patch at all, at the cost of trapped Hyper-V time
reads. The two mitigations were compared in a nested Windows 11 guest running an
in-guest Windows container benchmark (7-Zip CPU, diskspd 4K random) on a host
without VMX TSC scaling.

At a single moderate load point:

| Config                        | storm/s | 7-Zip MIPS | disk MiB/s | disk IOPS | usable                  |
|-------------------------------|--------:|-----------:|-----------:|----------:|-------------------------|
| process isolation, no Hyper-V |     ~0  |      3491  |       399  |     102k  | baseline (no nested VM) |
| Hyper-V iso + kernel guard    |     ~8k |      3015  |      53.0  |     13.6k | yes                     |
| Hyper-V iso + no mitigation   |   ~2.5M |        -   |        -   |       -   | no (storm, unreachable) |
| Hyper-V iso + ovm-timer-guard |     ~0  |      2900  |      46.6  |     11.9k | yes                     |

Disk throughput depends on queue depth. Swept over concurrency (same 4K-random
base):

| Disk load | kernel-guard MiB/s | kernel-guard IOPS | ovm-guard MiB/s | ovm-guard IOPS |
|-----------|-------------------:|------------------:|----------------:|---------------:|
| -o4  -t2  |              53.0  |            13566  |           46.6  |          11930 |
| -o16 -t2  |              43.7  |            11187  |           48.3  |          12364 |
| -o32 -t4  |              27.8  |             7122  |           38.5  |           9857 |

CPU throughput is within a few percent either way (the guard's residual storm
against the ovm-guard's trapped time reads). Disk is the differentiator: under
rising concurrency the kernel guard's residual storm competes for CPU and its
throughput drops, while the storm-free ovm-timer-guard holds. The two cross over
around -o16, and at heavy load the ovm-timer-guard is about +38%.

### Which to use

The typical nested workload here is Hyper-V-isolated Windows containers (CI build
agents and self-hosted runners) and nested dev/test guests, which are CPU-heavy
while compiling and disk-heavy while checking out and restoring, so the load is
mixed and bursty rather than steadily one or the other.

- Default to the kernel guard at the 2 ms cap. It is host-global, self-tuning, and
  needs no per-VM setup, and it serves interactive, mixed, and CPU-bound nested
  guests well. This is the right baseline for most hosts.
- For a host that mostly runs disk-heavy nested work, either lower the cap (which
  recovers IOPS host-wide at the price of more host CPU) or put the heaviest-IO
  VMs on the per-VM `--ovm-timer-guard` for the best disk scaling with no residual
  storm.
- If the kernel cannot be patched, the ovm-timer-guard is the per-VM fallback.

## Building with the guard

The guard is opt-in in the build script:

```bash
GUARD=1 KVM_RELAY_SRC=/path/to/linux-source ./build/kvm_patch_apply_hcall_relay.sh
```

It applies `patch/kernel-timer-guard-pve.patch` after the relay edits, then
builds `kvm.ko` + `kvm-intel.ko` as usual. Without `GUARD=1` the script builds
the relay only. The patch edits `arch/x86/kvm/hyperv.c` (the guard logic and the
two module params) and `arch/x86/include/asm/kvm_host.h` (the per-stimer guard
state in `struct kvm_vcpu_hv_stimer`).

## The mainline variant

The mainline form of this guard is an RFC against the KVM list, with the
corresponding patch on the `rfc-kernel-timer-guard` branch of:

  https://github.com/bitranox/linux-nested-vmbus-relay
