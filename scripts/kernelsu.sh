#!/usr/bin/env bash
# Install a KernelSU variant into the kernel tree.
#
# Every variant ships a near-identical kernel/setup.sh that clones itself next
# to the kernel tree and symlinks drivers/kernelsu at it. They differ in three
# ways that matter, all of which are encoded in the registry below:
#
#   * the directory the clone lands in (KernelSU vs KernelSU-Next),
#   * what "no argument" means -- most check out the latest tag, ReSukiSU
#     checks out main,
#   * which ref carries non-GKI support and which carries SUSFS.
#
# The critical safety property: every variant's setup.sh ends its checkout with
#     git checkout "$1" ... || echo "[-] Checkout default branch"
# so an invalid ref does NOT fail the script -- it silently leaves the tree on
# the default branch. A build asking for SukiSU's SUSFS-capable 'builtin'
# branch and typing 'susfs-main' (which does not exist) would quietly produce a
# kernel with no SUSFS at all. So we validate the ref before calling setup.sh
# and verify the checkout afterwards.

set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KERNEL_DIR=${KERNEL_DIR:?KERNEL_DIR must point at the kernel source tree}

# ------------------------------------------------------------- registry -----
#
# Fields, '|'-separated:
#   1 repo URL
#   2 ref the setup.sh script itself is fetched from
#   3 directory setup.sh clones into, relative to the kernel tree
#   4 default ref for modern (>= 5.10) kernels; empty means "let setup.sh pick"
#   5 default ref for legacy (< 5.10) kernels
#   6 refs that already contain SUSFS support (space separated; '-' for none)
#   7 human-readable name
#
# Verified against each repo's live branch/tag list on 2026-07-27.

ksu_registry() {
	case "$1" in
	kernelsu)
		# Official upstream. Dropped non-GKI support at v1.0, so legacy kernels
		# are pinned to the last release that supports them.
		echo "https://github.com/tiann/KernelSU|main|KernelSU||v0.9.5|-|KernelSU" ;;
	kernelsu-next)
		# 'next' was renamed to 'legacy' and the default branch is now 'dev'.
		# Raw URLs containing /next/ only still work via GitHub's rename
		# redirect, so we address the real branches directly.
		echo "https://github.com/KernelSU-Next/KernelSU-Next|dev|KernelSU-Next|dev|legacy|-|KernelSU-Next" ;;
	sukisu-ultra)
		# Repo moved from the personal ShirkNeko account into its own org.
		#
		# 'main' is the modern modular tree and is what legacy kernels should
		# use: it hooks via kprobes plus runtime patching of the syscall table
		# (hook/arm64/syscall_hook.c patches sys_call_table[nr] in place via
		# patch_memory), so it needs NO kernel source patches at all. Its
		# Kconfig only asks for `depends on KPROBES && EXT4_FS`.
		#
		# 'builtin' must not be used here. It is the source-integrated tree, and
		# its kernel/hook/lsm_hook.c defines `is_first_zygote` only under
		# `#if defined(CONFIG_KSU_SUSFS) && defined(KSU_COMPAT_USE_STATIC_KEY)`
		# while runtime/ksud.c uses it under a bare `#ifdef
		# KSU_COMPAT_USE_STATIC_KEY` -- which every 5.4 kernel satisfies. So
		# CONFIG_KSU_SUSFS is mandatory for it to link, and builtin ships no
		# SUSFS sources of its own: it expects susfs4ksu's kernel patch. On this
		# device that patch does not apply -- fs/proc/fd.c hunk #3 fails even at
		# fuzz 3 (the tree's seq_printf has 3 fields, the patch rewrites it to 4
		# to add `ino`), and fs/proc/bootconfig.c does not exist in a 5.4 tree.
		echo "https://github.com/SukiSU-Ultra/SukiSU-Ultra|main|KernelSU|main|main|-|SukiSU-Ultra" ;;
	resukisu)
		# ReSukiSU is a SukiSU-Ultra re-fork specifically maintained for legacy
		# kernels, and it is the only variant here that actually works on 5.4.
		#
		# Unlike SukiSU-Ultra it keeps the pre-5.10 SELinux path: selinux.h
		# defines KSU_COMPAT_USE_SELINUX_STATE only for >= 5.10 (or an explicit
		# backport), and rules.c/selinux_hide.c then use
		# `selinux_state.ss->policydb` / `ss->status_lock` instead of the flat
		# selinux_state.policy/.policy_mutex/.status_lock fields that do not
		# exist before 5.10. It also carries compat/kernel_compat.c with a real
		# fallback chain for renamed APIs (ksu_strncpy_from_user_nofault).
		#
		# The ref choice matters. v4.2.0-rc3 is required, not 'main' and not
		# 'auto-hook':
		#
		#   * With CONFIG_KSU_MANUAL_HOOK, 'main' includes
		#     tools/manual_hook_check.mk unconditionally, which $(error)s unless
		#     ksu_handle_execveat/ksu_handle_faccessat/... already appear in
		#     fs/exec.c, fs/open.c, fs/stat.c and friends -- i.e. unless the
		#     kernel source has already been patched by hand.
		#   * 'auto-hook' softens that (it swaps in tools/auto_hook_detect.mk
		#     and gates the hard check behind `ifneq ($(CONFIG_KALLSYMS_ALL),y)`,
		#     which this kernel satisfies), but it is a moving development branch
		#     whose commit count does not line up with any released manager.
		#   * v4.2.0-rc3 is a tag, and ReSukiSU derives its driver version from
		#     the commit count of the checked-out ref
		#     (KSU_VERSION = 30000 + commits + 700). Measured: auto-hook has
		#     4375 commits -> 35075, v4.2.0-rc3 has 4471 -> 35171, and the
		#     v4.2.0-rc3 manager reports 35171. Building the tag is therefore
		#     what makes the driver version match the manager and clears the
		#     "kernel needs update" notice.
		#
		# The tag has everything the tracepoint hook needs
		# (hook/arm64/syscall_hook.c, syscall_hook_manager.c,
		# syscall_event_bridge.c, tp_marker.c) and registers both __NR_execve
		# and __NR_execveat. It lacks auto_hook.c/inline_hook.c, which is fine:
		# inline hooking cannot work under CONFIG_CFI_CLANG anyway.
		#
		# CONFIG_KSU_TRACEPOINT_HOOK is still not usable unpatched -- its
		# Kbuild $(error)s out on GKI 1.0/Non-GKI -- which is what
		# patches/resukisu_enable_tracepoint.sh exists to fix.
		echo "https://github.com/ReSukiSU/ReSukiSU|main|KernelSU|v4.2.0-rc3|v4.2.0-rc3|-|ReSukiSU" ;;
	rsuntk)
		echo "https://github.com/rsuntk/KernelSU|main|KernelSU|main|main|susfs-rksu-master|RKSU (rsuntk)" ;;
	backslashxx)
		echo "https://github.com/backslashxx/KernelSU|master|KernelSU|master|master|-|backslashxx KernelSU" ;;
	*)
		die "unknown KSU_VARIANT '$1'" ;;
	esac
}

ksu_field() { ksu_registry "$1" | cut -d'|' -f"$2"; }

# ReSukiSU's setup.sh checks out 'main' when given no argument, while every
# other variant checks out the latest tag. Call that out so an unpinned CI
# build is not silently tracking a moving branch.
ksu_default_is_branch() { [ "$1" = "resukisu" ]; }

# ---------------------------------------------------------------- install ---

ksu_install() {
	local variant=$1 requested_ref=${2-}

	[ "$variant" = "none" ] && { info "KernelSU integration disabled"; return 0; }

	local repo setup_ref dir modern_ref legacy_ref susfs_refs name
	IFS='|' read -r repo setup_ref dir modern_ref legacy_ref susfs_refs name <<<"$(ksu_registry "$variant")"

	group "Installing ${name}"
	info "repository: ${repo}"

	# Decide which ref to check out.
	local kver ref=$requested_ref
	kver=$(kernel_version "$KERNEL_DIR" || echo "0.0")
	if [ -z "$ref" ]; then
		if ver_ge "$kver" "5.10"; then
			ref=$modern_ref
		else
			ref=$legacy_ref
			[ -n "$ref" ] && info "kernel ${kver} is pre-GKI; defaulting to ref '${ref}'"
		fi
	fi

	# Validate before handing the ref to setup.sh, which would swallow a typo.
	if [ -n "$ref" ]; then
		info "validating ref '${ref}' exists in ${repo}"
		ref_exists "$repo" "$ref" \
			|| die "ref '${ref}' does not exist in ${repo}.
       setup.sh would silently fall back to the default branch and you would
       get a kernel without the feature you asked for.
       Available branches: $(git ls-remote --heads "$repo" 2>/dev/null | awk '{print $2}' | sed 's@refs/heads/@@' | grep -v dependabot | tr '\n' ' ')"
		ok "ref '${ref}' exists"
	else
		warn "no ref pinned; setup.sh will pick the latest tag. Set KSU_REF for reproducible builds."
	fi

	if [ -z "$requested_ref" ] && ksu_default_is_branch "$variant"; then
		warn "${name}'s setup.sh defaults to the moving 'main' branch rather than a tag."
		warn "Pin KSU_REF (e.g. a tag) if you need reproducible builds."
	fi

	# A vendor tree may already vendor KernelSU as a git submodule (the Xiaomi
	# MIUI trees do), and setup.sh begins with
	#     test -d "$GKI_ROOT/KernelSU" || git clone ... KernelSU
	# so an existing directory is reused rather than cloned. Because source.sh
	# clones --recursive --depth=1, that submodule is shallow: the tag or branch
	# we ask for often is not present, `git checkout` fails, and setup.sh's own
	# `|| echo "[-] Checkout default branch"` swallows it -- leaving the wrong
	# commit with no error. Always start from a clean directory instead.
	if [ -e "${KERNEL_DIR}/${dir}" ]; then
		info "removing pre-existing ${dir}/ so setup.sh clones a fresh ${repo}"
		rm -rf "${KERNEL_DIR}/${dir}"
	fi
	# Same for a stale symlink from a previous run, which would otherwise be
	# left pointing at the directory we just deleted.
	[ -L "${KERNEL_DIR}/drivers/kernelsu" ] && rm -f "${KERNEL_DIR}/drivers/kernelsu"

	# Run the variant's own installer.
	local setup_url="https://raw.githubusercontent.com/${repo#https://github.com/}/${setup_ref}/kernel/setup.sh"
	info "running ${setup_url}"
	(
		cd "$KERNEL_DIR"
		if [ -n "$ref" ]; then
			fetch_stdout "$setup_url" | bash -s "$ref"
		else
			fetch_stdout "$setup_url" | bash
		fi
	) || die "${name} setup.sh failed"

	# --- verify the installer actually did what it claims ------------------
	local ksu_dir="${KERNEL_DIR}/${dir}"
	[ -d "$ksu_dir" ] || die "${name} setup.sh finished but ${dir}/ is missing"

	local link="${KERNEL_DIR}/drivers/kernelsu"
	[ -e "$link" ] || die "drivers/kernelsu symlink was not created"

	# setup.sh only checks whether the word "kernelsu" already appears.  Some
	# vendor trees carry an obsolete line guarded by CONFIG_WITH_KERNEL_SU, so
	# setup.sh reports success without adding the CONFIG_KSU rule and the final
	# link fails with every ksu_handle_* symbol undefined.  Normalize any stale
	# rule to the symbol declared by the installed Kconfig.
	local driver_makefile="${KERNEL_DIR}/drivers/Makefile"
	if ! grep -qE '^[[:space:]]*obj-\$\(CONFIG_KSU\)[[:space:]]*\+=[[:space:]]*kernelsu/?[[:space:]]*$' "$driver_makefile"; then
		if grep -qE '^[[:space:]]*obj-\$\(CONFIG_[A-Z0-9_]+\)[[:space:]]*\+=[[:space:]]*kernelsu/?[[:space:]]*$' "$driver_makefile"; then
			sed -i -E 's@^[[:space:]]*obj-\$\(CONFIG_[A-Z0-9_]+\)[[:space:]]*\+=[[:space:]]*kernelsu/?[[:space:]]*$@obj-$(CONFIG_KSU) += kernelsu/@' "$driver_makefile"
			warn "normalized stale drivers/Makefile KernelSU guard to CONFIG_KSU"
		else
			printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >>"$driver_makefile"
			warn "added missing CONFIG_KSU rule to drivers/Makefile"
		fi
	fi

	grep -qE '^[[:space:]]*obj-\$\(CONFIG_KSU\)[[:space:]]*\+=[[:space:]]*kernelsu/?[[:space:]]*$' "$driver_makefile" \
		|| die "drivers/Makefile was not wired to CONFIG_KSU for kernelsu"
	grep -q 'drivers/kernelsu/Kconfig' "${KERNEL_DIR}/drivers/Kconfig" \
		|| die "drivers/Kconfig was not wired up for kernelsu"

	# --- fix includes that assume a newer kernel than we are building --------
	#
	# <linux/pgtable.h> was split out of <asm/pgtable.h> in Linux 5.8. SukiSU's
	# 'main' branch includes it unconditionally in feature/sucompat.c, so on a
	# 5.4 kernel the build dies with:
	#     fatal error: 'linux/pgtable.h' file not found
	#
	# That file needs nothing from it -- the only relevant calls it makes are
	# kern_path() and path_put(), declared in linux/namei.h and linux/path.h,
	# both of which it already includes. So drop the include, but only when the
	# kernel actually lacks the header, and only for the KernelSU source, so a
	# future fork that genuinely needs it is unaffected.
	ksu_fix_legacy_includes "$ksu_dir" "$kver"
	ksu_fix_legacy_symbols "$ksu_dir" "$kver"

	# Confirm we landed on the ref we asked for, catching the silent fallback.
	local head_desc head_sha
	head_sha=$(git -C "$ksu_dir" rev-parse --short HEAD)
	head_desc=$(git -C "$ksu_dir" describe --tags --always 2>/dev/null || echo "$head_sha")
	if [ -n "$ref" ]; then
		local want
		want=$(git -C "$ksu_dir" rev-parse --verify --quiet "$ref^{commit}" 2>/dev/null || true)
		if [ -n "$want" ] && [ "$want" != "$(git -C "$ksu_dir" rev-parse HEAD)" ]; then
			die "${name} is checked out at ${head_desc}, not the requested ref '${ref}'"
		fi
	fi
	ok "${name} installed at ${head_desc} (${head_sha})"

	# --- publish facts the later steps need --------------------------------
	local count version_label
	count=$(git -C "$ksu_dir" rev-list --count HEAD 2>/dev/null || echo 0)
	if git -C "$ksu_dir" describe --exact-match --tags >/dev/null 2>&1; then
		version_label=$(git -C "$ksu_dir" describe --exact-match --tags)
	else
		version_label="${ref:-HEAD}-${head_sha}"
	fi

	export_env KSU_DIR "$dir"
	export_env KSU_NAME "$name"
	export_env KSU_REF_RESOLVED "${ref:-<latest-tag>}"
	export_env KSU_VERSION_LABEL "$version_label"
	export_env KSU_COMMIT_COUNT "$count"
	export_env KSU_SUSFS_BUNDLED_REFS "$susfs_refs"
	export_env UPLOADNAME "-${name// /_}_${version_label}"

	ksu_resolve_hook_mode "${KSU_HOOK_MODE:-auto}" "$kver"

	summary "| KernelSU variant | \`${name}\` |"
	summary "| KernelSU ref | \`${ref:-latest tag}\` -> \`${version_label}\` |"

	endgroup
}

# -------------------------------------------------- legacy include repair ---
#
# Modern KernelSU forks assume a fairly new kernel and include headers that were
# split out of older catch-all headers long after 5.4. Building them against a
# 5.4 tree then fails at the first include with 'file not found', before any of
# the interesting logic is even compiled.
#
# Each case below is checked against the kernel tree that is actually being
# built, and only rewritten when the header is genuinely absent, so a fork that
# does need the new header (on a kernel that has it) is left alone.
ksu_fix_legacy_includes() {
	local ksu_dir=$1 kver=$2
	local file line fixed=0

	# <linux/pgtable.h> -- split out of <asm/pgtable.h> in Linux 5.8.
	#
	# SukiSU 'main' includes it in feature/sucompat.c, which uses nothing from
	# it: the only relevant calls are kern_path() and path_put(), declared in
	# linux/namei.h and linux/path.h, both of which that file already includes.
	file="${ksu_dir}/kernel/feature/sucompat.c"
	if [ -f "$file" ] && [ ! -f "${KERNEL_DIR}/include/linux/pgtable.h" ] &&
	   grep -q 'linux/pgtable\.h' "$file"; then
		sed -i -E 's@^[[:space:]]*#include[[:space:]]+<linux/pgtable\.h>.*$@/* linux/pgtable.h does not exist before 5.8 (it was part of asm/pgtable.h) and\n * nothing here needs it: kern_path()/path_put() come from linux/namei.h and\n * linux/path.h, which are included above. */@' "$file"
		warn "removed the <linux/pgtable.h> include from $(basename "$file") for kernel ${kver}"
		fixed=$((fixed + 1))
	fi

	# <linux/hex.h> -- introduced in Linux 5.9; bin2hex() lived in linux/kernel.h
	# before that, and every file here already includes linux/kernel.h.
	file="${ksu_dir}/kernel/manager/apk_sign.c"
	if [ -f "$file" ] && [ ! -f "${KERNEL_DIR}/include/linux/hex.h" ] &&
	   grep -q 'linux/hex\.h' "$file"; then
		sed -i -E 's@^[[:space:]]*#include[[:space:]]+<linux/hex\.h>.*$@/* linux/hex.h appeared in 5.9; bin2hex() is in linux/kernel.h before that,\n * which this file already includes. */@' "$file"
		warn "removed the <linux/hex.h> include from $(basename "$file") for kernel ${kver}"
		fixed=$((fixed + 1))
	fi

	[ "$fixed" -gt 0 ] && info "adjusted ${fixed} include(s) for kernel ${kver}"
	return 0
}

# ------------------------------------------- legacy API compatibility shim ---
#
# Some functions the modern forks call were *renamed* rather than removed, so
# unlike the includes above there is no way to fix this by deleting a line --
# every call site uses the new name.
#
# strncpy_from_user_nofault() is strncpy_from_unsafe_user() renamed in Linux
# 5.8 (commit bd88bb5d4007949be7154deae7cef7173c751a95). Both are
# pagefault-disabled user copies with an identical signature and identical
# return convention, so on a kernel that predates the rename the old symbol is
# exactly the right implementation.
#
# Rather than rewriting five call sites across three files, force-include a
# small header that provides the new name. The file is placed in the KernelSU
# tree (never the kernel tree) and wired in with ccflags-y, which is how the
# fork already injects its own definitions.
ksu_fix_legacy_symbols() {
	local ksu_dir=$1 kver=$2
	local kbuild="${ksu_dir}/kernel/Kbuild"

	[ -f "$kbuild" ] || return 0

	local need_nofault=0 need_twa=0 need_copy_nofault=0
	local uaccess="${KERNEL_DIR}/include/linux/uaccess.h"
	local twh="${KERNEL_DIR}/include/linux/task_work.h"

	# --- strncpy_from_user_nofault (renamed in 5.8) -------------------------
	if [ -f "$uaccess" ] && ! grep -q 'strncpy_from_user_nofault' "$uaccess"; then
		if grep -rql 'strncpy_from_user_nofault' "${ksu_dir}/kernel" 2>/dev/null; then
			if grep -q 'strncpy_from_unsafe_user' "$uaccess"; then
				need_nofault=1
			else
				warn "the fork calls strncpy_from_user_nofault but ${kver} declares neither it nor strncpy_from_unsafe_user"
			fi
		fi
	fi

	# --- copy_from_user_nofault / copy_to_user_nofault (renamed in 5.8) -----
	# Same 5.8 rename batch as strncpy above: copy_{from,to}_user_nofault() were
	# called probe_user_read() and probe_user_write() before it, and the
	# signatures are identical. Without this the kernel compiles in full and
	# then fails at the very last step:
	#     ld.lld: error: undefined symbol: copy_to_user_nofault
	if [ -f "$uaccess" ] && ! grep -q 'copy_from_user_nofault' "$uaccess"; then
		if grep -rql 'copy_from_user_nofault\|copy_to_user_nofault' "${ksu_dir}/kernel" 2>/dev/null; then
			if grep -q 'probe_user_read' "${KERNEL_DIR}/include/linux/uaccess.h" 2>/dev/null ||
			   grep -q 'probe_user_read' "${KERNEL_DIR}/mm/maccess.c" 2>/dev/null; then
				need_copy_nofault=1
			else
				warn "the fork calls copy_{from,to}_user_nofault but ${kver} declares neither them nor probe_user_{read,write}"
			fi
		fi
	fi

	# --- TWA_RESUME (enum added in 5.8) -------------------------------------
	# Only shadowed when the fork actually uses TWA_RESUME and the kernel has
	# the pre-enum bool form. TWA_SIGNAL is intentionally not provided.
	if [ -f "$twh" ] && ! grep -q 'TWA_RESUME' "$twh"; then
		if grep -rql 'TWA_RESUME' "${ksu_dir}/kernel" 2>/dev/null; then
			if grep -q 'task_work_add' "$twh"; then
				need_twa=1
			else
				warn "the fork uses TWA_RESUME but ${kver} has no task_work_add"
			fi
		fi
	fi

	[ "$need_nofault" -eq 1 ] || [ "$need_twa" -eq 1 ] || [ "$need_copy_nofault" -eq 1 ] || return 0

	local hdr="${ksu_dir}/kernel/include/ksu_legacy_compat.h"
	cat >"$hdr" <<'EOF'
/* Generated by KernelSU_Action for kernels that predate a rename or an enum.
 *
 * 1. strncpy_from_user_nofault() is strncpy_from_unsafe_user() renamed in Linux
 *    5.8 (commit bd88bb5d4007949be7154deae7cef7173c751a95). The signature and
 *    the pagefault-disabled semantics are identical, so the old symbol is a
 *    faithful implementation of the new name.
 *
 * 2. copy_from_user_nofault() and copy_to_user_nofault() are the same 5.8
 *    rename batch: they were probe_user_read() and probe_user_write() before
 *    it. Signatures are identical (the newer to_user form adds `notrace`,
 *    which a macro alias does not need).
 *
 * 3. task_work_add()'s third argument became `enum task_work_notify_mode` in
 *    Linux 5.8 (commit 91989c707884ecc7cd537281ab1a4b8fb7219da3), which is
 *    where TWA_RESUME/TWA_SIGNAL were introduced. Before that it was a plain
 *    `bool notify`, and `true` meant exactly "notify on resume" -- i.e.
 *    TWA_RESUME. TWA_SIGNAL did not exist and cannot be emulated, so it is
 *    deliberately left undefined: if a future fork relies on it, the build must
 *    fail loudly rather than silently changing task_work semantics.
 */
#ifndef __KSU_LEGACY_COMPAT_H
#define __KSU_LEGACY_COMPAT_H

#include <linux/uaccess.h>
#include <linux/task_work.h>
#include <linux/version.h>

#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 8, 0)
EOF

	if [ "$need_nofault" -eq 1 ]; then
		cat >>"$hdr" <<'EOF'
#ifndef strncpy_from_user_nofault
#define strncpy_from_user_nofault(dst, src, count) \
	strncpy_from_unsafe_user((dst), (const void __user *)(src), (count))
#endif
EOF
	fi

	if [ "$need_copy_nofault" -eq 1 ]; then
		cat >>"$hdr" <<'EOF'
#ifndef copy_from_user_nofault
#define copy_from_user_nofault(dst, src, size) \
	probe_user_read((dst), (const void __user *)(src), (size))
#endif
#ifndef copy_to_user_nofault
#define copy_to_user_nofault(dst, src, size) \
	probe_user_write((void __user *)(dst), (src), (size))
#endif
EOF
	fi

	if [ "$need_twa" -eq 1 ]; then
		cat >>"$hdr" <<'EOF'
#ifndef TWA_RESUME
#define TWA_RESUME true
#endif
EOF
	fi

	cat >>"$hdr" <<'EOF'
#endif

#endif /* __KSU_LEGACY_COMPAT_H */
EOF

	# Wire it in only once, and only if that line is not already present.
	#
	# The fork's own source-directory variable has to be used, and its name is
	# not the same across forks:
	#
	#   SukiSU-Ultra  defines $(KSU_KERNEL_DIR) in kernel/Kbuild
	#   ReSukiSU      defines $(KSU_SRC), and never defines KSU_KERNEL_DIR
	#
	# Referencing the wrong one expands to empty and the compiler is handed
	# "/include/ksu_legacy_compat.h", which fails as
	#     error: '/include/ksu_legacy_compat.h' file not found
	# -- so pick whichever the Kbuild actually defines, and refuse to write a
	# line at all if neither is present rather than emit a broken path.
	local dirvar=""
	if grep -qE '^[[:space:]]*KSU_KERNEL_DIR[[:space:]]*:?=' "$kbuild"; then
		dirvar="KSU_KERNEL_DIR"
	elif grep -qE '^[[:space:]]*KSU_SRC[[:space:]]*:?=' "$kbuild"; then
		dirvar="KSU_SRC"
	fi

	if [ -z "$dirvar" ]; then
		die "cannot work out the KernelSU source-directory variable in ${kbuild}.
       Neither KSU_KERNEL_DIR nor KSU_SRC is defined there, so a
       force-include of ksu_legacy_compat.h cannot be expressed and the build
       would fail with a path of the form /include/ksu_legacy_compat.h.
       Add the right variable name to this check."
	fi

	if ! grep -q 'ksu_legacy_compat\.h' "$kbuild"; then
		printf '\n# Generated by KernelSU_Action: legacy symbol compatibility.\n' >>"$kbuild"
		printf 'ccflags-y += -include $(%s)/include/ksu_legacy_compat.h\n' "$dirvar" >>"$kbuild"
	fi
	info "force-including the compat header via \$(${dirvar})"

	local what=""
	[ "$need_nofault" -eq 1 ] && what="strncpy_from_user_nofault"
	[ "$need_copy_nofault" -eq 1 ] && what="${what:+${what}, }copy_{from,to}_user_nofault"
	[ "$need_twa" -eq 1 ] && what="${what:+${what}, }TWA_RESUME"
	warn "added a ${what} shim for kernel ${kver}"
	return 0
}

# ------------------------------------------------------------ hook config ---
#
# Which hook mechanism a variant should use is genuinely version- and
# fork-specific. 'auto' picks the option that the variant actually declares.

# Resolve 'auto' into a concrete mode and publish it.
#
# This has to happen once, early, and be reused by BOTH the source-patching
# step and the defconfig step. Resolving it independently in each place is how
# you end up setting CONFIG_KSU_MANUAL_HOOK on a tree whose syscall entry
# points were never actually patched -- which builds fine and then does
# nothing at runtime.
ksu_resolve_hook_mode() {
	local mode=${1:-auto} kver=$2
	if [ "$mode" = "auto" ]; then
		if ver_ge "$kver" "5.10"; then
			mode="kprobes"
		else
			# kprobes on pre-GKI kernels is the classic source of "KernelSU
			# installed but su does nothing" reports; manual hooks are patched
			# straight into the syscall entry points instead.
			mode="manual"
		fi
		info "hook mode 'auto' resolved to '${mode}' for kernel ${kver}"
	fi
	export_env KSU_HOOK_MODE_RESOLVED "$mode"
}

ksu_hook_configs() {
	local variant=$1 mode=$2 defconfig=$3 kver=$4

	if [ "$mode" = "auto" ]; then
		[ -n "${KSU_HOOK_MODE_RESOLVED:-}" ] || ksu_resolve_hook_mode "$mode" "$kver"
		mode=$KSU_HOOK_MODE_RESOLVED
	fi

	case "$mode" in
	none) return 0 ;;
	kprobes)
		kconf_enable "$defconfig" CONFIG_MODULES
		kconf_enable "$defconfig" CONFIG_KPROBES
		kconf_enable "$defconfig" CONFIG_HAVE_KPROBES
		kconf_enable "$defconfig" CONFIG_KPROBE_EVENTS
		kconf_enable "$defconfig" CONFIG_KRETPROBES
		# Only kernelsu-next declares this symbol; the others implement their
		# kprobe hooks unconditionally. Written as an if rather than
		# `[ ... ] && cmd` on purpose: when the test is false the compound
		# command returns 1, and this function is called as a plain command
		# from prepare_defconfig under `set -e`, so the whole build aborted
		# with no diagnostic at all.
		if [ "$variant" = "kernelsu-next" ]; then
			kconf_enable "$defconfig" CONFIG_KSU_KPROBES_HOOK
		fi
		;;
	manual)
		case "$variant" in
			kernelsu-next)  kconf_enable "$defconfig" CONFIG_KSU_MANUAL_HOOK ;;
			sukisu-ultra)
				kconf_enable "$defconfig" CONFIG_KSU_MANUAL_HOOK ;;
			resukisu)
				# ReSukiSU's non-GKI static export check requires the complete
				# kallsyms table unless every internal SELinux symbol is exported
				# manually by the vendor tree.
				kconf_set_many "$defconfig" \
					CONFIG_KSU_MANUAL_HOOK=y CONFIG_DEBUG_KERNEL=y \
					CONFIG_KALLSYMS=y CONFIG_KALLSYMS_ALL=y ;;
			*) : ;;  # tiann/KernelSU 0.9.x infers manual hooks from the source patch
		esac
		;;
	tracepoint)
		[ "$variant" = "resukisu" ] || [ "$variant" = "sukisu-ultra" ] \
			|| warn "hook mode 'tracepoint' is only declared by ReSukiSU/SukiSU-Ultra; ignoring for ${variant}"
		kconf_enable "$defconfig" CONFIG_KSU_TRACEPOINT_HOOK
		;;
	syscall)
		kconf_enable "$defconfig" CONFIG_KSU_SYSCALL_HOOK
		;;
	runtime)
		# Variants that install their own hooks at runtime and therefore need
		# NO kernel source patching. SukiSU-Ultra's 'main' branch is the case
		# this exists for: it registers kretprobes and patches sys_call_table
		# in place (kernel/hook/arm64/syscall_hook.c -> patch_memory), driven
		# by CONFIG_KPROBES plus the syscall tracepoints.
		#
		# It must NOT be treated as 'manual'. That resolved mode makes
		# hooks_patch_apply() run patches/legacy_ksu_hooks.sh, which externs
		# ksu_handle_execveat, ksu_handle_vfs_read, ksu_vfs_read_hook and
		# ksu_input_hook. 'main' defines none of those -- it has no such
		# functions, and its ksu_handle_faccessat takes (orig_nr, regs) rather
		# than the legacy (dfd, filename, mode, flags) -- so the kernel would
		# fail to link. 'auto' picks 'manual' for every pre-5.10 kernel, which
		# is exactly why this has to be selected explicitly.
		case "$variant" in
			sukisu-ultra)
				kconf_set_many "$defconfig" \
					CONFIG_KPROBES=y CONFIG_HAVE_KPROBES=y \
					CONFIG_KPROBE_EVENTS=y CONFIG_KRETPROBES=y \
					CONFIG_HAVE_SYSCALL_TRACEPOINTS=y CONFIG_TRACEPOINTS=y ;;
			*)
				warn "hook mode 'runtime' is only meaningful for variants that hook at runtime (sukisu-ultra); ignoring for ${variant}" ;;
		esac
		;;
	esac
}

# Only run the installer when sourced as a script entry point.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
	ksu_install "${KSU_VARIANT:-none}" "${KSU_REF:-}"
fi
