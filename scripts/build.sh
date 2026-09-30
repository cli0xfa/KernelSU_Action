#!/usr/bin/env bash
# Prepare the defconfig and compile the kernel.

set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=scripts/kernelsu.sh
. "$(dirname "${BASH_SOURCE[0]}")/kernelsu.sh"
# shellcheck source=scripts/patches.sh
. "$(dirname "${BASH_SOURCE[0]}")/patches.sh"

KERNEL_DIR=${KERNEL_DIR:?KERNEL_DIR must be set}
WORKSPACE=${WORKSPACE:-$(cd "${KERNEL_DIR}/.." && pwd)}
ARCH=${ARCH:-arm64}
OUT="${KERNEL_DIR}/out"

DEFCONFIG_PATH="${KERNEL_DIR}/arch/${ARCH}/configs/${KERNEL_CONFIG}"

# ------------------------------------------------------------- defconfig ---

# The make targets that produce .config, in order.
#
# Qualcomm trees split device options across several files and rely on make's
# `%.config` rule (scripts/kconfig/merge_config.sh) to fold each one into the
# .config the preceding `%_defconfig` target generated. So the target list --
# not a single defconfig -- is the unit that describes a device:
#
#     vendor/lahaina-qgki_defconfig vendor/xiaomi_QGKI.config vendor/star_QGKI.config
#
# KERNEL_CONFIG is the first, single-path entry (it also names the device and
# is the file this script edits); KERNEL_CONFIG_FRAGMENTS are merged after it.
defconfig_targets() {
	printf '%s' "$KERNEL_CONFIG"
	local frag
	for frag in ${KERNEL_CONFIG_FRAGMENTS:-}; do
		printf ' %s' "$frag"
	done
}

prepare_defconfig() {
	group "Preparing defconfig"
	[ -f "$DEFCONFIG_PATH" ] \
		|| die "defconfig not found: arch/${ARCH}/configs/${KERNEL_CONFIG}
       Available: $(ls "${KERNEL_DIR}/arch/${ARCH}/configs/" | head -20 | tr '\n' ' ')"

	# Fragments are merged by make after the base defconfig, so they must exist
	# too -- merge_config.sh silently tolerates a missing fragment and the
	# device options in it would just never be applied.
	local frag
	for frag in ${KERNEL_CONFIG_FRAGMENTS:-}; do
		[ -f "${KERNEL_DIR}/arch/${ARCH}/configs/${frag}" ] \
			|| die "config fragment not found: arch/${ARCH}/configs/${frag}
       Check KERNEL_CONFIG_FRAGMENTS; a missing fragment is silently ignored by
       merge_config.sh and the options in it would never reach the build."
	done

	cp "$DEFCONFIG_PATH" "${WORKSPACE}/defconfig.orig"

	local kver
	kver=$(kernel_version "$KERNEL_DIR" || echo "0.0")

	if [ "${KSU_VARIANT:-none}" != "none" ]; then
		kconf_enable "$DEFCONFIG_PATH" CONFIG_KSU
		ksu_hook_configs "${KSU_VARIANT}" "${KSU_HOOK_MODE:-auto}" "$DEFCONFIG_PATH" "$kver"

		if is_true "${ENABLE_SUSFS:-false}"; then
			susfs_defconfig "$DEFCONFIG_PATH"
		fi

		if is_true "${ENABLE_KPM:-false}"; then
			# patch_linux resolves symbols at runtime, so kallsyms must be complete.
			kconf_set_many "$DEFCONFIG_PATH" \
				CONFIG_KPM=y CONFIG_KALLSYMS=y CONFIG_KALLSYMS_ALL=y
		fi
	fi

	# Overlayfs backs KernelSU's module mounts and system-partition writes.
	is_true "${ADD_OVERLAYFS_CONFIG:-false}" && kconf_enable "$DEFCONFIG_PATH" CONFIG_OVERLAY_FS

	# Kept as a standalone switch for kernels that need kprobes for their own
	# reasons, independent of the hook mode.
	if is_true "${ADD_KPROBES_CONFIG:-false}"; then
		kconf_set_many "$DEFCONFIG_PATH" \
			CONFIG_MODULES=y CONFIG_KPROBES=y CONFIG_HAVE_KPROBES=y CONFIG_KPROBE_EVENTS=y
	fi

	if is_true "${DISABLE_LTO:-false}"; then
		kconf_set_many "$DEFCONFIG_PATH" \
			CONFIG_LTO=n CONFIG_LTO_CLANG=n CONFIG_LTO_CLANG_FULL=n \
			CONFIG_LTO_CLANG_THIN=n CONFIG_THINLTO=n CONFIG_LTO_NONE=y
	fi

	is_true "${DISABLE_CC_WERROR:-false}" && kconf_disable "$DEFCONFIG_PATH" CONFIG_CC_WERROR

	# Free-form extras: one CONFIG_x=y per line, or space separated.
	if [ -n "${EXTRA_DEFCONFIG:-}" ]; then
		local kv
		# shellcheck disable=SC2086
		for kv in $(printf '%s' "$EXTRA_DEFCONFIG" | tr '\n' ' '); do
			[ -n "$kv" ] || continue
			case "$kv" in
				*=*) kconf_set "$DEFCONFIG_PATH" "${kv%%=*}" "${kv#*=}" ;;
				*)   warn "ignoring malformed EXTRA_DEFCONFIG entry '${kv}' (want CONFIG_X=y)" ;;
			esac
		done
	fi

	# A stable LOCALVERSION keeps artifact names predictable. Without this the
	# tree appends "-dirty" as soon as any patch above touches a tracked file.
	if [ -n "${KERNEL_NAME:-}" ]; then
		kconf_set "$DEFCONFIG_PATH" CONFIG_LOCALVERSION "\"-${KERNEL_NAME}\""
		if [ -f "${KERNEL_DIR}/scripts/setlocalversion" ]; then
			sed -i 's/echo "\$res"/echo "\$res"/; s/-dirty//g' "${KERNEL_DIR}/scripts/setlocalversion"
		fi
	fi

	info "defconfig changes:"
	diff -u "${WORKSPACE}/defconfig.orig" "$DEFCONFIG_PATH" | sed -n '4,$p' | sed 's/^/    /' || true
	endgroup
}

# ----------------------------------------------------------------- build ---

make_args() {
	printf '%s' "O=out ARCH=${ARCH}"
	[ -n "${CUSTOM_CMDS:-}" ] && printf ' %s' "$CUSTOM_CMDS"
	[ -n "${EXTRA_CMDS:-}"  ] && printf ' %s' "$EXTRA_CMDS"
	[ -n "${GCC_64:-}"      ] && printf ' %s' "$GCC_64"
	[ -n "${GCC_32:-}"      ] && printf ' %s' "$GCC_32"
	if is_true "${USE_LLVM:-false}"; then
		printf ' LLVM=1 LLVM_IAS=1'
		[ -n "${GCC_64:-}" ] || printf ' CROSS_COMPILE=aarch64-linux-gnu-'
	fi
	# Several lines above are `[ test ] && printf`, which return 1 when the test
	# fails. Callers capture this function with `args=$(make_args)`, and the
	# exit status of a command substitution becomes the status of the
	# assignment -- so a false test in the last line would abort the whole
	# build under `set -e`, silently. Nothing here can actually fail.
	return 0
}

build_kernel() {
	group "Building kernel"
	export PATH="${CLANG_PATH:-}:${PATH}"
	export KBUILD_BUILD_HOST=${KBUILD_BUILD_HOST:-Github-Action}
	export KBUILD_BUILD_USER=${KBUILD_BUILD_USER:-kernelsu-action}

	# DISABLE_LTO is this action's boolean configuration switch, but several
	# Android kernel trees use the same Make variable for compiler flags (for
	# example, "-fno-lto").  Leaving our value in the environment makes a
	# non-LTO build invoke `clang ... false ...`, treating "false" as an input
	# file.  prepare_defconfig() has already consumed the action setting, so let
	# Kbuild own the name from this point on.
	unset DISABLE_LTO

	# Custom manager signature, when the user builds their own manager APK.
	if [ -n "${KSU_EXPECTED_SIZE:-}" ] && [ -n "${KSU_EXPECTED_HASH:-}" ]; then
		export KSU_EXPECTED_SIZE KSU_EXPECTED_HASH
		info "using custom manager signature (size=${KSU_EXPECTED_SIZE})"
	fi

	local cc="clang" args
	args=$(make_args)
	if is_true "${ENABLE_CCACHE:-true}" && command -v ccache >/dev/null; then
		cc="ccache clang"
		export CCACHE_DIR="${CCACHE_DIR:-${WORKSPACE}/.ccache}"
		info "ccache enabled (dir: ${CCACHE_DIR})"
	fi

	cd "$KERNEL_DIR"
	# shellcheck disable=SC2086
	local targets
	targets=$(defconfig_targets)
	info "make ${args} ${targets}"
	# Unquoted on purpose: this is a target list, and make folds each
	# ".config" fragment into the .config produced by the preceding
	# "_defconfig" target via scripts/kconfig/merge_config.sh.
	# shellcheck disable=SC2086
	make -j"$(nproc --all)" CC=clang $args $targets \
		|| die "defconfig generation failed"

	verify_required_config

	info "make ${args}"
	# shellcheck disable=SC2086
	make -j"$(nproc --all)" CC="$cc" $args \
		|| die "kernel build failed"

	endgroup
}

# Fail the build when a symbol we asked for did not survive into .config.
#
# An unknown symbol in a defconfig, a fragment that never got merged, and a
# symbol whose Kconfig dependency is unmet all look the same from the outside:
# the line is simply absent from .config and the build proceeds. On a kernel
# whose only purpose is to carry KernelSU that produces a root-capable-looking
# image with no root in it, so it is worth an explicit check.
verify_required_config() {
	local cfg="${OUT}/.config"
	local spec sym want got missing=0

	[ -f "$cfg" ] || die "no ${cfg} after defconfig generation"

	# KERNEL_REQUIRED_CONFIG may name the KernelSU symbols implicitly; always
	# assert them when a variant was requested, since that is the whole point.
	if [ "${KSU_VARIANT:-none}" != "none" ]; then
		spec="CONFIG_KSU=y"
	fi
	spec="${spec} ${KERNEL_REQUIRED_CONFIG:-}"

	[ -n "${spec// /}" ] || return 0

	group "Verifying required config"
	for sym in $spec; do
		want="y"
		case "$sym" in
			*=*) want="${sym#*=}"; sym="${sym%%=*}" ;;
		esac
		case "$sym" in CONFIG_*) ;; *) sym="CONFIG_${sym}" ;; esac

		got=$(sed -nE "s/^${sym}=(.*)$/\1/p" "$cfg" | tail -n1)
		if [ "$want" = "y" ]; then
			if [ "$got" = "y" ]; then
				ok "${sym}=y"
			else
				warn "${sym} is not set in .config (value: '${got:-unset}')"
				missing=$((missing + 1))
			fi
		else
			if [ "$got" = "$want" ]; then
				ok "${sym}=${want}"
			else
				warn "${sym} is '${got:-unset}', expected '${want}'"
				missing=$((missing + 1))
			fi
		fi
	done

	if [ "$missing" -gt 0 ]; then
		die "${missing} required config option(s) missing from .config.
       A symbol that is unknown, or whose dependency is unmet, is dropped from
       a defconfig without any error -- the kernel then builds fine while
       missing the feature you asked for. Fix KERNEL_CONFIG_FRAGMENTS or
       KERNEL_REQUIRED_CONFIG (check that the option exists in the tree's
       Kconfig: grep -rn 'config ${sym#CONFIG_}' ${KERNEL_DIR})."
	fi
	endgroup
}

# ---------------------------------------------------------------- modules ---

# Compile the tree's loadable modules and stage them in a /vendor-shaped tree.
#
# Why this exists: CONFIG_MODVERSIONS makes module loadability depend on the
# symbol CRCs baked into the *kernel's* __kcrctab, and those CRCs are computed
# by genksyms from the source tree's own header type signatures. A stock
# module built by the vendor from a tree you do not have therefore cannot be
# loaded by your kernel -- the very first symbol (module_layout) is rejected
# and every dependent driver (display, touch, Wi-Fi, storage) fails with it.
# The only reliable answer is to ship modules built from this same tree.
#
# Modules are staged under ${WORKSPACE}/modules-stage/vendor/lib/modules so
# that package.sh can drop them into an AnyKernel3 "modules/" overlay, which
# AnyKernel3 turns into a systemless module that bind-mounts over /vendor.
build_modules() {
	is_true "${BUILD_MODULES:-false}" || { debug "module build disabled"; return 0; }
	group "Building kernel modules"

	local args stage
	args=$(make_args)
	stage="${WORKSPACE}/modules-stage"
	rm -rf "$stage"
	mkdir -p "$stage"

	cd "$KERNEL_DIR"
	info "make ${args} modules"
	# Techpack (camera/audio/datarmnet) ships external Makefiles that only
	# emit modules when modules are actually requested, so this must be a
	# separate invocation after the kernel image has been built.
	#
	# Failure here is deliberately not fatal. The kernel image is the artifact
	# that matters, and it has already been built by the time this runs; a
	# module that does not compile (Qualcomm's out-of-tree techpack Makefiles
	# routinely need a source tweak) would otherwise discard a perfectly
	# bootable kernel. Warn, keep whatever compiled, and let the flash
	# proceed -- the affected driver simply stays at its stock version.
	# shellcheck disable=SC2086
	if ! make -j"$(nproc --all)" $args modules; then
		warn "the module build failed; continuing with the kernel image alone."
		warn "The drivers in techpack/ (camera, audio, datarmnet) will fall back to"
		warn "the ROM's stock .ko, which this kernel cannot load -- so those may be"
		warn "non-functional until the module build is fixed."
	fi

	# modules_install wants CC/INSTALL_MOD_PATH and a destination outside the
	# tree so that ${stage} can be shipped verbatim.
	# shellcheck disable=SC2086
	make -j"$(nproc --all)" $args \
		INSTALL_MOD_PATH="$stage" \
		INSTALL_MOD_STRIP=1 \
		modules_install \
		|| warn "modules_install failed; no modules will be packaged"

	# modules_install creates build/ and source/ symlinks pointing back into
	# the build tree. They are meaningless (and dangling) inside a flashable
	# overlay, so drop them.
	rm -rf "${stage}/lib/modules/"*/build "${stage}/lib/modules/"*/source

	local release modroot
	release=$(cat "${OUT}/include/config/kernel.release" 2>/dev/null || echo "")
	modroot="${stage}/lib/modules/${release}"
	[ -d "$modroot" ] || modroot=$(find "$stage/lib/modules" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | head -n1)
	if [ -z "$modroot" ] || [ ! -d "$modroot" ]; then
		warn "modules_install produced no module directory; packaging the kernel without modules"
		endgroup
		return 0
	fi

	local count
	count=$(find "$modroot" -name '*.ko' | wc -l)
	if [ "$count" -eq 0 ]; then
		# Not an error: a config that builds everything as "=y" produces no
		# modules at all, and that is the desired outcome on a device whose
		# stock modules cannot be loaded by a foreign kernel anyway.
		warn "modules_install staged no .ko files; every driver is built into the image"
		endgroup
		return 0
	fi

	# Reshape into the layout the device uses: modules live flat in
	# /vendor/lib/modules, and /system/vendor is a symlink to /vendor. Only the
	# .ko files are staged -- deliberately not the generated modules.dep /
	# modules.alias / modules.softdep. Those are overlaid too if present, and
	# a dep file generated from just our subset would drop the entries for any
	# module we did not build, breaking modprobe for it. Leaving the stock dep
	# files in place keeps dependency resolution working by filename, so the
	# names we did build resolve to our .ko.
	local out="${WORKSPACE}/modules-vendor/vendor/lib/modules"
	rm -rf "${WORKSPACE}/modules-vendor"
	mkdir -p "$out"
	find "$modroot" -name '*.ko' -exec cp -a {} "$out/" \;

	local staged
	staged=$(find "$out" -name '*.ko' | wc -l)
	[ "$staged" -gt 0 ] || die "no .ko files were staged into ${out}"
	[ "$staged" -eq "$count" ] \
		|| warn "staged ${staged} of ${count} built modules (some names may collide)"

	export_env MODULE_STAGE "${WORKSPACE}/modules-vendor"
	export_env MODULE_COUNT "$staged"
	ok "staged ${staged} modules for release ${release:-unknown}"
	summary "| Modules | \`${staged}\` staged under \`vendor/lib/modules\` |"
	endgroup
}

# --------------------------------------------------------------- verify ---

check_output() {
	group "Checking build output"
	local boot="${OUT}/arch/${ARCH}/boot"
	local image="${boot}/${KERNEL_IMAGE_NAME}"

	[ -f "$image" ] || die "expected kernel image not found: ${image}
       Built files: $(ls "$boot" 2>/dev/null | tr '\n' ' ')
       Check that KERNEL_IMAGE_NAME matches what your kernel produces."

	ok "kernel image: ${KERNEL_IMAGE_NAME} ($(du -h "$image" | cut -f1))"
	export_env CHECK_FILE_IS_OK true

	if is_true "${NEED_DTBO:-false}"; then
		[ -f "${boot}/dtbo.img" ] || die "NEED_DTBO=true but ${boot}/dtbo.img was not produced"
		export_env CHECK_DTBO_IS_OK true
		ok "dtbo.img present"
	fi

	# KPM rewrites the image in place, so it has to happen after the build and
	# before packaging.
	if is_true "${ENABLE_KPM:-false}"; then
		kpm_patch_image "$image"
	fi

	# Record the version string the kernel actually reports.
	if [ -f "${OUT}/include/generated/utsrelease.h" ]; then
		local rel
		rel=$(sed -nE 's/.*UTS_RELEASE[[:space:]]+"([^"]+)".*/\1/p' "${OUT}/include/generated/utsrelease.h")
		export_env KERNEL_RELEASE "$rel"
		ok "kernel release: ${rel}"
		summary "| Kernel release | \`${rel}\` |"
	fi
	endgroup
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
	case "${1:-all}" in
		defconfig) prepare_defconfig ;;
		compile)   build_kernel ;;
		modules)   build_modules ;;
		check)     check_output ;;
		all)       prepare_defconfig; build_kernel; build_modules; check_output ;;
		*) die "unknown build step '$1'" ;;
	esac
fi
