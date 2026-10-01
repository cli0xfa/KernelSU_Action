# Matching the ReSukiSU manager version

## Result: matched, and root still works

The kernel now reports **35171**, exactly the manager's own `versionCode`, while
still booting from the `auto-hook` branch that is known to work here:

```
$ adb shell 'su -c "/data/adb/ksud debug version"'
Kernel Version: 35171        <- the (pinned) driver version

manager APK versionCode : 35171   (read from its AndroidManifest.xml)
ksud --version          : ksud 4.2.0-rc3 (uapi: 4)
```

Verified after a permanent flash to `boot_b`: kernel
`5.4.283-mars-g6cb9f5a9edc1`, `sys.boot_completed=1`, `su` returns
`uid=0(root) ... context=u:r:ksu:s0`, SELinux `Enforcing`, and a root write test
succeeds.

Build: CI run **36860101959**, all steps green.

## The version mechanism (verified)

ReSukiSU derives its driver version from the **commit count of whatever ref is
checked out** (`kernel/Kbuild`):

```makefile
KSU_LOCAL_VERSION := $(shell cd $(KSU_SRC); git rev-list --count HEAD)
KSU_VERSION       := $(shell expr 30000 + $(KSU_LOCAL_VERSION) + 700)
```

and reports it to the manager as `KERNEL_SU_VERSION` (= `KSU_VERSION`) through
`do_get_info` in `supercall/dispatch.c`. The manager compares that against its
own `versionCode`; a mismatch produces the "kernel needs update" notice.

Measured against the real repository (full clone, not shallow):

| Ref | Commits | `30000 + n + 700` |
| --- | --- | --- |
| `auto-hook` branch | 4375 | **35075** |
| `v4.2.0-rc3` tag | 4471 | **35171** |

## Why choosing the ref to match does not work

Building the `v4.2.0-rc3` tag does produce 35171 (CI run 36852266515 confirmed
`-- ReSukiSU version code: 35171`), **but that kernel does not boot on this
device**. `fastboot boot` was accepted by the bootloader and then the device fell
through to MIUI Recovery; it never reached `sys.boot_completed`, and ADB only
ever showed `offline`.

The notable compile difference is that `v4.2.0-rc3` additionally builds
`feature/module_load_filter.o`, which hooks module loading; on 5.4 that is the
most likely cause. *(Not yet confirmed.)*

So matching by ref forces a choice between a working kernel and a matching
version number. Pinning the number removes the trade.

## The fix

`KSU_VERSION` is only ever consumed as a compiler define:

```makefile
ccflags-y += -DKSU_VERSION=$(KSU_VERSION)
```

so overriding the variable is sufficient.
`patches/resukisu_pin_version.sh` rewrites that one assignment, keeping the
upstream expression in a comment, and `KSU_VERSION_PIN=35171` in the device
profile sets the value. The ref stays `auto-hook`.

Bump `KSU_VERSION_PIN` when the manager is upgraded: a release's number is
`30000 + (its commit count) + 700`, and the manager's own `versionCode` (readable
from its `AndroidManifest.xml`) equals that.

The patch rejects a non-numeric value, since it ends up in a C define; refuses a
Kbuild whose `KSU_VERSION` assignment is not shaped as expected rather than
silently doing nothing; and can re-pin to a new value in place.

## Things learned the hard way (relevant to any future flash)

* **`fastboot -S <size>` corrupts the partition if the image is not sparse.**
  It reported `Invalid sparse file format at header magic` but had already
  written the first chunk, which left `boot_b` unbootable and dropped the device
  into recovery. Recovery was restoring the stock image to **both** slots plus
  both `vbmeta` partitions. Do not use `-S` without converting to a real sparse
  image first.
* **The bootloader caps the flash download size** between 72256 KB (works) and
  72560 KB (rejected: `Requested download size is more than max allowed`).
  `fastboot boot` of the same image is *not* subject to that cap, which is why a
  kernel can boot fine yet refuse to flash. The ReSukiSU `Image` is 49152 bytes
  larger than the v0.9.5 one, which is enough to cross the limit.
* **The fix for the size cap is the ramdisk.** The working v0.9.5 image carried a
  ramdisk 258159 bytes smaller than the stock one (its build had stripped
  Magisk's ramdisk edits). Reusing that clean ramdisk with the new kernel brings
  the total to 74039296 bytes = **72304 KB**, which flashes. Padding to a 64 KiB
  boundary does not help, and recompressing the stock ramdisk makes it *larger*.

