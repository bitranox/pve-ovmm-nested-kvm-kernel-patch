# Matching Proxmox kernel source per version

This repo ships the relay as a patch plus a build script, not as a vendored
kernel tree. To build the modules you need the same Proxmox kernel source the
running kernel was built from. Proxmox does not host the full per-version source
on GitHub: the `proxmox/pve-kernel` GitHub repo is only a read-only mirror of the
packaging tree (Makefile, `debian/`, `patches/kernel/*.patch`), and the actual
Linux source lives in a git submodule (`submodules/ubuntu-kernel`) that points at
an Ubuntu kernel mirror. So the source is reconstructed from two pinned commits
plus the Proxmox patch set, as the pve-kernel `Makefile` does.

The relay's edits are anchored text insertions, so one patch tracks several point
releases as long as the anchor lines hold. The table records which kernels each
revision was prepared and checked against.

## Pins

| pve kernel       | pve-kernel commit | submodules/ubuntu-kernel commit            | Ubuntu base        |
|------------------|-------------------|--------------------------------------------|--------------------|
| 7.0.2-7-pve      | `b1a2549`         | `69bb061d`                                 | Ubuntu-7.0.0-18.18 |
| 7.0.6-2-pve      | `f109f2b`         | `148c038ca663f09720ebdaa77e5c63d0e8da4573` | Ubuntu-7.0.0-26.26 |

The 7.0.6-2 base is Ubuntu-7.0.0-26.26, verified from the submodule commit itself
(`148c038c` is tagged `UBUNTU: Ubuntu-7.0.0-26.26`). Do not confuse it with the
7.0.6-1 base, Ubuntu-7.0.0-21.21 (`bc624d38`), which is a different commit. Always
read the pin from the pve-kernel tree (`git ls-tree`), not from the changelog
wording, since a single pve-kernel changelog entry can describe several steps.

The pve-kernel commit is the one that bumps the version (its `debian/changelog`
top entry is the target kernel). Its tree pins the exact `submodules/ubuntu-kernel`
commit; read it with `git ls-tree <pve-commit> submodules/ubuntu-kernel`.

## Reconstructing a source tree

```bash
# 1. the packaging tree
git clone https://git.proxmox.com/git/pve-kernel.git
cd pve-kernel
git checkout <pve-kernel commit>          # e.g. f109f2b for 7.0.6-2-pve

# 2. the Ubuntu kernel base it pins (large fetch; the proxmox mirror does a full
#    clone, partial-clone filters are ignored server-side)
git submodule update --init submodules/ubuntu-kernel

# 3. lay down the patched source the way the pve-kernel Makefile's *.prepared
#    target does: copy the submodule out, drop its debian/ dirs, apply the
#    proxmox patch set with patch -p1.
SRC=proxmox-kernel/ubuntu-kernel
mkdir -p proxmox-kernel
cp -a submodules/ubuntu-kernel "$SRC"
rm -rf "$SRC/debian" "$SRC/debian.master"
( cd "$SRC" && for p in ../../patches/kernel/*.patch; do patch --batch -p1 < "$p"; done )
```

`$SRC` now has a full `arch/x86/kvm/` with the Proxmox patches applied. Point the
build script at it:

```bash
KVM_RELAY_SRC="$PWD/$SRC" ./build/kvm_patch_apply_cap.sh
```

The build script copies `/boot/config-$(uname -r)` and the matching
`Module.symvers` from the installed headers, runs `make modules_prepare`, and
builds only `kvm.ko` + `kvm-intel.ko`.

## Notes per version

`7.0.6-2-pve` carries a larger KVM patch set than `7.0.2-7-pve` (an MBEC/GMET MMU
rework, patches `0019`-`0048`). One of them,
`0032-KVM-x86-make-translate_nested_gpa-vendor-specific.patch`, moves
`translate_nested_gpa` behind `kvm_x86_ops.nested_ops->translate_nested_gpa`,
which is the exact call the relay's `hyperv.c` edit uses, so the relay matches
that tree. The relay anchors (`trace_kvm_nested_vmexit` in `nested.c`, the
`kvm_hv_hypercall_read_xmm` / `switch (hc.code)` block in `hyperv.c`, the
`KVM_CAP_SPLIT_IRQCHIP` define in `kvm.h`, the `struct kvm_arch` opener) are
unchanged by the Proxmox patches.
