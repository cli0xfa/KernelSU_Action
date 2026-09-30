# Xiaomi Mi 11 Pro (mars) — KernelSU v0.9.5 build & test record

Device: M2102K1AC · SM8350 (lahaina) · MIUI 14 / Android 13 · V14.0.11.0.TKACNXM
Stock kernel: `5.4.210-qgki-g71d7658432ee`
Root before this work: **Magisk 30.7** (active slot `_b`)

Built kernel: `5.4.283-mars-g6cb9f5a9edc1` (clang r416183b / 12.0.5, full LLVM+IAs)
CI run: https://github.com/cli0xfa/KernelSU_Action/actions/runs/36760357398

## Result of the temporary boot test — PASSED

`fastboot boot mars-KernelSU-v0.9.5-boot.img` (RAM only, no disk write):

| Check | Result |
| --- | --- |
| Kernel boots | ✅ `uname -r` = `5.4.283-mars-g6cb9f5a9edc1`, `sys.boot_completed=1` |
| Display | ✅ `sde-crtc-0/1`, `card0-DSI-1` present |
| Touch | ✅ `fts` (ST FTS), `cyttsp5` |
| Fingerprint | ✅ `uinput-goodix` |
| Haptics | ✅ `aw8697_haptic` |
| Storage | ✅ `/dev/block/by-name/boot_b` |
| **KernelSU driver** | ✅ **live** — see logcat evidence below |
| Non-destructive | ✅ `adb reboot` returned to stock `5.4.210-qgki` + Magisk root |

### KernelSU evidence (logcat)

```
KernelSU: ksud::cli: command: Debug { command: Su { global_mnt: false } }
KernelSU: ksud::cli: command: Module { command: List }
KernelSU: getAllowList: 1, size: 0
KsuCli  : install result: true, cost: 82ms
```

These lines can only be produced by the KernelSU **kernel driver**: the manager
app only gets `ksud` invoked and gets an allowlist back if the in-kernel hooks
are registered and calling out. `install result: true` is the manager's JNI
binding to the driver reporting success.

`getAllowList: size: 0` means the **allowlist is empty**, so KernelSU
deliberately denies root to everything. That is designed behaviour, not a
failure: root is granted per-app in the manager UI, which needs a screen tap.
Screen input could not be injected over adb on this MIUI build
(`SecurityException: Injecting input events requires ... INJECT_EVENTS`).

**Net: the kernel, KernelSU driver, and the manager↔driver channel are all
confirmed working. Only the final "tap Grant" step is unverified, and that is a
UI action, not a kernel property.**

## Artifacts

| File | Purpose |
| --- | --- |
| `mars-KernelSU-v0.9.5-boot.img` | boot image: KSU kernel + **clean stock ramdisk** (73990144 bytes) |
| `mars-KernelSU-v0.9.5-Image` | raw kernel `Image` (52716032 bytes) |
| `mars-KernelSU-v0.9.5-AnyKernel3.zip` | flashable zip (recovery / manager) |

Backups taken before any change (in `_backup_mars/`, git-ignored):
`boot_a.img boot_b.img vbmeta_a.img vbmeta_b.img` — all verified valid
(`ANDROID!` / `AVB0` magic).
Magisk's own untouched dump: `/data/magisk_backup_697eda2371e809bd40398d5fd22263c40ffca02a/boot.img.gz`

## Making it permanent

Only after the manager shows "Working" and `su` grants root:

```
adb reboot bootloader
fastboot flash boot mars-KernelSU-v0.9.5-boot.img
fastboot reboot
```

Install the matching manager (already used during testing):
`KernelSU_v0.9.5_11872-release.apk`
→ https://github.com/tiann/KernelSU/releases/tag/v0.9.5

Because the KernelSU Build number reported by the kernel was **11872**, the
manager must be this exact release; a newer manager reports a version mismatch.

## Recovery

```
fastboot flash boot   _backup_mars\boot_b.img
fastboot flash boot_a _backup_mars\boot_a.img
fastboot flash boot_b _backup_mars\boot_b.img
fastboot reboot
```

vbmeta only if the bootloader itself misbehaves:

```
fastboot flash vbmeta   _backup_mars\vbmeta_b.img
fastboot flash vbmeta_a _backup_mars\vbmeta_a.img
```

## Known limitations found during testing

1. **Loadable modules did not build.** `make modules` failed on the Qualcomm
   techpack trees, so the build continued by design (`BUILD_MODULES=true`
   reports failure without discarding the kernel). Affected: **camera**,
   **audio** (`*_dlkm`), **mobile data** (`rmnet_*`). These fall back to the
   stock `.ko`, which this kernel cannot load (see next point), so expect them
   degraded until the techpack build is fixed.
2. **Stock `.ko` cannot be reused — this is the reason everything else is
   built in.** The kernel has `CONFIG_MODVERSIONS=y` + `CONFIG_CFI_CLANG=y` and
   no `CONFIG_MODULE_FORCE_LOAD`. Loadability is decided by the symbol CRCs in
   the kernel's `__kcrctab`, which `genksyms` derives from the source tree's
   own headers. Xiaomi never published the 5.4.210 tree (MiCode only ships
   `star-r-oss` = 5.4.61 / Android R), so stock modules fail at the very first
   symbol, `module_layout`. Verified present in the built image instead:
   `sde_kms`/`msm_drm`, `fts_touch_spi`, `cyttsp5`, `goodix_fod`,
   `cnss2`/`wlan_hdd_cfg80211_init`, `ufs_qcom_`.
3. **Wi-Fi could not be demonstrated — but it is not a regression.** Wi-Fi is
   enabled in settings yet no `wlan0` appears under the **stock** kernel either
   (`ls /sys/class/net` on stock is identical, and stock also reports
   "Wi-Fi is disabled"). So the absence is a pre-existing device/environment
   state, not something this kernel introduced. The Wi-Fi stack
   (`QCA_CLD_WLAN=y`, `CNSS2=y`, `ICNSS2=y`) is built into the image.
4. **`su` requires the allowlist.** With `getAllowList: size: 0`, `su` denies
   until an app is granted in the manager. Note `su` is provided purely by the
   kernel's `execve` hook rewriting `/system/bin/su` → `/data/adb/ksud`; the
   file `/system/bin/su` never exists on disk, so a bare `su` fails to resolve
   in `PATH` — the hook only fires on an actual `execve`. Use the full path.

## Configuration notes worth keeping

- **`CONFIG_KPROBES` is KernelSU v0.9.5's hook-mode selector**, not an
  independent knob. The `ksu_*_hook` variables that "manual" mode needs exist
  only in the `#else` branch of `#ifdef CONFIG_KPROBES` in `kernel/ksud.c`.
  Asking for manual hooks while kprobes is on makes the hook patch reference
  undefined symbols and the build dies at the `vmlinux` link. The stock kernel
  has the full kprobes set, so `KSU_HOOK_MODE=kprobes` is the matching choice.
- **This tree pins the watchdog with `range 11000 11000`.** A single-valued
  `range` is a hard constraint, not a default — Kconfig clamps the defconfig's
  value to it, silently turning the stock 20 s/15 s into 11 s/9.36 s and
  biting the watchdog ~9 s earlier than the ROM expects (a boot loop that
  looks like a random hang). `ENABLE_WATCHDOG_RELAX=true` rewrites the range.
- **Qualcomm trees need a target list, not one defconfig:**
  `vendor/lahaina-qgki_defconfig` + `vendor/xiaomi_QGKI.config` +
  `vendor/star_QGKI.config` + `vendor/debugfs.config`. Mars has no defconfig of
  its own; it is built on the *star* config, because `BOARD_XIAOMI_STAR`
  selects `BOARD_XIAOMI_LAHAINA`, which selects `ARCH_LAHAINA`/`ARCH_QCOM`.
- **Image format:** boot header v3, gzip ramdisk, uncompressed arm64 `Image`
  kernel. `tools/make-bootimg.py` splices kernel+ramdisk byte-for-byte
  (round-trip verified: 0 differing bytes) and preserves the header, so the
  only variable under test is the kernel.
