#!/usr/bin/env bash
# Resolve the build configuration, validate it, and export it to later steps.
#
# Resolution order (last wins):
#   1. built-in defaults below
#   2. the config file named by CONFIG_ENV (default: config.env)
#   3. workflow_dispatch inputs, passed in as IN_<KEY> environment variables
#
# The old workflow parsed config.env with
#     grep -w "$KEY" config.env | head -n1 | cut -d= -f2
# which truncates any value containing '=', matches commented-out lines, and
# matches a key that merely appears as a substring of a comment. That is why
# EXTRA_CMDS had to use a ':' separator. Both forms are still accepted here,
# but parsing is now anchored and comment-aware, so '=' in values is fine.

set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CONFIG_FILE=${CONFIG_ENV:-config.env}

# --------------------------------------------------------------- defaults ---

declare -A DEFAULTS=(
	[KERNEL_SOURCE]=""
	[KERNEL_SOURCE_BRANCH]=""
	[KERNEL_CONFIG]=""
	# Extra config fragments merged after KERNEL_CONFIG, space separated, e.g.
	# "vendor/xiaomi_QGKI.config vendor/star_QGKI.config". Qualcomm trees split
	# device options across such files (make's %.config target runs
	# merge_config.sh for each one). KERNEL_CONFIG itself must stay a single
	# path: it also names the device and is edited in place.
	[KERNEL_CONFIG_FRAGMENTS]=""
	# Symbols that must survive into the resolved .config, space separated,
	# written as CONFIG_X=y or bare CONFIG_X ("must be set"). A fragment that
	# does not apply, or a symbol whose dependency is unmet, is dropped
	# silently -- which is how a build "succeeds" while shipping a kernel with
	# no KernelSU in it. This turns that into a hard failure.
	[KERNEL_REQUIRED_CONFIG]=""
	# Appended to KERNEL_REQUIRED_CONFIG rather than replacing it, so a profile
	# that layers on another via INCLUDE can add its own assertions without
	# having to restate (and risk drifting from) the base list.
	[KERNEL_REQUIRED_CONFIG_EXTRA]=""
	[KERNEL_IMAGE_NAME]="Image.gz-dtb"
	[ARCH]="arm64"
	[KERNEL_NAME]=""
	[ADD_LOCALVERSION_TO_FILENAME]="false"
	[EXTRA_CMDS]=""
	[CUSTOM_CMDS]=""

	# Toolchain
	[USE_CUSTOM_CLANG]="false"
	[CUSTOM_CLANG_SOURCE]=""
	[CUSTOM_CLANG_BRANCH]=""
	[CLANG_BRANCH]="main-kernel-2025"
	[CLANG_VERSION]="r547379"
	[USE_LLVM]="false"
	[ENABLE_GCC_ARM64]="false"
	[ENABLE_GCC_ARM32]="false"
	[USE_CUSTOM_GCC_64]="false"
	[CUSTOM_GCC_64_SOURCE]=""
	[CUSTOM_GCC_64_BRANCH]=""
	[CUSTOM_GCC_64_BIN]="aarch64-linux-android-"
	[USE_CUSTOM_GCC_32]="false"
	[CUSTOM_GCC_32_SOURCE]=""
	[CUSTOM_GCC_32_BRANCH]=""
	[CUSTOM_GCC_32_BIN]="arm-linux-androideabi-"

	# KernelSU
	[KSU_VARIANT]="none"
	[KSU_REF]=""
	[KSU_HOOK_MODE]="auto"
	# Set false to force source hook patches even for a variant that normally
	# installs its hooks at runtime (see hooks_patch_apply in patches.sh).
	[KSU_HOOKS_AUTO_HOOKED]="true"
	# Enable ReSukiSU's tracepoint syscall hook on a non-GKI 2.0 kernel by
	# neutralising its GKI-2.0-only Kbuild guard. Needed on CONFIG_CFI_CLANG
	# kernels, where the inline-hook path cannot install (see
	# resukisu_kernel_tp_fix in patches.sh).
	[KSU_RESUKISU_KERNEL_TP_FIX]="false"
	[KSU_EXPECTED_SIZE]=""
	[KSU_EXPECTED_HASH]=""

	# Patches
	[ENABLE_SUSFS]="false"
	[SUSFS_REPO]="https://gitlab.com/simonpunk/susfs4ksu.git"
	[SUSFS_BRANCH]="auto"
	[ENABLE_PATH_UMOUNT]="false"
	[ENABLE_HIDE_STUFF]="false"
	[ENABLE_KPM]="false"
	# Some Qualcomm trees pin the watchdog bark/pet time with a single-value
	# Kconfig `range`, which silently overrides whatever the defconfig asks for.
	[ENABLE_WATCHDOG_RELAX]="false"
	[WATCHDOG_BARK_TIME]="20000"
	[WATCHDOG_PET_TIME]="15000"

	# Kconfig tweaks
	[ADD_KPROBES_CONFIG]="false"
	[ADD_OVERLAYFS_CONFIG]="false"
	[DISABLE_LTO]="false"
	[DISABLE_CC_WERROR]="false"
	[EXTRA_DEFCONFIG]=""

	# Packaging
	[USE_CUSTOM_ANYKERNEL3]="false"
	[CUSTOM_ANYKERNEL3_SOURCE]=""
	[CUSTOM_ANYKERNEL3_BRANCH]=""
	[NEED_DTBO]="false"
	[BUILD_BOOT_IMG]="false"
	[SOURCE_BOOT_IMAGE]=""

	# Compile the tree's loadable modules and ship them as an overlay package.
	[BUILD_MODULES]="false"

	# Runner
	[ENABLE_CCACHE]="true"
	[REMOVE_UNUSED_PACKAGES]="true"
)

# Legacy spellings that must keep working for existing forks' config.env files.
declare -A ALIASES=(
	[DISABLE-LTO]="DISABLE_LTO"
	[KERNELSU_TAG]="KSU_REF"
	[APPLY_KSU_PATCH]="_LEGACY_APPLY_KSU_PATCH"
	[ENABLE_KERNELSU]="_LEGACY_ENABLE_KERNELSU"
)

# ----------------------------------------------------------------- parsing ---

# cfg_read FILE KEY -- first non-comment "KEY=value" or "KEY:value" line.
cfg_read() {
	local file=$1 key=$2
	[ -f "$file" ] || return 0
	sed -nE "s/\r$//; s/^[[:space:]]*${key}[[:space:]]*[=:][[:space:]]*(.*)$/\1/p" "$file" \
		| head -n1 \
		| sed -E 's/[[:space:]]+$//'
}

# A profile may begin with `INCLUDE=<path>` to layer on top of another profile,
# which keeps device profiles that differ only in the KernelSU choice from
# duplicating two hundred lines that must otherwise be kept in sync by hand.
#
# Resolution order, lowest priority first: the included file, then the file
# itself, then workflow inputs. The include is a plain single level (no
# chaining) and its path is relative to the including file's directory.
cfg_include_of() {
	local file=$1
	local inc
	inc=$(cfg_read "$file" INCLUDE)
	[ -n "$inc" ] || return 0
	case "$inc" in
		/*) printf '%s' "$inc" ;;
		*)  printf '%s/%s' "$(dirname "$file")" "$inc" ;;
	esac
}

# cfg_get FILE KEY -- value for KEY honouring that file's INCLUDE.
# The file itself wins; the included file is the fallback. That ordering is
# what makes an INCLUDE-ing profile able to override just a few keys.
cfg_get() {
	local file=$1 key=$2 inc val
	val=$(cfg_read "$file" "$key")
	[ -n "$val" ] && { printf '%s' "$val"; return 0; }
	inc=$(cfg_include_of "$file")
	[ -n "$inc" ] && cfg_read "$inc" "$key"
}

resolve() {
	local key val
	for key in "${!DEFAULTS[@]}"; do
		val=${DEFAULTS[$key]}

		local from_file
		from_file=$(cfg_get "$CONFIG_FILE" "$key")
		[ -n "$from_file" ] && val=$from_file

		# Workflow inputs win over the file, but only when actually provided.
		#
		# The sentinel "config" means "leave the config file's value alone".
		# The dispatch form needs it because a GitHub boolean input always has
		# a concrete value: with a plain checkbox defaulting to false, a user
		# who set ENABLE_SUSFS=true in their profile and then ran the form
		# without touching anything would silently get SUSFS turned back off.
		local in_var="IN_${key}"
		local in_val=${!in_var:-}
		if [ -n "$in_val" ] && [ "$in_val" != "config" ]; then
			val=$in_val
		fi

		CFG[$key]=$val
	done

	# Fold legacy keys in only where the modern key was not already set.
	local legacy modern
	for legacy in "${!ALIASES[@]}"; do
		modern=${ALIASES[$legacy]}
		local lv
		lv=$(cfg_get "$CONFIG_FILE" "$legacy")
		[ -n "$lv" ] || continue
		case "$modern" in
			_LEGACY_*) CFG[$modern]=$lv ;;
			*)
				# Only honour the legacy spelling when the modern one is absent
				# from the file and no input overrode it.
				local mv in_var="IN_${modern}"
				mv=$(cfg_get "$CONFIG_FILE" "$modern")
				if [ -z "$mv" ] && [ -z "${!in_var:-}" ]; then
					CFG[$modern]=$lv
					debug "legacy key ${legacy} -> ${modern}=${lv}"
				fi
				;;
		esac
	done
}

# --------------------------------------------- legacy compatibility bridge ---

# Old config.env used ENABLE_KERNELSU=true plus KERNELSU_TAG to mean
# "install tiann/KernelSU". Translate that into the new variant selector so
# existing forks keep building without editing anything.
apply_legacy_bridge() {
	local legacy_enable=${CFG[_LEGACY_ENABLE_KERNELSU]:-}
	local legacy_patch=${CFG[_LEGACY_APPLY_KSU_PATCH]:-}

	if [ "${CFG[KSU_VARIANT]}" = "none" ] && is_true "$legacy_enable"; then
		CFG[KSU_VARIANT]="kernelsu"
		warn "config.env uses the legacy ENABLE_KERNELSU flag; treating it as KSU_VARIANT=kernelsu."
		warn "Set KSU_VARIANT explicitly to pick a fork (kernelsu-next, sukisu-ultra, resukisu, ...)."
	fi

	# APPLY_KSU_PATCH used to mean "run the bundled sed script to add manual
	# hooks". That is now the 'manual' hook mode.
	if is_true "$legacy_patch" && [ "${CFG[KSU_HOOK_MODE]}" = "auto" ]; then
		CFG[KSU_HOOK_MODE]="manual"
		warn "config.env uses the legacy APPLY_KSU_PATCH flag; treating it as KSU_HOOK_MODE=manual."
	fi

	unset 'CFG[_LEGACY_ENABLE_KERNELSU]' 'CFG[_LEGACY_APPLY_KSU_PATCH]'
}

# -------------------------------------------------------------- validation ---

validate() {
	local errors=0
	_err() { warn "config: $*"; errors=$((errors + 1)); }

	[ -n "${CFG[KERNEL_SOURCE]}" ]        || _err "KERNEL_SOURCE is required"
	[ -n "${CFG[KERNEL_SOURCE_BRANCH]}" ] || _err "KERNEL_SOURCE_BRANCH is required"
	[ -n "${CFG[KERNEL_CONFIG]}" ]        || _err "KERNEL_CONFIG is required"
	case "${CFG[KERNEL_CONFIG]}" in
		*" "*) _err "KERNEL_CONFIG must be a single path; put additional fragments in KERNEL_CONFIG_FRAGMENTS" ;;
	esac
	local _frag
	for _frag in ${CFG[KERNEL_CONFIG_FRAGMENTS]}; do
		case "$_frag" in
			*" "*) _err "KERNEL_CONFIG_FRAGMENTS entries must not contain spaces" ;;
		esac
	done
	[ -n "${CFG[KERNEL_IMAGE_NAME]}" ]    || _err "KERNEL_IMAGE_NAME is required"

	case "${CFG[ARCH]}" in
		arm64 | arm | x86_64 | riscv) ;;
		*) _err "ARCH must be one of arm64/arm/x86_64/riscv (got '${CFG[ARCH]}')" ;;
	esac

	case "${CFG[KSU_VARIANT]}" in
		none | kernelsu | kernelsu-next | sukisu-ultra | resukisu | rsuntk | backslashxx) ;;
		*) _err "unknown KSU_VARIANT '${CFG[KSU_VARIANT]}'" ;;
	esac

	case "${CFG[KSU_HOOK_MODE]}" in
		auto | kprobes | manual | tracepoint | syscall | runtime | none) ;;
		*) _err "unknown KSU_HOOK_MODE '${CFG[KSU_HOOK_MODE]}'" ;;
	esac

	if [ "${CFG[KSU_VARIANT]}" = "none" ]; then
		is_true "${CFG[ENABLE_SUSFS]}" &&
			_err "ENABLE_SUSFS requires a KSU_VARIANT other than 'none'"
		is_true "${CFG[ENABLE_KPM]}" &&
			_err "ENABLE_KPM requires KSU_VARIANT=sukisu-ultra"
	fi

	# KPM is a SukiSU-Ultra feature and its patch_linux tool is 64-bit only.
	if is_true "${CFG[ENABLE_KPM]}"; then
		[ "${CFG[KSU_VARIANT]}" = "sukisu-ultra" ] ||
			_err "ENABLE_KPM is only supported with KSU_VARIANT=sukisu-ultra (got '${CFG[KSU_VARIANT]}')"
		[ "${CFG[ARCH]}" = "arm64" ] ||
			_err "ENABLE_KPM requires ARCH=arm64"
	fi

	if is_true "${CFG[BUILD_BOOT_IMG]}" && [ -z "${CFG[SOURCE_BOOT_IMAGE]}" ]; then
		_err "BUILD_BOOT_IMG=true requires SOURCE_BOOT_IMAGE"
	fi

	if is_true "${CFG[USE_CUSTOM_CLANG]}" && [ -z "${CFG[CUSTOM_CLANG_SOURCE]}" ]; then
		_err "USE_CUSTOM_CLANG=true requires CUSTOM_CLANG_SOURCE"
	fi

	if is_true "${CFG[USE_CUSTOM_ANYKERNEL3]}" && [ -z "${CFG[CUSTOM_ANYKERNEL3_SOURCE]}" ]; then
		_err "USE_CUSTOM_ANYKERNEL3=true requires CUSTOM_ANYKERNEL3_SOURCE"
	fi

	if is_true "${CFG[ENABLE_WATCHDOG_RELAX]}"; then
		case "${CFG[WATCHDOG_BARK_TIME]}" in
			'' | *[!0-9]*) _err "WATCHDOG_BARK_TIME must be a number of milliseconds" ;;
		esac
		case "${CFG[WATCHDOG_PET_TIME]}" in
			'' | *[!0-9]*) _err "WATCHDOG_PET_TIME must be a number of milliseconds" ;;
		esac
	fi

	[ "$errors" -eq 0 ] || die "${errors} configuration error(s); fix ${CONFIG_FILE} or the workflow inputs"
}

# ------------------------------------------------------------------- main ---

declare -A CFG
resolve
apply_legacy_bridge
validate

# Derive the device label from the defconfig name, as before.
DEVICE=$(printf '%s' "${CFG[KERNEL_CONFIG]}" | sed 's!.*/!!; s/_defconfig$//; s/_user$//; s/-perf$//')
[ -n "${CFG[KERNEL_NAME]}" ] && DEVICE=${CFG[KERNEL_NAME]}
CFG[DEVICE]=$DEVICE

summary "### Build configuration"
summary ""
summary "| Item | Value |"
summary "| --- | --- |"

group "Resolved configuration"
for key in $(printf '%s\n' "${!CFG[@]}" | sort); do
	printf '  %-32s = %s\n' "$key" "${CFG[$key]}"
	export_env "$key" "${CFG[$key]}"
done
endgroup

export_env BUILD_TIME "$(TZ=${BUILD_TZ:-Asia/Shanghai} date '+%Y%m%d%H%M')"

ok "configuration resolved (device: ${DEVICE})"
