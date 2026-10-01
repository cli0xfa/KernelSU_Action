# ReSukiSU on mars: builds and boots, but `su` fails on inline hooks

Status as of 2026-10-01. Supersedes the pessimistic note in
`sukisu-5.4-incompatibility.md` about no modern fork being viable: ReSukiSU
**does** build and boot on this kernel. It just cannot install the one hook that
makes `su` work.

## What was achieved

CI run **36822162236** (`config/mars-miui14-resukisu.env`) completed with every
step green — the first modern KernelSU fork to compile for this device.

The ref matters: `ReSukiSU/ReSukiSU` at **`auto-hook`**, not `main`. On `main`
and `v4.2.0-rc3`, `CONFIG_KSU_MANUAL_HOOK` pulls in
`tools/manual_hook_check.mk`, which `$(error)`s unless `ksu_handle_execveat`,
`ksu_handle_faccessat` and friends already appear in `fs/exec.c`, `fs/open.c`
and `fs/stat.c` — i.e. unless the kernel source was already patched by hand.
`auto-hook` replaces that with `tools/auto_hook_detect.mk` and gates the hard
check behind `ifneq ($(CONFIG_KALLSYMS_ALL),y)`. This kernel sets
`CONFIG_KALLSYMS_ALL=y`, so the check is skipped.

`CONFIG_KSU_TRACEPOINT_HOOK` (ReSukiSU's own default) is not usable either: its
Kbuild `$(error)`s with *"TP hooks are incompatible with Non-GKI/GKI 1.0
kernels"*.

## Verified working, on the device

Booted with `fastboot boot` (RAM only; nothing written to disk, `boot_b` still
holds the v0.9.5 image).

| Check | Evidence |
| --- | --- |
| Kernel boots | `sys.boot_completed=1`, `uname -r` = `5.4.283-mars-g6cb9f5a9edc1` |
| ReSukiSU driver live | `KernelSU: Initialized on: 5.4.283-mars-g6cb9f5a9edc1 (aarch64) with driver version: 35075` |
| Auto-hook code ran | 29 `ksu_*` symbols in `/proc/kallsyms`, incl. `ksu_on_sys_{faccessat,newfstat,stat,fstat64,reboot}` |
| LSM hooks installed | `ksu_task_fix_setuid`, `ksu_inode_rename`, `ksu_file_permission` present and firing |
| Syscall table patched | `KernelSU: patch result=0` |
| Driver actively working | dmesg: continuous `handle_setresuid`, `renameat`, `boot not completed, skip prune` |
| Debug mode | `shell is allowed at init!` (the `CONFIG_KSU_DEBUG` auto-grant) |
| Display / touch / boot | normal; no regressions observed |

## What fails, and exactly why

All **7** inline hooks are rejected at boot:

```
ksu_hook_sys_reboot: sys_reboot target=ffffffd2da979eb0 (__arm64_sys_reboot+0x0/0x254)
inline_hook: reject non-text target=ffffffd2da979eb0 dispatcher=ffffffd2da68365c
ksu_hook_sys_reboot: failed to hook sys_reboot: -22
```

identical for `execve` (both the primary target and the `CONFIG_COMPAT`
`do_execve` fallback), `faccessat`, `newfstatat`, `newfstat` and `fstat64`.

`hook/inline_hook.c` gates every install on:

```c
if (!kernel_text_address((unsigned long)target) ||
    !kernel_text_address((unsigned long)config.dispatcher)) {
    pr_err("inline_hook: reject non-text target=%px dispatcher=%px\n", ...);
    return ERR_PTR(-EINVAL);
}
```

This kernel has `CONFIG_CFI_CLANG=y`, `CONFIG_CFI_CLANG_SHADOW=y` and
`CONFIG_LTO_CLANG=y`, so those functions are not inside a range
`kernel_text_address()` accepts, and the check returns `-EINVAL` every time.

**Why that specifically breaks root:** the `execve` hook is what rewrites
`/system/bin/su` → `/data/adb/ksud`. Without it, `su` has nothing to escalate
through. `/system/bin/su -c id` and `/data/adb/ksud su -c id` both fail, and the
`uid=0` that `su -c id` *does* return is **Magisk's**, not KernelSU's — its
SELinux context is `u:r:magisk:s0`, whereas KernelSU's is `u:r:su:s0` (which the
working v0.9.5 build does produce).

## Manager compatibility is not a problem

ReSukiSU hard-codes signatures for six managers
(`kernel/manager/manager_sign.h`), including `tiann/KernelSU`:

```
#define EXPECTED_SIZE_OFFICIAL 0x033b
#define EXPECTED_HASH_OFFICIAL "c371061b19d8c7d7d6133c6a9bafe198fa944e50c1b31c9d8daa8d7f1fc2d2d6"
```

The v0.9.5 manager already installed on this device matches that exactly
(verified by parsing the APK Signing Block v2 certificate: DER size 827 =
0x33b, SHA-256 identical), so no new APK is needed.

## Artifacts, verified before booting

| File | Size |
| --- | --- |
| `dist/mars-ReSukiSU-auto-hook-boot.img` | 74301440 |
| `dist/mars-ReSukiSU-auto-hook-Image` | 52765184 |

The boot image was built with `tools/make-bootimg.py` and checked: the kernel
region matches the CI `Image` byte-for-byte, the ramdisk is byte-identical to
stock, and the only header bytes changed are those of `kernel_size`.

## Options for making root work

### Option 3 is the promising one, and it is now scoped

Reading ReSukiSU's hook architecture shows there are **two independent syscall
mechanisms**, and only one of them is broken here:

| Mechanism | How it installs | Result on this kernel |
| --- | --- | --- |
| `ksu_syscall_table_hook(nr, fn)` | overwrites `sys_call_table[nr]` via `ksu_patch_text` | **works** — `patch result=0` |
| `ksu_inline_hook_register()` | rewrites the function prologue in place | **fails** — rejected as non-text |

`ksu_register_syscall_hook(nr, fn)` does **not** patch per-syscall entries. It
fills a routing table (`syscall_hooks[nr]`) and relies on a single shared
dispatcher, `ksu_syscall_dispatcher`, installed once into a spare `ni_syscall`
slot through `ksu_syscall_table_hook` — i.e. through the mechanism that works:

```c
/* arm64/syscall_hook.c */
ksu_syscall_table_hook(ksu_dispatcher_nr, (syscall_fn_t)ksu_syscall_dispatcher, NULL);
...
int ksu_register_syscall_hook(int nr, ksu_syscall_hook_fn fn) {
    WRITE_ONCE(syscall_hooks[nr], fn);   /* table not touched */
}
```

That dispatcher is generic over any `nr`. **`su` only fails because nothing
registers `__NR_execve` with it.** `syscall_hook_manager.c` registers
setresuid, execve, newfstatat and faccessat — but only `core/init.c`'s
`CONFIG_KSU_TRACEPOINT_HOOK` branch calls `ksu_syscall_hook_init()` +
`ksu_syscall_hook_manager_init()`. The `MANUAL_HOOK` branch (ours) calls
`ksu_auto_hook_init()` instead, which is the inline-hook path that cannot work
under CFI. And `TRACEPOINT_HOOK` is unusable because its Kbuild `$(error)`s on
GKI 1.0.

Crucially, **the execve su-handler needed for this already exists**, gated only
behind the tracepoint config:

```c
/* feature/sucompat.c */
#ifdef CONFIG_KSU_TRACEPOINT_HOOK
int ksu_handle_execve_sucompat_tp_internal(const char __user **filename_user,
                                           int orig_nr, const struct pt_regs *regs)
{
    ...
    if (likely(memcmp(path, su, sizeof(su)))) goto do_orig_execve;
    pr_info("sys_execve su found\n");
    *filename_user = ksud_user_path();
    ret = escape_with_root_profile();
    ...
    return ksu_syscall_table[orig_nr](regs);   /* the working call form */
}
#endif
```

So the minimal fix is to route `__NR_execve` (and `__NR_execveat`) through the
shared dispatcher in `MANUAL_HOOK` mode, reusing
`ksu_handle_execve_sucompat_tp_internal` — the same pattern `ksu_sys_read` and
`ksu_sys_fstat` already use successfully in this very build. That is a patch
against ReSukiSU's own source, not against the kernel, so it needs no hand-edited
kernel tree and no 5.4 hook-patch port.

Concretely:
1. Drop the `#ifdef CONFIG_KSU_TRACEPOINT_HOOK` guard on
   `ksu_handle_execve_sucompat_tp_internal` (and on its `syscall_event_bridge.c`
   caller), or add an equivalent caller for manual mode.
2. Call `ksu_syscall_hook_init()` in the `MANUAL_HOOK` branch of `core/init.c`,
   then `ksu_register_syscall_hook(__NR_execve, ksu_hook_execve)` and the
   `__NR_execveat` equivalent.
3. Leave `ksu_auto_hook_init()` in place for the hooks that can still install
   (the LSM ones already work: `ksu_task_fix_setuid` fires continuously in
   dmesg), and let the inline ones fail as they do now.

Not yet attempted; it is the next thing to try if a modern fork is still wanted.

### The other options

1. **Give the inline hooks a target that passes `kernel_text_address()`.** The
   check is about section placement, so the fix is to make the patched symbols
   land in real text — which is inherently what `CONFIG_CFI_CLANG` prevents for
   these functions.
2. **Port the hook patches for this tree.** ReSukiSU publishes
   `ReSukiSU_Patches`, but only `kernel-4.9`, `kernel-4.14`, `kernel-4.19` and
   the GKI ones — no 5.4 — so a 5.4 patch would have to be written.
   `KSU_HOOKS_AUTO_HOOKED=false` is already wired up to allow that.
4. **Stay on KernelSU v0.9.5**, which is flashed, verified and granting root
   (`u:r:su:s0`) right now. v0.9.5 works because it hooks via **kprobes**, which
   the kernel supports natively and which is unaffected by CFI section
   placement — the same reason `CONFIG_KSU_HOOK_MODE=kprobes` was the right
   choice for it.

`CONFIG_CFI_PERMISSIVE` is `not set` on this kernel; note it would not help,
since the rejection is a section-placement test in KernelSU's own sanity check,
not a CFI trap at runtime.

## The broader lesson

`CONFIG_CFI_CLANG=y` + `CONFIG_LTO_CLANG=y` makes in-place function-prologue
hooking unreliable, because `kernel_text_address()` no longer covers the
functions being patched. Any KernelSU fork that relies on **inline hooks** will
hit this on such a kernel; kprobes and syscall-table dispatch both avoid it.
That is the discriminator to check first when picking a fork for this device,
and it is worth stating in the device profile.

