#!/usr/bin/env python3
"""Generate a KernelSU allowlist file that grants root to specific UIDs.

Why this exists
---------------
KernelSU grants root per-app, normally by tapping "Grant" in the manager. That
is impossible when the device cannot receive injected input (e.g. MIUI blocks
`input keyevent` from adb: "requires ... INJECT_EVENTS") and the screen is
locked. With the allowlist empty the kernel reports `getAllowList: size: 0` and
correctly denies every `su`, so root cannot be obtained at all -- a
chicken-and-egg problem, since fixing it needs root or a UI tap.

This writes the file directly from a shell that already has root (Magisk, a
recovery, or a booted stock system), so the next boot into the KernelSU kernel
has a working allowlist.

The on-disk format (kernel/allowlist.c, kernel/ksu.h in KernelSU v0.9.5):

    u32 magic   = 0x7f4b5355    # ' KSU'
    u32 version = 3             # FILE_FORMAT_VERSION
    struct app_profile entry[]  # 776 bytes each on arm64

    struct app_profile {
        u32  version;                      // must be >= KSU_APP_PROFILE_VER (2)
        char key[256];                     // package name, for display
        s32  current_uid;                  // the UID being granted
        bool allow_su;
        union {
            struct { bool use_default; char template_name[256];
                     struct root_profile profile; } rp_config;
            struct { bool use_default;
                     struct non_root_profile profile; } nrp_config;
        };
    };

Two entry fields are load-bearing -- get either wrong and the kernel's
profile_valid() silently drops the record during load, leaving you with a file
that looks right and a `su` that still refuses:

  * version must be >= 2 (KSU_APP_PROFILE_VER);
  * rp_config.profile.selinux_domain must be non-empty when allow_su is set.

rp_config.use_default = true then makes the kernel use its own built-in root
profile (uid 0, gid 0, full capabilities, domain u:r:su:s0); the domain string
above is still required because validation runs before that shortcut is
consulted.

Usage
-----
    gen-allowlist.py OUTPUT [UID[:LABEL] ...]

    # grant adb shell (uid 2000)
    gen-allowlist.py .allowlist 2000:com.android.shell

    # several entries
    gen-allowlist.py .allowlist 2000:com.android.shell 1010:com.android.system

Install it with root, then reboot into the KernelSU kernel:

    adb push .allowlist /data/local/tmp/.allowlist
    adb shell su -c 'cp /data/local/tmp/.allowlist /data/adb/ksu/.allowlist'
    adb shell su -c 'chmod 600 /data/adb/ksu/.allowlist'

Verify afterwards with: adb shell su -c id   # expect uid=0(root)
"""
import ctypes
import struct
import sys

FILE_MAGIC = 0x7F4B5355  # ' KSU'
FILE_FORMAT_VERSION = 3
KSU_APP_PROFILE_VER = 2
KSU_MAX_PACKAGE_NAME = 256
KSU_MAX_GROUPS = 32
KSU_SELINUX_DOMAIN = 64
DEFAULT_SELINUX_DOMAIN = b"u:r:su:s0"


class Capabilities(ctypes.Structure):
    _fields_ = [
        ("effective", ctypes.c_uint64),
        ("permitted", ctypes.c_uint64),
        ("inheritable", ctypes.c_uint64),
    ]


class RootProfile(ctypes.Structure):
    _fields_ = [
        ("uid", ctypes.c_int32),
        ("gid", ctypes.c_int32),
        ("groups_count", ctypes.c_int32),
        ("groups", ctypes.c_int32 * KSU_MAX_GROUPS),
        ("capabilities", Capabilities),
        ("selinux_domain", ctypes.c_char * KSU_SELINUX_DOMAIN),
        ("namespaces", ctypes.c_int32),
    ]


class NonRootProfile(ctypes.Structure):
    _fields_ = [("umount_modules", ctypes.c_bool)]


class RpConfig(ctypes.Structure):
    _fields_ = [
        ("use_default", ctypes.c_bool),
        ("template_name", ctypes.c_char * KSU_MAX_PACKAGE_NAME),
        ("profile", RootProfile),
    ]


class NrpConfig(ctypes.Structure):
    _fields_ = [
        ("use_default", ctypes.c_bool),
        ("profile", NonRootProfile),
    ]


class RpUnion(ctypes.Union):
    _fields_ = [("rp_config", RpConfig), ("nrp_config", NrpConfig)]


class AppProfile(ctypes.Structure):
    _fields_ = [
        ("version", ctypes.c_uint32),
        ("key", ctypes.c_char * KSU_MAX_PACKAGE_NAME),
        ("current_uid", ctypes.c_int32),
        ("allow_su", ctypes.c_bool),
        ("u", RpUnion),
    ]


def make_profile(label, uid, allow_su=True):
    p = AppProfile()
    ctypes.memset(ctypes.byref(p), 0, ctypes.sizeof(p))
    p.version = KSU_APP_PROFILE_VER
    p.key = label.encode()[: KSU_MAX_PACKAGE_NAME - 1]
    p.current_uid = uid
    p.allow_su = allow_su
    p.u.rp_config.use_default = True
    p.u.rp_config.profile.selinux_domain = DEFAULT_SELINUX_DOMAIN
    return bytes(ctypes.string_at(ctypes.byref(p), ctypes.sizeof(p)))


def parse_entry(spec):
    # "2000:com.android.shell" or just "2000"
    uid_s, _, label = spec.partition(":")
    uid = int(uid_s)
    if uid < 2000:
        # profile_valid() calls forbid_system_uid() and refuses anything below
        # 2000, so such an entry would be dropped on load.
        raise SystemExit(
            "uid %d is rejected by the kernel (forbid_system_uid requires "
            "uid >= 2000); it would be silently dropped" % uid
        )
    return (label or "uid%d" % uid), uid, True


def main():
    if len(sys.argv) < 3:
        sys.stderr.write(__doc__)
        return 2

    out = sys.argv[1]
    entries = [parse_entry(s) for s in sys.argv[2:]]

    blob = struct.pack("<II", FILE_MAGIC, FILE_FORMAT_VERSION)
    for label, uid, allow in entries:
        blob += make_profile(label, uid, allow)
        print("  %-28s uid=%-6d allow_su=%s" % (label, uid, allow))

    with open(out, "wb") as f:
        f.write(blob)

    entry_size = ctypes.sizeof(AppProfile)
    expected = 8 + len(entries) * entry_size
    assert len(blob) == expected, "size mismatch: %d != %d" % (len(blob), expected)

    print("struct app_profile : %d bytes" % entry_size)
    print("entries            : %d" % len(entries))
    print("written            : %s (%d bytes)" % (out, len(blob)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
