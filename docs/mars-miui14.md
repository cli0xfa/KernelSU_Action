# Xiaomi Mi 11 Pro (mars) — KernelSU v0.9.5 build & test record

Device: M2102K1AC · SM8350 (lahaina) · MIUI 14 / Android 13 · V14.0.11.0.TKACNXM
Stock kernel: `5.4.210-qgki-g71d7658432ee`
Root before this work: **Magisk 30.7** (active slot `_b`)

Built kernel: `5.4.283-mars-g6cb9f5a9edc1` (clang r416183b / 12.0.5, full LLVM+IAs)
CI run: https://github.com/cli0xfa/KernelSU_Action/actions/runs/36760357398

## Status: DONE — flashed to `boot_b` and root verified working

| Check | Result |
| --- | --- |
| Kernel boots | ✅ `uname -r` = `5.4.283-mars-g6cb9f5a9edc1`, `sys.boot_completed=1` |
| **KernelSU root** | ✅ **`su -c id` → `uid=0(root)`, context `u:r:su:s0`** |
| SELinux | ✅ `Enforcing` (KernelSU's own `su` domain) |
| Display | ✅ `sde-crtc-0/1`, `card0-DSI-1` |
| Touch | ✅ `fts` (ST FTS), `cyttsp5` |
| Fingerprint | ✅ `uinput-goodix` |
| Haptics | ✅ `aw8697_haptic` |
| Camera | ✅ 4 × `/dev/video*` |
| Audio | ✅ 66 PCM devices under `/sys/class/sound` |
| Mobile data | ✅ 11 × `rmnet*` interfaces |
| Storage | ✅ `/dev/block/by-name/boot_b` |
| Root write test | ✅ created and removed a file in `/data/local/tmp` as root |
| Non-destructive first | ✅ `fastboot boot` returned to stock `5.4.210-qgki` + Magisk |

Root comes from KernelSU, not Magisk: the SELinux context is `u:r:su:s0`
(KernelSU's domain), whereas Magisk's is `u:r:magisk:s0`.

### How the allowlist was seeded

The manager UI grants root per-app, but screen input cannot be injected over adb
on this MIUI build (`SecurityException: ... requires INJECT_EVENTS`), and the
allowlist was empty (`getAllowList: 1, size: 0`), so `su` correctly denied
everything. The entry was therefore written directly to
`/data/adb/ksu/.allowlist`, matching the kernel's ABI exactly
(`kernel/allowlist.c`, `kernel/ksu.h`):

```
magic   0x7f4b5355   version 3   (file header)
then N × struct app_profile (776 bytes each)
```

Two fields are load-bearing, and getting either wrong makes the entry **silently
ignored** (`profile_valid()` returns false and the record is dropped):

| Field | Required | Why |
| --- | --- | --- |
| `version` | `>= KSU_APP_PROFILE_VER` = **2** | `profile_valid()` rejects anything lower |
| `rp_config.profile.selinux_domain` | **non-empty** | also checked by `profile_valid()` |

`rp_config.use_default = true` then makes `ksu_get_root_profile()` return the
kernel's built-in profile (uid 0, gid 0, full capabilities, `u:r:su:s0`); that
switch is consulted only *after* validation, so the domain still has to be
filled in even though its value is not used in that path.

Once a matching UID is allowlisted, the execve kprobe rewrites the path
`/system/bin/su` → `/data/adb/ksud` and calls `escape_to_root()`. This is why
`/system/bin/su` never exists on disk: a bare `su` cannot resolve it in `PATH`,
and the hook only fires on an actual `execve` of that path.

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

## Already made permanent

Flashed and verified — no further steps needed:

```
fastboot flash boot mars-KernelSU-v0.9.5-boot.img   # wrote boot_b (active slot)
fastboot reboot
```

Manager APK (must be this exact release; the kernel reports Build **11872**, and
a newer manager reports a version mismatch):
`KernelSU_v0.9.5_11872-release.apk`
→ https://github.com/tiann/KernelSU/releases/tag/v0.9.5

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

## Findings worth keeping

1. **No modules are needed — everything is built into the image.** The resolved
   `.config` has **zero `=m`** entries (854 `=y`), so `/proc/modules` is empty on
   the running kernel while 169 drivers are built in. Camera (`/dev/video*`),
   audio (66 PCM devices) and mobile data (`rmnet*`, 11 interfaces) were all
   verified working. `make modules` does fail on the Qualcomm techpack trees
   (`error: unable to open output file 'scripts/mod/empty.o': 'Operation not
   permitted'`), but that is harmless here: there is nothing left to build as a
   module, and the step is non-fatal by design so the kernel is never discarded.
2. **Stock `.ko` cannot be reused — which is exactly why everything is built
   in.** The kernel has `CONFIG_MODVERSIONS=y` + `CONFIG_CFI_CLANG=y` and no
   `CONFIG_MODULE_FORCE_LOAD`. Loadability is decided by the symbol CRCs in the
   kernel's `__kcrctab`, which `genksyms` derives from the source tree's own
   headers. Xiaomi never published the 5.4.210 tree (MiCode only ships
   `star-r-oss` = 5.4.61 / Android R), so stock modules fail at the very first
   symbol, `module_layout`. Verified present in the built image instead:
   `sde_kms`/`msm_drm`, `fts_touch_spi`, `cyttsp5`, `goodix_fod`,
   `cnss2`/`wlan_hdd_cfg80211_init`, `ufs_qcom_`.
3. **Wi-Fi does not come up on *this* device/environment, on stock either.**
   Wi-Fi is enabled in settings yet no `wlan0` appears under the stock kernel
   either: `ls /sys/class/net` is identical, stock also reports "Wi-Fi is
   disabled", and the same `cnss-daemon` / `BTON: WLAN OFF` messages appear. So
   this is a pre-existing state, **not a regression** from the new kernel. The
   Wi-Fi stack (`QCA_CLD_WLAN=y`, `CNSS2=y`, `ICNSS2=y`) is built in, and the
   `cnss2` platform driver registers; no device binds to it, on either kernel.
4. **`su` requires a non-empty allowlist.** With the allowlist empty
   (`getAllowList: size: 0`), KernelSU denies everything by design. Root is
   granted per-app; see the seeding note above for the required file format.
   Note `su` is provided purely by the kernel's `execve` hook rewriting
   `/system/bin/su` → `/data/adb/ksud`; the file `/system/bin/su` never exists
   on disk, so the hook fires only on an actual `execve` of that path — a bare
   `su` cannot resolve it through `PATH`.

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
