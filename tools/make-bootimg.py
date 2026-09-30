#!/usr/bin/env python3
"""Splice a freshly built kernel Image into a stock boot image.

Why not magiskboot repack:
  The stock boot header carries 32 bytes of non-zero data at offset 576
  (inside the v3 header's unused tail, before the cmdline area). magiskboot
  preserves the header it read, but any tool that *rebuilds* the header from
  parsed fields zeros that region. Since we only ever replace the kernel, the
  header is copied verbatim and exactly two fields are touched: kernel_size
  (offset 8) and, if needed, the os_version/security patch (offset 16).

  The ramdisk is reused as the stock *compressed* bytes rather than being
  unpacked and recompressed, so it is bit-identical to what shipped. On this
  device the stock ramdisk is the only one known to boot, and it already
  carries the Magisk changes present in the dumped image.

Layout (header v3, the only version this device uses):
    0x0000  header (4096 bytes, page aligned)
    +0x1000 kernel  (kernel_size bytes, padded to page size)
    +...    ramdisk (ramdisk_size bytes, padded to page size)

Usage:
    make-bootimg.py <stock-boot.img> <Image> <out-boot.img> [--trim]

--trim strips the all-zero tail padding so the result matches the byte length
actually stored in the boot partition.
"""
import struct
import sys

PAGE = 4096


def round_up(x, align=PAGE):
    return (x + align - 1) // align * align


def main():
    if len(sys.argv) < 4:
        sys.stderr.write(__doc__)
        return 2

    ref, image, out = sys.argv[1], sys.argv[2], sys.argv[3]
    trim = "--trim" in sys.argv[4:]

    raw = open(ref, "rb").read()
    magic = raw[:8]
    if magic != b"ANDROID!":
        sys.stderr.write("not an Android boot image: %s\n" % ref)
        return 1

    header_version = struct.unpack_from("<I", raw, 40)[0]
    if header_version != 3:
        sys.stderr.write(
            "only header v3 is supported (got v%d).\n"
            "v0/v1/v2 have no kernel_size padding rules in common with this "
            "layout; use magiskboot for those.\n" % header_version
        )
        return 1

    kernel_size, ramdisk_size = struct.unpack_from("<II", raw, 8)

    # v3 header layout: recovery_dtbo_size at 0x400+0x18 and dtb_size at
    # 0x400+0x28 (both inside the second 4096-byte header page). This device's
    # images carry neither, and silently dropping them would produce a broken
    # boot image, so refuse rather than guess.
    recovery_dtbo_size = struct.unpack_from("<I", raw, 1632)[0]
    dtb_size = struct.unpack_from("<I", raw, 1648)[0]
    if recovery_dtbo_size or dtb_size:
        sys.stderr.write(
            "reference image carries recovery_dtbo (%d) or dtb (%d); this "
            "tool only handles the plain kernel+ramdisk case\n"
            % (recovery_dtbo_size, dtb_size)
        )
        return 1

    kernel_off = PAGE
    ramdisk_off = kernel_off + round_up(kernel_size)
    ramdisk = raw[ramdisk_off:ramdisk_off + ramdisk_size]
    if len(ramdisk) != ramdisk_size:
        sys.stderr.write("reference image is truncated\n")
        return 1

    new_kernel = open(image, "rb").read()
    if new_kernel[:2] != b"MZ":
        sys.stderr.write(
            "%s does not look like an arm64 Image (expected 'MZ' magic)\n"
            % image
        )
        return 1

    header = bytearray(raw[:PAGE])
    struct.pack_into("<I", header, 8, len(new_kernel))

    blob = bytes(header) + new_kernel
    blob += b"\x00" * (round_up(len(blob)) - len(blob))
    blob += ramdisk
    blob += b"\x00" * (round_up(len(blob)) - len(blob))

    if trim:
        blob = blob.rstrip(b"\x00")
        if len(blob) % PAGE:
            blob += b"\x00" * (PAGE - (len(blob) % PAGE))

    open(out, "wb").write(blob)

    print("reference  : %s (%d bytes, kernel %d, ramdisk %d)"
          % (ref, len(raw), kernel_size, ramdisk_size))
    print("new kernel : %s (%d bytes)" % (image, len(new_kernel)))
    print("output     : %s (%d bytes)" % (out, len(blob)))

    sig = bytes(header[576:608])
    print("header sig : %s%s"
          % (sig.hex(), "  (preserved)" if any(sig) else "  (zero in reference)"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
