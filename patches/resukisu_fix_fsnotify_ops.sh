#!/usr/bin/env bash
# =============================================================================
# Fix ReSukiSU's fsnotify usage on kernels older than 5.9.
#
# PROBLEM
# -------
# kernel/manager/pkg_observer.c installs:
#
#     static const struct fsnotify_ops ksu_ops = {
#         .handle_inode_event = ksu_handle_inode_event,
#     };
#
# `handle_inode_event` was added to `struct fsnotify_ops` in Linux 5.9. On 5.4
# the struct has only `handle_event`, so the designated initialiser names a
# field that does not exist and the build dies:
#
#     pkg_observer.c:39:6: error: field designator 'handle_inode_event' does not
#     refer to any field in type 'const struct fsnotify_ops';
#     did you mean 'handle_event'?
#
# with a follow-on -Wincompatible-function-pointer-types error, because the two
# callbacks take different arguments:
#
#   5.4  handle_event       (group, inode, mask, data, data_type, file_name,
#                            cookie, iter_info)
#   5.9+ handle_inode_event (mark, mask, inode, dir, file_name, cookie)
#
# FIX
# ---
# Add a `handle_event` wrapper for < 5.9 that adapts the argument list and
# forwards to the existing handler, and select whichever field the kernel
# actually has. Nothing about what the observer does changes: it only looks at
# the file name (and ignores directories), both of which the older callback
# provides.
#
# Note the mask semantics differ slightly: on 5.4 `handle_event` receives the
# event mask for the inode, and the same FS_ISDIR test applies. The file name
# arrives as `file_name` in both cases.
#
# Only ReSukiSU's own source is edited. No kernel source file is touched.
# =============================================================================
set -euo pipefail

KSU_DIR=${1:?usage: resukisu_fix_fsnotify_ops.sh <KernelSU-dir>}
SRC="${KSU_DIR}/kernel/manager/pkg_observer.c"

[ -f "$SRC" ] || { echo "pkg_observer.c not found: ${SRC}" >&2; exit 1; }

if grep -q 'KSU_FSNOTIFY_OPS_FIELD' "$SRC"; then
	echo "[-] fsnotify compat already present"
	exit 0
fi

if ! grep -q 'handle_inode_event' "$SRC"; then
	echo "[-] no handle_inode_event in ${SRC}; nothing to do" >&2
	echo "    Either this revision already guards it or the file changed shape." >&2
	echo "    Inspect it before proceeding." >&2
	exit 1
fi

tmp="${SRC}.fspatch.$$"

awk '
	# Insert the pre-5.9 wrapper just before the ops struct, and swap the field
	# name for the version-appropriate one.
	/^[[:space:]]*static const struct fsnotify_ops ksu_ops[[:space:]]*=[[:space:]]*\{[[:space:]]*$/ {
		print ""
		print "/*"
		print " * handle_inode_event only exists from Linux 5.9. Before that the single"
		print " * callback is handle_event, with a wider argument list; adapt to it so"
		print " * this observer compiles on 5.4. Behaviour is unchanged: neither"
		print " * version looks at anything except the file name and the FS_ISDIR flag."
		print " */"
		print "#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)"
		print "#define KSU_FSNOTIFY_HANDLE_INODE_EVENT ksu_handle_inode_event"
		print "#define KSU_FSNOTIFY_OPS_FIELD handle_inode_event"
		print "#else"
		print "static int ksu_handle_event_compat(struct fsnotify_group *group, struct inode *inode,"
		print "                                   u32 mask, const void *data, int data_type,"
		print "                                   const struct qstr *file_name, u32 cookie,"
		print "                                   struct fsnotify_iter_info *iter_info)"
		print "{"
		print "	(void)group;"
		print "	(void)inode;"
		print "	(void)data;"
		print "	(void)data_type;"
		print "	(void)iter_info;"
		print "	return ksu_handle_inode_event(NULL, mask, inode, NULL, file_name, cookie);"
		print "}"
		print "#define KSU_FSNOTIFY_HANDLE_INODE_EVENT ksu_handle_event_compat"
		print "#define KSU_FSNOTIFY_OPS_FIELD handle_event"
		print "#endif"
		print ""
		print "static const struct fsnotify_ops ksu_ops = {"
		print "	.KSU_FSNOTIFY_OPS_FIELD = KSU_FSNOTIFY_HANDLE_INODE_EVENT,"
		skip_field = 1
		next
	}
	skip_field && /^[[:space:]]*\.handle_inode_event[[:space:]]*=/ { skip_field = 0; next }
	{ print }
	END { if (skip_field) exit 1 }
' "$SRC" >"$tmp" || {
	rm -f "$tmp"
	echo "[-] could not locate the ksu_ops initialiser in ${SRC}" >&2
	echo "    Refusing to guess; inspect that file." >&2
	exit 1
}

mv -f "$tmp" "$SRC"

# Prove the rewrite actually took effect.
grep -q 'KSU_FSNOTIFY_OPS_FIELD' "$SRC" || {
	echo "[-] patch did not apply as expected" >&2
	exit 1
}
if grep -qE '^[[:space:]]*\.handle_inode_event[[:space:]]*=' "$SRC"; then
	echo "[-] a bare .handle_inode_event initialiser survived" >&2
	exit 1
fi

echo "[+] patched: fsnotify ops now select handle_event below 5.9"
