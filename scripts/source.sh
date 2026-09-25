#!/usr/bin/env bash
# Fetch the kernel source tree.

set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORKSPACE=${WORKSPACE:?WORKSPACE must be set}
KERNEL_DIR="${WORKSPACE}/android-kernel"

group "Cloning kernel source"
info "${KERNEL_SOURCE} @ ${KERNEL_SOURCE_BRANCH:-<pinned commit>}"

ref_exists "$KERNEL_SOURCE" "$KERNEL_SOURCE_BRANCH" \
	|| die "branch/tag '${KERNEL_SOURCE_BRANCH}' does not exist in ${KERNEL_SOURCE}"

rm -rf "$KERNEL_DIR"
if [ -n "${KERNEL_PIN_COMMIT:-}" ]; then
	# A commit rather than a branch. This matters for vendor trees that get
	# rebased in place: the defconfig, the hook patches and the SUSFS backport
	# in a device profile are all context-sensitive, so a moving branch tip
	# silently turns a verified build into an unverified one.
	#
	# git clone -b does not accept a commit, so clone nothing and fetch the
	# one commit we want. `git fetch <sha>` works on GitHub for any commit
	# reachable from a ref, and --depth=1 keeps it as cheap as a branch clone.
	info "pinning to commit ${KERNEL_PIN_COMMIT}"
	retry 3 git init -q "$KERNEL_DIR" \
		|| die "failed to create ${KERNEL_DIR}"
	git -C "$KERNEL_DIR" remote add origin "$KERNEL_SOURCE" \
		|| die "failed to add remote ${KERNEL_SOURCE}"
	retry 3 git -C "$KERNEL_DIR" fetch -q --depth=1 origin "$KERNEL_PIN_COMMIT" \
		|| die "commit ${KERNEL_PIN_COMMIT} is not fetchable from ${KERNEL_SOURCE}"
	git -C "$KERNEL_DIR" checkout -q --detach FETCH_HEAD \
		|| die "failed to check out ${KERNEL_PIN_COMMIT}"
	pinned=$(git -C "$KERNEL_DIR" rev-parse HEAD)
	[ "$pinned" = "$KERNEL_PIN_COMMIT" ] \
		|| die "expected commit ${KERNEL_PIN_COMMIT}, got ${pinned}"
else
	retry 3 git clone -q --recursive --depth=1 \
		-b "$KERNEL_SOURCE_BRANCH" "$KERNEL_SOURCE" "$KERNEL_DIR" \
		|| die "failed to clone ${KERNEL_SOURCE}"
fi

# KernelSU forks compute their version from the commit count, and several
# read it straight out of the enclosing git repo. A depth-1 clone reports 1
# commit, which produces a nonsense version. Unshallow just enough to count.
if [ -f "${KERNEL_DIR}/.git/shallow" ]; then
	debug "kernel tree is shallow; that is fine for building"
fi

KVER=$(kernel_version "$KERNEL_DIR") \
	|| die "could not read VERSION/PATCHLEVEL from ${KERNEL_DIR}/Makefile -- is this a kernel tree?"
export_env KERNEL_VERSION "$KVER"
export_env KERNEL_DIR "$KERNEL_DIR"
ok "kernel source ready (Linux ${KVER})"
if [ -n "${KERNEL_PIN_COMMIT:-}" ]; then
	summary "| Kernel | \`${KERNEL_SOURCE##*/}\` @ \`${KERNEL_PIN_COMMIT:0:12}\` (Linux ${KVER}) |"
else
	summary "| Kernel | \`${KERNEL_SOURCE##*/}\` @ \`${KERNEL_SOURCE_BRANCH}\` (Linux ${KVER}) |"
fi

# LOCALVERSION is used purely to decorate artifact names.
if is_true "${ADD_LOCALVERSION_TO_FILENAME:-false}" && [ -f "${KERNEL_DIR}/localversion" ]; then
	export_env LOCALVERSION "$(cat "${KERNEL_DIR}/localversion")"
else
	export_env LOCALVERSION ""
fi
endgroup
