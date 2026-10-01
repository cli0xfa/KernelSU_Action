#!/usr/bin/env bash
# =============================================================================
# Bisect why the ReSukiSU v4.2.0-rc3 kernel does not boot on this device.
#
# The auto-hook branch builds AND boots; the v4.2.0-rc3 tag builds but falls
# through to recovery. The tag has the UAPI version the current manager wants
# (4 vs auto-hook's 2), so being unable to boot it is what forces the manager to
# hide the Modules and Superuser tabs.
#
# Rather than guess from a code diff, disable the additions one at a time and
# test each build. Each switch below corresponds to a concrete difference found
# between the two trees:
#
#   APP_PROFILE_INIT   core/init.c calls ksu_app_profile_init(), which auto-hook
#                      never calls. New init path; if it faults, init dies.
#   MODULE_LOAD_FILTER core/init.c calls ksu_module_load_filter_hook_init(), and
#                      feature/module_load_filter.o is compiled unconditionally
#                      (there is no Kconfig for it). It installs its own
#                      syscall-table hooks for init_module/finit_module.
#   SESSION_KEYRING    setup_ksu_cred() calls ksu_get_session_keyring()
#                      unconditionally, where auto-hook only did so under
#                      KSU_COMPAT_REQUIRE_SESSION_KEYRING.
#   PUT_CRED_GUARD     kernel_exit() calls put_cred(ksu_cred) unconditionally,
#                      where auto-hook guarded with `if (ksu_cred)`.
#
# Usage: bisect_rc3_boot.sh <KernelSU-dir> <switch>[,<switch>...]
#   e.g. bisect_rc3_boot.sh ./KernelSU MODULE_LOAD_FILTER
#        bisect_rc3_boot.sh ./KernelSU APP_PROFILE_INIT,MODULE_LOAD_FILTER
#        bisect_rc3_boot.sh ./KernelSU ALL
#
# Each switch is applied idempotently and reports what it changed.
# =============================================================================
set -euo pipefail

KSU_DIR=${1:?usage: bisect_rc3_boot.sh <KernelSU-dir> <switch>[,<switch>...]}
SWITCHES=${2:-ALL}

[ -d "${KSU_DIR}/kernel" ] || { echo "no kernel dir under ${KSU_DIR}" >&2; exit 1; }

INIT_C="${KSU_DIR}/kernel/core/init.c"
KBUILD="${KSU_DIR}/kernel/Kbuild"
[ -f "$INIT_C" ] || { echo "init.c not found: ${INIT_C}" >&2; exit 1; }

if [ "$SWITCHES" = "ALL" ]; then
	SWITCHES="APP_PROFILE_INIT,MODULE_LOAD_FILTER,SESSION_KEYRING,PUT_CRED_GUARD"
fi

want() { case ",${SWITCHES}," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

changed=""

# --- comment out a single call site, matched literally ------------------------
# Uses awk rather than sed so the replacement text needs no escaping.
disable_call() {
	local file=$1 call=$2 tag=$3
	if grep -q "KSU_BISECT_DISABLED_${tag}" "$file"; then
		echo "  [-] ${tag} already disabled"
		return 0
	fi
	if ! grep -qF "$call" "$file"; then
		echo "  [!] ${tag}: call site not found, skipping: $call"
		return 0
	fi
	awk -v call="$call" -v tag="$tag" '
		index($0, call) && $0 !~ ("KSU_BISECT_DISABLED_" tag) {
			# Preserve indentation and comment the statement out.
			match($0, /^[[:space:]]*/)
			ind = substr($0, 1, RLENGTH)
			print ind "/* KSU_BISECT_DISABLED_" tag " */ /* " $0 " */"
			next
		}
		{ print }
	' "$file" >"${file}.bisect.$$"
	mv -f "${file}.bisect.$$" "$file"
	echo "  [+] ${tag} disabled"
	changed="${changed} ${tag}"
}

# --- APP_PROFILE_INIT ---------------------------------------------------------
if want APP_PROFILE_INIT; then
	echo "APP_PROFILE_INIT: skip ksu_app_profile_init()"
	disable_call "$INIT_C" "ksu_app_profile_init();" "APP_PROFILE_INIT"
fi

# --- MODULE_LOAD_FILTER -------------------------------------------------------
if want MODULE_LOAD_FILTER; then
	echo "MODULE_LOAD_FILTER: skip its init + drop it from the build"
	disable_call "$INIT_C" "ksu_module_load_filter_hook_init();" "MODULE_LOAD_FILTER_INIT"
	disable_call "$INIT_C" "ksu_module_load_filter_hook_exit();"  "MODULE_LOAD_FILTER_EXIT"
	if grep -q 'KSU_BISECT_DISABLED_MODULE_LOAD_FILTER_OBJ' "$KBUILD"; then
		echo "  [-] object already removed"
	elif grep -qF 'kernelsu-objs += feature/module_load_filter.o' "$KBUILD"; then
		awk '
			$0 == "kernelsu-objs += feature/module_load_filter.o" {
				print "# KSU_BISECT_DISABLED_MODULE_LOAD_FILTER_OBJ"
				print "# " $0
				next
			}
			{ print }
		' "$KBUILD" >"${KBUILD}.bisect.$$"
		mv -f "${KBUILD}.bisect.$$" "$KBUILD"
		echo "  [+] feature/module_load_filter.o removed from the build"
		changed="${changed} MODULE_LOAD_FILTER_OBJ"
	else
		echo "  [!] object line not found in Kbuild"
	fi
	# Its init is only meaningful if the object is gone, so the header include
	# must not break compilation. Leave the include; only calls were removed.
fi

# --- SESSION_KEYRING ----------------------------------------------------------
# Invert the unguarded call in setup_ksu_cred() back to auto-hook's behaviour:
# only do it when the compat macro says the kernel needs it.
if want SESSION_KEYRING; then
	echo "SESSION_KEYRING: guard ksu_get_session_keyring() call"
	if grep -q 'KSU_BISECT_DISABLED_SESSION_KEYRING' "$INIT_C"; then
		echo "  [-] already guarded"
	elif grep -q 'init_session_keyring = ksu_get_session_keyring(current_cred());' "$INIT_C"; then
		awk '
			/init_session_keyring = ksu_get_session_keyring\(current_cred\(\)\);/ {
				print "#ifdef KSU_COMPAT_REQUIRE_SESSION_KEYRING /* KSU_BISECT_DISABLED_SESSION_KEYRING */"
				print "\tinit_session_keyring = ksu_get_session_keyring(current_cred());"
				print "#endif"
				next
			}
			/^[[:space:]]*if \(init_session_keyring == NULL\) \{[[:space:]]*$/ {
				print "#ifdef KSU_COMPAT_REQUIRE_SESSION_KEYRING"
				print $0
				next
			}
			/^[[:space:]]*\}[[:space:]]*$/ { print; next }
			{ print }
		' "$INIT_C" >"${INIT_C}.bisect.$$"
		mv -f "${INIT_C}.bisect.$$" "$INIT_C"
		echo "  [+] done (verify the block still compiles)"
		changed="${changed} SESSION_KEYRING"
	else
		echo "  [!] call not found"
	fi
fi

# --- PUT_CRED_GUARD -----------------------------------------------------------
if want PUT_CRED_GUARD; then
	echo "PUT_CRED_GUARD: restore the NULL check around put_cred(ksu_cred)"
	if grep -q 'KSU_BISECT_DISABLED_PUT_CRED' "$INIT_C"; then
		echo "  [-] already guarded"
	elif grep -qE '^[[:space:]]*put_cred\(ksu_cred\);' "$INIT_C"; then
		awk '
			/^[[:space:]]*put_cred\(ksu_cred\);[[:space:]]*$/ {
				print "\tif (ksu_cred) { /* KSU_BISECT_DISABLED_PUT_CRED */"
				print "\t\tput_cred(ksu_cred);"
				print "\t}"
				next
			}
			{ print }
		' "$INIT_C" >"${INIT_C}.bisect.$$"
		mv -f "${INIT_C}.bisect.$$" "$INIT_C"
		echo "  [+] done"
		changed="${changed} PUT_CRED_GUARD"
	else
		echo "  [!] call not found"
	fi
fi

if [ -z "$changed" ]; then
	echo "no changes made (switches: ${SWITCHES})"
else
	echo "applied:${changed}"
fi
