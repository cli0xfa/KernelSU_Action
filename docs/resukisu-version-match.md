# Matching the ReSukiSU manager version: what was tried and what it cost

## The version mechanism (verified)

ReSukiSU derives its driver version from the **commit count of whatever ref is
checked out** (`kernel/Kbuild`):

```makefile
KSU_LOCAL_VERSION := $(shell cd $(KSU_SRC); git rev-list --count HEAD)
KSU_VERSION       := $(shell expr 30000 + $(KSU_LOCAL_VERSION) + 700)
```

and reports it to the manager through `do_get_info` as
`KERNEL_SU_VERSION` (= `KSU_VERSION`). The manager compares that with its own
build number; a mismatch shows the "kernel needs update" notice.

Measured against the real repository (full clone, not shallow):

| Ref | Commits | `30000 + n + 700` |
| --- | --- | --- |
| `auto-hook` branch | 4375 | **35075** |
| `v4.2.0-rc3` tag | 4471 | **35171** |

The manager is `v4.2.0-rc3 (35171/4)`, so building the **tag** makes the numbers
match exactly. CI run **36852266515** confirmed it:

```
-- ReSukiSU version code: 35171
-- ReSukiSU version name: v4.2.0-rc3-239e1e88-dirty@ReSukiSU
-- ReSukiSU TP Hooks on GKI 1.0: enabled by patch
[+] ReSukiSU installed at v4.2.0-rc3 (239e1e88)
```

The build completed with every step green, and the resulting `Image` is the same
size as the working `auto-hook` one (52765184 bytes).

## But the v4.2.0-rc3 kernel does not boot

`fastboot boot mars-ReSukiSU-rc3-boot.img` was accepted by the bootloader
("Sending ... OKAY / Booting OKAY") and then the device fell through to MIUI
Recovery instead of booting. It never reached `sys.boot_completed`, and ADB only
ever showed `offline`, then `unauthorized` (recovery's own ADB).

So the tag builds but is not bootable on this device, while the `auto-hook`
branch is both buildable and bootable (verified earlier: `su` returns
`uid=0 root`, `context=u:r:ksu:s0`).

Difference in what gets compiled — both take the tracepoint branch, but:

| | `auto-hook` | `v4.2.0-rc3` |
| --- | --- | --- |
| `hook/inline_hook.o`, `hook/auto_hook.o` | yes | **absent** |
| `feature/module_load_filter.o` | absent | **yes** |

`feature/module_load_filter.o` is the notable addition; it hooks module loading,
which on a 5.4 kernel may not have the internals it expects even though it
compiles. That is the most likely candidate for the boot failure and is worth
checking first if this path is revisited.

**Nothing was written to disk** — `fastboot boot` loads into RAM only, so
`boot_b` still holds the working `auto-hook` ReSukiSU kernel
(`dist/mars-ReSukiSU-tp-small.img`).

## Where this leaves the version question

The two goals conflict on this device:

* **Working root** requires the `auto-hook` branch, whose driver reports 35075.
* **Matching the manager** requires the `v4.2.0-rc3` tag, which reports 35171 but
  does not boot here.

Options, none yet tested:

1. **Keep `auto-hook` and accept the notice.** The mismatch is cosmetic in
   practice: the manager still shows "工作中 / Built-in", lists superusers and
   modules, and the kernel/manager fd channel works (`install fd for ksu
   manager(uid=10274)`). This is the state the device was left in and it is
   fully functional.
2. **Keep `auto-hook` and override the version.** `KSU_VERSION` is just a
   `ccflags-y += -DKSU_VERSION=...` define, so the build can pass an explicit
   value (e.g. 35171) without changing the code. This gets an exactly matching
   version *and* a kernel that boots — the cleanest fix if the notice matters.
3. **Find why v4.2.0-rc3 does not boot** and fix that instead — most likely by
   disabling `feature/module_load_filter.o` or the config that pulls it in.
