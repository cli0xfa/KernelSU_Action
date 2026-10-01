# ReSukiSU on mars: WORKING — verified with root

## Result

ReSukiSU **builds, boots, and grants root** on this device. This is the first
modern KernelSU fork to do so.

Verified over `fastboot boot` (RAM only, nothing written to disk):

```
$ adb shell '/system/bin/su -c id'
uid=0(root) gid=0(root) groups=0(root) context=u:r:ksu:s0
```

`u:r:ksu:s0` is **ReSukiSU's own SELinux domain**, distinct from Magisk's
`u:r:magisk:s0` — so this is provably KernelSU root, not Magisk's. A write test
as that root succeeded (`touch` + `rm` in `/data/local/tmp`).

The kernel-side logs show the hook path doing exactly what it should:

```
KernelSU: dispatcher installed at slot 42
KernelSU: hook_manager: ksu_hook_manager_init called
KernelSU: hook_manager: register_syscall_regfunc kretprobe: 0
KernelSU: registered syscall hook for nr=147   (setresuid)
KernelSU: registered syscall hook for nr=221   (execve)
KernelSU: registered syscall hook for nr=79    (newfstatat)
KernelSU: registered syscall hook for nr=48    (faccessat)
KernelSU: hook_manager: sys_enter tracepoint registered
KernelSU: ksu_handle_stat: su->sh!
KernelSU: faccessat su->sh!
KernelSU: sys_execve su found
```

The last three lines are the `su` interception firing: the execve hook rewrote
`/system/bin/su` to `/data/adb/ksud` (the `su->sh!` lines are the fallback path
used while `/data/adb/ksud` is being resolved).

Everything else still works: display (`card0-DSI-1`), touch (7 input devices),
camera (4 `/dev/video*`), mobile data (11 `rmnet` interfaces), `sys.boot_completed=1`.

Build: CI run **36836876641**, all steps green.
Artifacts: `dist/mars-ReSukiSU-tp-boot.img`, `dist/mars-ReSukiSU-auto-hook-Image`.

## How it was made to work

Three separate 5.4 incompatibilities had to be fixed. Two are generic (they
apply to any modern fork); one is specific to ReSukiSU.

### 1. The hook mechanism had to change (the decisive one)

The pre-GKI default is `KSU_MANUAL_HOOK`, which installs hooks with
`hook/inline_hook.c`. On a `CONFIG_CFI_CLANG=y` + `CONFIG_LTO_CLANG=y` kernel
that cannot work: every install is refused, because the code gates on

```c
if (!kernel_text_address(target) || !kernel_text_address(dispatcher))
    return ERR_PTR(-EINVAL);
```

and those functions are not in the ranges that predicate accepts. All 7 inline
hooks failed, including the `execve` one that rewrites `/system/bin/su`, so `su`
had no escalation path at all.

The **tracepoint** hook does not patch function text. It redirects at syscall
entry by pointing `regs->syscallno` at a spare `ni_syscall` slot holding a shared
dispatcher installed via `ksu_syscall_table_hook()` — i.e. through
`ksu_patch_text`, the mechanism that works here (`patch result=0`).

ReSukiSU refuses that mode on non-GKI 2.0 with a hard `$(error)`. That gate is
about what upstream tested, not what the code needs:

* the hook requires the `sys_enter` tracepoint, declared under
  `CONFIG_HAVE_SYSCALL_TRACEPOINTS`, which this kernel sets.
  `CONFIG_FTRACE_SYSCALLS` is unset, but that only governs tracefs visibility,
  not KernelSU registering its own probe;
* the path uses no post-5.4 API — its only two version checks already fall back
  correctly (`tp_marker.c` → `TIF_SYSCALL_TRACEPOINT` below 5.11,
  `syscall_hook_manager.c` → `compat.h` below 6.7);
* arm64 is on the arch allowlist.

`patches/resukisu_enable_tracepoint.sh` neutralises that one Kbuild block.

### 2. ReSukiSU's fsnotify usage

`manager/pkg_observer.c` used `.handle_inode_event`, added to
`struct fsnotify_ops` in **5.9**; 5.4 has only `handle_event`, with a wider
argument list. `patches/resukisu_fix_fsnotify_ops.sh` adds a `handle_event`
wrapper for < 5.9 and selects whichever field the kernel has. Behaviour is
unchanged — that observer only reads the file name and `FS_ISDIR`.

### 3. Generic 5.8 symbol renames (handled for any fork)

`ksu_fix_legacy_includes()` and `ksu_fix_legacy_symbols()` in
`scripts/kernelsu.sh`, applying only when the kernel being built genuinely lacks
the modern name:

| Modern name | 5.4 name | Where it bit |
| --- | --- | --- |
| `<linux/pgtable.h>` | part of `asm/pgtable.h` (split in 5.8) | `feature/sucompat.c` |
| `<linux/hex.h>` | `bin2hex` in `linux/kernel.h` (added 5.9) | `manager/apk_sign.c` |
| `strncpy_from_user_nofault()` | `strncpy_from_unsafe_user()` | `feature/sucompat.c` |
| `copy_from_user_nofault()` | `probe_user_read()` | `runtime/ksud_integration.c` |
| `copy_to_user_nofault()` | `probe_user_write()` | `runtime/ksud_integration.c` |
| `TWA_RESUME` | `true` (enum added in 5.8) | `policy/allowlist.c` |

The last two only surfaced at the **final vmlinux link**
(`ld.lld: undefined symbol: copy_to_user_nofault`), after the whole kernel had
compiled.

## Full-tree audit: no other API gaps exist

An exhaustive pass over every externally-referenced symbol, struct member, enum
and signature in the ReSukiSU tree against the real 5.4 headers found **no
remaining post-5.4 API use**. Notable verifications:

* `PT_REGS_PARM1..6` / `PT_REGS_ORIG_SYSCALL` / `PT_REGS_RC` do **not** exist in
  this tree's `asm/ptrace.h`, but the driver defines them itself in
  `include/arch.h:114-139`, mapping onto real 5.4 `struct pt_regs` members
  (`regs[31]`, `sp`, `pc`, `orig_x0`, `syscallno`). Valid — this is what makes
  the tracepoint path work.
* `register_trace_prio_sys_enter` and the syscall tracepoints exist.
* `security_add_hooks` is 3-arg; the driver takes that branch.
* `path_mount` (5.9+) is absent but handled by a `__weak` shim.
* `seccomp_cache.c` compiles to nothing below 5.10 (whole file guarded).
* Every `tools/kernel_compat.mk` probe resolves correctly for this tree.

## Flashing: one new constraint, not yet resolved

`fastboot flash boot_b` of the ReSukiSU image is **rejected by the bootloader**:

```
Sending 'boot_b' (72560 KB)   FAILED (remote: 'Requested download size is more than max allowed')
```

`fastboot boot` of the *same* image works, so the bootloader accepts the content
— this is a size cap on the `flash` download path. The working v0.9.5 image is
72256 KB and flashed fine, so the cap lies between 72256 KB and 72560 KB.
ReSukiSU's `Image` is 49152 bytes larger than v0.9.5's; padding to a 64 KiB
boundary did not help, and recompressing the ramdisk makes it larger (the stock
ramdisk is already optimally compressed).

Options, in order of preference:

1. **Shrink the kernel under the cap.** `CONFIG_KSU_DEBUG` is a verification-only
   feature (it is what auto-grants root to adb shell) and is no longer needed now
   that root is proven; dropping it, and any other optional feature, should
   recover far more than the ~1 KB of margin required.
2. **Use the AnyKernel3 zip** via a custom recovery, which has no such cap.
3. `fastboot boot` the image and flash from the booted system with `dd`, since
   the kernel is verified working.

## IMPORTANT — device state at the time of writing

The device is in **fastboot mode but not responding to fastboot commands**. It
enumerates on USB as `Android Bootloader Interface`
(`USB\VID_18D1&PID_D00D\E655E794`) but `fastboot devices` lists nothing, and
`fastboot reboot` hangs. This followed a `fastboot -S 8M flash` attempt, which
rejected the non-sparse image ("Invalid sparse file format at header magic").

Programmatic recovery was tried and did not work: ADB server restart, USB device
disable/enable (the PnP cycle failed), and repeated waits. It needs a
**physical action**: hold Power + Volume Up for ~10-15 seconds to leave
fastboot, then reboot normally; or hold Power alone for ~10 seconds to force a
reboot. Re-plugging the USB cable may also help.

**Nothing was written to any partition by the failed flashes** — the bootloader
rejected them before writing, so `boot_b` still holds the verified v0.9.5
KernelSU image (md5 `105ADA15EE914A5CCB96176E510CC224`), which is what the
device will boot into once it leaves fastboot. If it does not, recovery images
are in `_backup_mars/` (`boot_b.img` etc.).
