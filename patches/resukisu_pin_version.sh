#!/usr/bin/env bash
# =============================================================================
# Pin ReSukiSU's reported driver version to a chosen value.
#
# WHY
# ---
# ReSukiSU derives its version from the commit count of whatever ref is checked
# out (kernel/Kbuild):
#
#     KSU_LOCAL_VERSION := $(shell cd $(KSU_SRC); git rev-list --count HEAD)
#     KSU_VERSION       := $(shell expr 30000 + $(KSU_LOCAL_VERSION) + 700)
#
# and reports it to the manager as KERNEL_SU_VERSION via do_get_info. The manager
# compares that against its own build number and shows "kernel needs update" when
# they differ.
#
# Measured on the real repository:
#     auto-hook branch : 4375 commits -> 35075
#     v4.2.0-rc3 tag   : 4471 commits -> 35171   <- matches release v4.2.0-rc3
#
# So matching a released manager otherwise forces you onto that exact ref. That
# is a bad trade: on this device the v4.2.0-rc3 tag *builds* but does not boot
# (it falls through to recovery; see docs/resukisu-version-match.md), while the
# auto-hook branch builds AND boots. Pinning the number decouples the two: keep
# the ref that works, and report the version the manager expects.
#
# HOW
# ---
# KSU_VERSION is only ever consumed as a compiler define
# (`ccflags-y += -DKSU_VERSION=$(KSU_VERSION)`), so overriding the variable is
# enough. The replacement is inserted immediately after the original assignment,
# guarded so a second run is a no-op and so the original line is left visible for
# anyone reading the Kbuild.
#
# Only ReSukiSU's own Kbuild is edited; no kernel source is touched.
# =============================================================================
set -euo pipefail

KSU_DIR=${1:?usage: resukisu_pin_version.sh <KernelSU-dir> <version-code>}
VERSION=${2:?usage: resukisu_pin_version.sh <KernelSU-dir> <version-code>}
KBUILD="${KSU_DIR}/kernel/Kbuild"

[ -f "$KBUILD" ] || { echo "Kbuild not found: ${KBUILD}" >&2; exit 1; }

# Reject anything that is not a plain decimal number: this value ends up in a
# C define, and a malformed one would fail the build in a confusing place.
case "$VERSION" in
	''|*[!0-9]*) echo "version must be a decimal integer, got '${VERSION}'" >&2; exit 1 ;;
esac

MARKER="KSU_VERSION_PINNED_BY_KERNELSU_ACTION"

if grep -q "$MARKER" "$KBUILD"; then
	# Already pinned: rewrite the value in place so re-running with a different
	# number works. Match the pinned line loosely (any digits, marker anywhere
	# on the line) and rebuild it, rather than trying to substitute the old
	# number, which would fail once the value changes.
	if ! grep -qE "^KSU_VERSION[[:space:]]*:=[[:space:]]*[0-9]+.*${MARKER}" "$KBUILD"; then
		echo "[-] found the pin marker but not a pinned KSU_VERSION line;" >&2
		echo "    inspect ${KBUILD}" >&2
		exit 1
	fi
	awk -v ver="$VERSION" -v marker="$MARKER" '
		$0 ~ ("^KSU_VERSION[[:space:]]*:=[[:space:]]*[0-9]+.*" marker) {
			print "KSU_VERSION := " ver " # " marker
			next
		}
		{ print }
	' "$KBUILD" >"${KBUILD}.kpv.$$"
	mv -f "${KBUILD}.kpv.$$" "$KBUILD"

	if grep -qE "^KSU_VERSION[[:space:]]*:=[[:space:]]*${VERSION}[[:space:]]*# ${MARKER}\$" "$KBUILD"; then
		echo "[-] version already pinned to ${VERSION}"
		exit 0
	fi
	echo "[+] re-pinned KSU_VERSION to ${VERSION}"
	exit 0
fi

# Anchor on the upstream assignment. If it is absent this is a different
# revision, and silently doing nothing would leave the mismatch in place.
if ! grep -qE '^KSU_VERSION[[:space:]]*:=[[:space:]]*\$\(shell expr 30000' "$KBUILD"; then
	echo "[-] could not find the KSU_VERSION assignment in ${KBUILD}" >&2
	echo "    Either this revision computes it differently or the file changed" >&2
	echo "    shape. Refusing to guess; inspect that file." >&2
	exit 1
fi

# Replace the assignment itself, preserving the upstream expression in a comment
# so the intent is obvious to the next reader.
awk -v ver="$VERSION" -v marker="$MARKER" '
	/^KSU_VERSION[[:space:]]*:=[[:space:]]*\$\(shell expr 30000/ {
		print "# Pinned by KernelSU_Action (resukisu_pin_version.sh) so the driver"
		print "# version matches the installed manager. Upstream computed it as:"
		print "# " $0
		print "KSU_VERSION := " ver " # " marker
		next
	}
	{ print }
' "$KBUILD" >"${KBUILD}.kpv.$$"

mv -f "${KBUILD}.kpv.$$" "$KBUILD"

# Prove it took.
grep -qE "^KSU_VERSION[[:space:]]*:=[[:space:]]*${VERSION}[[:space:]]*# ${MARKER}\$" "$KBUILD" || {
	echo "[-] pin did not apply" >&2
	exit 1
}

echo "[+] pinned KSU_VERSION to ${VERSION}"
