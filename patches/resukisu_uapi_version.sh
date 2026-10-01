#!/usr/bin/env bash
# =============================================================================
# Report ReSukiSU's UAPI version as 4 on a kernel whose UAPI is genuinely 4.
#
# WHY THIS IS NOT A LIE
# ---------------------
# The version comparison that matters is in the manager
# (`Natives.kt`):
#
#     fun isFullFeatured() = isManager && kernelUAPIVersion == managerUAPIVersion
#
# and when it is false the manager does not merely show a warning -- it hides the
# Modules and Superuser tabs entirely (`MainScreen.kt` builds its page list from
# `isFullFeatured`). So a mismatch is not cosmetic.
#
# The `auto-hook` branch declares `KERNEL_SU_UAPI_VERSION = 2`, but a full diff
# of the UAPI headers against the v4.2.0-rc3 tag (which declares 4) shows the
# two are identical except for a single constant:
#
#     DEFINE_KSU_UAPI_CONST(__u32, KSU_GET_INFO_FLAG_BUNDLED, (1U << 4))   # rc3 only
#
# Every ioctl command, every uapi struct (including `app_profile` and
# `ksu_get_info_cmd`) and every other constant match. What UAPI 3 introduced --
# the scoped su-session driver fd -- is already present in auto-hook as
# `ksu_install_fd()`:  `supercall/supercall.c`, called from
# `hook/setuid_hook.c`. So auto-hook implements the UAPI 3 contract and was
# simply never re-declared.
#
# The one thing auto-hook lacks, `KSU_GET_INFO_FLAG_BUNDLED`, is a *response
# flag*, not a callable API, and its only consumer is:
#
#     bool is_lkm_bundled() {
#         return (info.flags & KSU_GET_INFO_FLAG_LKM) != 0 &&
#                (info.flags & KSU_GET_INFO_FLAG_BUNDLED) != 0;
#     }
#
# which requires FLAG_LKM, set only under `#ifdef MODULE`. This kernel is built
# in, so FLAG_LKM is never set, `is_lkm_bundled()` is false either way, and the
# property `isLkmBundled` is not referenced anywhere in the manager UI. Reporting
# 4 therefore tells the manager nothing false about a built-in kernel.
#
# This script only bumps the integer the driver reports. It does not add or
# remove any capability.
#
# WHAT IT CHANGES
# ---------------
# `kernel/include/uapi/supercall.h`: the `KERNEL_SU_UAPI_VERSION` constant, with
# the original value preserved in a comment. Refuses to run if the constant is
# not `2`, so it cannot silently mis-apply to a different revision.
# =============================================================================
set -euo pipefail

KSU_DIR=${1:?usage: resukisu_uapi_version.sh <KernelSU-dir> [target]}
TARGET=${2:-4}
HDR="${KSU_DIR}/kernel/include/uapi/supercall.h"

[ -f "$HDR" ] || { echo "supercall.h not found: ${HDR}" >&2; exit 1; }

case "$TARGET" in
	''|*[!0-9]*) echo "target must be a decimal integer, got '${TARGET}'" >&2; exit 1 ;;
esac

MARKER="KSU_UAPI_VERSION_PINNED_BY_KERNELSU_ACTION"

if grep -q "$MARKER" "$HDR"; then
	if grep -qE "KERNEL_SU_UAPI_VERSION = ${TARGET};.*${MARKER}" "$HDR"; then
		echo "[-] UAPI version already ${TARGET}"
		exit 0
	fi
	# Re-pin to a new value.
	awk -v v="$TARGET" -v m="$MARKER" '
		$0 ~ ("KERNEL_SU_UAPI_VERSION = [0-9]+;.*" m) {
			print "static const __u32 KERNEL_SU_UAPI_VERSION = " v "; /* " m " */"
			next
		}
		{ print }
	' "$HDR" >"${HDR}.uapi.$$"
	mv -f "${HDR}.uapi.$$" "$HDR"
	echo "[+] re-pinned KERNEL_SU_UAPI_VERSION to ${TARGET}"
	exit 0
fi

# Only act on the exact upstream form, and only when it says 2 -- the value this
# patch was reasoned about. Anything else means a different revision and the
# analysis above may not hold.
cur=$(grep -oE 'KERNEL_SU_UAPI_VERSION = [0-9]+;' "$HDR" | head -1 | grep -oE '[0-9]+' || true)
if [ -z "$cur" ]; then
	echo "[-] could not find KERNEL_SU_UAPI_VERSION in ${HDR}" >&2
	echo "    Refusing to guess; inspect that file." >&2
	exit 1
fi
if [ "$cur" != "2" ]; then
	echo "[-] expected KERNEL_SU_UAPI_VERSION = 2, found ${cur}." >&2
	echo "    This patch is reasoned specifically about the 2 -> ${TARGET} step;" >&2
	echo "    re-read docs/resukisu-uapi-version.md before changing it." >&2
	exit 1
fi

awk -v v="$TARGET" -v m="$MARKER" '
	/KERNEL_SU_UAPI_VERSION = 2;/ {
		print "// Pinned by KernelSU_Action (resukisu_uapi_version.sh)."
		print "// The headers are identical to the v4.2.0-rc3 tag apart from"
		print "// KSU_GET_INFO_FLAG_BUNDLED, which is an LKM-mode response flag that"
		print "// cannot apply to a built-in kernel; UAPI 3 (the scoped su-session"
		print "// fd) is already implemented here. See"
		print "// docs/resukisu-uapi-version.md."
		print "// Upstream declared: " $0
		print "static const __u32 KERNEL_SU_UAPI_VERSION = " v "; /* " m " */"
		next
	}
	{ print }
' "$HDR" >"${HDR}.uapi.$$"

mv -f "${HDR}.uapi.$$" "$HDR"

grep -qE "KERNEL_SU_UAPI_VERSION = ${TARGET};.*${MARKER}" "$HDR" || {
	echo "[-] pin did not apply" >&2
	exit 1
}

echo "[+] KERNEL_SU_UAPI_VERSION: ${cur} -> ${TARGET}"
