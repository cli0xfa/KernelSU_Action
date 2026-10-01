# SukiSU-Ultra on Linux 5.4 — why it cannot build on Mi 11 Pro (mars)

Investigated 2026-10-01. Driver refs tested: `main` (HEAD 7fbbb1f) and `v4.2.0`.
Target: `EndCredits/android_kernel_xiaomi_sm8350-miui` @ `ASB-2024-10-05`
(SM8350, MIUI 14 / Android 13, kernel 5.4.210 → built as 5.4.283).

## Outcome

**Not viable.** The problem is not a handful of missing headers. SukiSU-Ultra
has **no pre-5.10 SELinux code path at all**, and that is structural.

CI evidence: run 36816582027 failed at
`drivers/kernelsu/feature/sucompat.c:106` with
`implicit declaration of strncpy_from_user_nofault` — i.e. it had already got
past the include fixes and died on the first renamed API.

## Blockers found, in the order the compiler hits them

All verified against the real 5.4 tree, not inferred.

### 1. `<linux/pgtable.h>` — split out of `asm/pgtable.h` in 5.8
Used by `feature/sucompat.c`. Tree has only `arch/arm64/include/asm/pgtable.h`.
Nothing in that file needs it (`kern_path`/`path_put` come from `namei.h`/`path.h`).
**Fixed** — `ksu_fix_legacy_includes()`.

### 2. `<linux/hex.h>` — added in 5.9
Used by `manager/apk_sign.c` for `bin2hex()`, which lived in `linux/kernel.h`
before. **Fixed** — same function.

### 3. `strncpy_from_user_nofault()` — renamed in 5.8
`strncpy_from_unsafe_user()` renamed by commit `bd88bb5d4007`. Identical
signature and pagefault-disabled semantics. 5.4 has only the old name.
**Fixed** — compat macro in a generated force-included header.

### 4. `copy_to_kernel_nofault()` / `copy_from_kernel_nofault()`
5.8 renames of `probe_kernel_write()` / `probe_kernel_read()`. Used by
`hook/arm64/patch_memory.c:150`. 5.4 `mm/maccess.c` has only the `probe_*` names.
**Not fixed** (would be the same shim treatment).

### 5. `TWA_RESUME` — enum `task_work_notify_mode` added in 5.8
5.4 `task_work_add(task, work, bool notify)`. Commit `91989c70`. `TWA_RESUME`
maps exactly onto the old `true`; `TWA_SIGNAL` has no pre-5.8 equivalent.
Used at `policy/allowlist.c:472`, `supercall/supercall.c:98`.
**Fixed** — compat macro.

### 6. `selinux_state.policy` / `.policy_mutex` — **only exist from 5.10**
This is the fatal one. Verified by reading upstream headers at v5.4…v5.10:

| kernel | `struct selinux_policy *policy` | `policy_mutex` |
| --- | --- | --- |
| v5.4 – v5.8 | absent | absent |
| v5.10 | present | present |

In this 5.4 tree `struct selinux_state` is only:

```c
struct selinux_state {
    bool disabled; bool enforcing; bool checkreqprot; bool initialized;
    bool policycap[__POLICYDB_CAPABILITY_MAX];
    bool android_netlink_route; bool android_netlink_getneigh;
    struct selinux_avc *avc;
    struct selinux_ss  *ss;
};
```

`policy`/`policy_mutex` never existed in the flat struct before 5.10; what
exists is `ss->policydb` and `ss->policy_rwlock`. Same for `status_page` /
`status_lock`, which live in `struct selinux_ss` here and are reached through
the accessor `selinux_kernel_status_page(state)`.

SukiSU-Ultra accesses all of these **unguarded**:
- `selinux/rules.c:47,54,56,78` — `selinux_state.policy`, `.policy_mutex`
- `feature/selinux_hide.c:252,255,260,296,305,307,520,524` — `.status_lock`, `.status_page`

Its `rules.c` does `#define SELINUX_POLICY_INSTEAD_SELINUX_SS`, but grep shows
that macro is **defined and never used** anywhere in the tree — dead code. There
is no `KSU_COMPAT_HAS_SELINUX_STATE`/`KSU_COMPAT_USE_SELINUX_STATE` either.

`selinux/rules.c` and `feature/selinux_hide.c` are compiled unconditionally
(`kernelsu-objs += ...` with no gate), so these are hard compile errors.

## Why the working fork works and this one does not

`tiann/KernelSU` v0.9.5 — the build already flashed and verified on this device
— carries exactly the layer SukiSU-Ultra dropped:

```c
/* kernel/selinux/selinux.h */
#if (LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)) || defined(KSU_COMPAT_HAS_SELINUX_STATE)
#define KSU_COMPAT_USE_SELINUX_STATE
#endif
```

with `#ifdef KSU_COMPAT_USE_SELINUX_STATE ... #else db = &policydb;` fallbacks
throughout `rules.c` / `selinux.c` / `sepolicy.c`. On 5.4 the macro is unset, so
the code uses the kernel's global `policydb` / `selinux_enforcing` directly —
which is why it compiles and runs.

## The fork that does support 5.4: ReSukiSU

`github.com/ReSukiSU/ReSukiSU` @ `main` is the same lineage but built for old
kernels. It has everything SukiSU-Ultra lacks:

1. **The pre-5.10 SELinux path.** `selinux/rules.c` gates on
   `KSU_COMPAT_HAS_POLICY_MUTEX` and falls back to
   `write_unlock_irq(ksu_policy_rwlock_ptr)`; `selinux/selinux.h` has the
   `KSU_COMPAT_USE_SELINUX_STATE` logic; `feature/selinux_hide.c`,
   `selinux/rules.c`, `selinux/sepolicy.c` all carry the guards (12 + 11 + 2
   references).
2. **A compat shim layer** in `compat/kernel_compat.c`, e.g.
   `ksu_strncpy_from_user_nofault()` with a real fallback chain
   (≥5.8 native / ≥5.3 `strncpy_from_unsafe_user` / else a copied 4.9
   implementation), a `path_mount()` backport for <5.9, `__kvmalloc()` for <4.12.
3. **No hard `depends on KPROBES`**, and `CONFIG_KSU_SUSFS` is a normal
   `bool` defaulting off with `depends on THREAD_INFO_IN_TASK && 64BIT` — and
   `THREAD_INFO_IN_TASK=y` on this kernel — so no SUSFS patch is required.
4. Same runtime hooking as SukiSU-Ultra `main` (kretprobe +
   `sys_call_table` patching), so still **no kernel source patches**.

The repo already has a `resukisu` registry entry pointing at `main`.

## What was changed in this repo anyway (all verified, none SukiSU-specific)

- `ksu_fix_legacy_includes()` — drops `pgtable.h` / `hex.h` only when the tree
  being built actually lacks them; verified idempotent and verified it leaves
  both files alone when the headers exist.
- `ksu_fix_legacy_symbols()` — generates
  `kernel/include/ksu_legacy_compat.h` and force-includes it via
  `ccflags-y += -include $(KSU_KERNEL_DIR)/include/...`, providing
  `strncpy_from_user_nofault` and `TWA_RESUME`. `TWA_SIGNAL` is deliberately
  *not* defined so an unsupported use fails loudly instead of silently changing
  task_work semantics.
- A `runtime` hook mode, so a variant that hooks at runtime is not treated as
  `manual` (which would run the legacy source patches and fail to link, since
  these forks do not define the old `ksu_handle_*` symbols).
- `hooks_patch_apply()` no longer uses SukiSU's `hooks/syscall_hooks.patch`:
  every call it injects is gated on `CONFIG_KSU_MANUAL_HOOK`, a symbol
  SukiSU-Ultra never declares, so it would compile out to a silently rootless
  kernel.
- Config profiles gained `INCLUDE=` and `KERNEL_REQUIRED_CONFIG_EXTRA=`, so
  `config/mars-miui14-sukisu.env` overrides ~6 keys instead of duplicating 240
  lines of device config.
- `verify_required_config()` can now assert a disabled symbol (`# CONFIG_X is
  not set`), which it previously could not.

These are generic improvements; the include/symbol repair is what any modern
fork needs on 5.4.

## Recommendation

Switch `KSU_VARIANT` to `resukisu` rather than continuing to hand-port
SukiSU-Ultra's SELinux layer, which means reimplementing a compat path that
ReSukiSU already maintains. Keep the `KSU_HOOK_MODE=runtime` and compat-header
machinery, since ReSukiSU benefits from the same treatment.

Note ReSukiSU's own hook-mode default on 5.4 still needs checking: if it also
expects `KSU_MANUAL_HOOK` on old kernels, `runtime` must be selected explicitly
for the same reason.
