# Reporting UAPI 4 from the auto-hook branch — why it is honest

## Result: verified on the device

The kernel now reports UAPI 4, matching the manager, and root still works. Read
back from the flashed kernel:

```
$ adb shell 'su -c "/data/adb/ksud debug info"'
version: 35171
full_version: v4.1.0-9d159b41-dirty@ReSukiSU
flags: 0x0
uapi_version: 4          <- was 2
features: 0x5
lkm: false               <- built-in, as assumed
bundled: false           <- would be false either way, as predicted
late_load: false
runtime_mode: built-in
pr_build: false
```

with `su -c id` → `uid=0(root) ... context=u:r:ksu:s0`, SELinux `Enforcing`, and
the manager connected (`install fd for ksu manager`).

Since the manager's test is `isManager && kernelUAPIVersion == managerUAPIVersion`
and both sides now report 4, the Modules and Superuser tabs are no longer hidden.

Build: CI run **36875939048**, all steps green. Flashed to `boot_b` and
re-verified after a reboot.

## The problem

The ReSukiSU manager showed **"需要更新内核"** and — far worse — **hid the Modules
and Superuser tabs**, leaving only Home and Settings. The cause is not the version
code. It is this (`Natives.kt`):

```kotlin
fun isFullFeatured(): Boolean {
    return isManager && kernelUAPIVersion == managerUAPIVersion
}
```

and `MainScreen.kt` builds the bottom-bar page list from `isFullFeatured`:

```kotlin
val pages = remember(homeState.systemStatus.isFullFeatured) {
    BottomBarDestination.getPages(homeState.systemStatus.isFullFeatured)
}
```

So a UAPI mismatch removes most of the app, not just a notice.

The two sides were:

| | UAPI version |
| --- | --- |
| `auto-hook` branch kernel | **2** |
| `v4.2.0-rc3` manager | **4** |

Note that pinning the *version code* (`KSU_VERSION_PIN`) did nothing for this —
it is a different field. That mistake cost a build cycle.


## Why matching by ref does not work

Building the `v4.2.0-rc3` tag does report 4, but **that kernel does not boot on
this device** — it falls through to MIUI Recovery (CI run 36852266515 built it
cleanly). The suspect is `feature/module_load_filter.o`, which it compiles
additionally; `patches/bisect_rc3_boot.sh` exists to confirm that.

So choosing the ref trades a working kernel for a matching number.

## Why 4 is a truthful description of this kernel

The `auto-hook` headers were diffed in full against the `v4.2.0-rc3` tag. Every
ioctl command, every UAPI struct (including `app_profile` and
`ksu_get_info_cmd`) and every constant is **identical**, except one:

```
DEFINE_KSU_UAPI_CONST(__u32, KSU_GET_INFO_FLAG_BUNDLED, (1U << 4))   # rc3 only
```

What the intervening revisions were documented to add:

```c
// 2: allowlist v4 root profile flags
// 3: scoped su-session driver fd
// 4: add KSU_GET_INFO_FLAG_BUNDLED
```

* **UAPI 3 (scoped su-session fd)** — already implemented in `auto-hook` as
  `ksu_install_fd()` in `supercall/supercall.c`, called from
  `hook/setuid_hook.c:95` and `:133`, and exposed via
  `ksu_install_fd_to_user()`. The capability is present; only the version
  constant was never bumped.
* **UAPI 4 (`KSU_GET_INFO_FLAG_BUNDLED`)** — a *response* flag, not a callable
  API, and its sole consumer is:

  ```c
  bool is_lkm_bundled() {
      return (info.flags & KSU_GET_INFO_FLAG_LKM) != 0 &&
             (info.flags & KSU_GET_INFO_FLAG_BUNDLED) != 0;
  }
  ```

  It requires `KSU_GET_INFO_FLAG_LKM`, which is set under `#ifdef MODULE` only.
  This kernel is **built in**, so `FLAG_LKM` is never set, `is_lkm_bundled()` is
  false either way, and the Kotlin property `isLkmBundled` is declared in
  `Natives.kt:60` but **referenced nowhere** in the manager.

Therefore reporting 4 claims no capability the driver lacks. It corrects an
under-declaration, it does not fabricate one.

## What was done

`patches/resukisu_uapi_version.sh` rewrites the single constant:

```c
static const __u32 KERNEL_SU_UAPI_VERSION = 4; /* KSU_UAPI_VERSION_PINNED_BY_KERNELSU_ACTION */
```

keeping the original declaration in a comment. It refuses to run unless the tree
declares exactly `2`, so the reasoning above cannot silently mis-apply to a
different revision, and rejects a non-numeric target.

`KSU_UAPI_VERSION=4` in the device profile drives it.

## Keeping this honest over time

The manager's comparison is **equality**, so this must be revisited whenever the
manager is upgraded:

* Bump `KSU_VERSION_PIN` to the new manager's version code
  (`30000 + its commit count + 700`).
* Bump `KSU_UAPI_VERSION` to the new manager's UAPI value, **but only after
  re-diffing the headers** to confirm no new callable API or struct field was
  introduced that this driver lacks. If one was, this shortcut is no longer
  valid and the kernel side must actually be brought up to date.

The safe check is the diff used here:

```sh
diff <(grep -oE 'DEFINE_KSU_UAPI_CONST\([^)]*\)' auto-hook/uapi/*.h | sort -u) \
     <(grep -oE 'DEFINE_KSU_UAPI_CONST\([^)]*\)' manager/uapi/*.h   | sort -u)
```

If that reports only additive *response* flags, bumping is honest. If it reports a
new ioctl or a changed struct, it is not.
