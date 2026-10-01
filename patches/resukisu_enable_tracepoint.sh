#!/usr/bin/env bash
# =============================================================================
# Enable ReSukiSU's tracepoint syscall hook on a 5.4 kernel.
#
# WHY
# ---
# ReSukiSU gates `CONFIG_KSU_TRACEPOINT_HOOK` to GKI 2.0 with a hard $(error):
#
#     ifneq ($(KERNEL_TYPE), GKI 2.0)
#       $(error TP hooks are incompatible with Non-GKI/GKI 1.0 kernels.)
#     endif
#
# On this device that gate is wrong, and the reason matters:
#
#   * The hook needs the `sys_enter` tracepoint, which is declared in
#     include/trace/events/syscalls.h under `#ifdef CONFIG_HAVE_SYSCALL_TRACEPOINTS`.
#     This kernel sets CONFIG_HAVE_SYSCALL_TRACEPOINTS=y, so the tracepoint
#     exists and register_trace_prio_sys_enter() works.
#   * CONFIG_FTRACE_SYSCALLS is *not* set here, but that only controls whether
#     the events show up in tracefs for userspace; it does not gate KernelSU
#     registering its own probe.
#   * The tracepoint code path itself carries no post-5.4 API use. Its only
#     version checks have 5.4-correct fallbacks already:
#         tp_marker.c        >= 5.11 -> test_task_syscall_work(), else
#                                     test_tsk_thread_flag(TIF_SYSCALL_TRACEPOINT)
#         syscall_hook_manager.c < 6.7 -> include <linux/compat.h> and
#                                     <linux/sched/task_stack.h>
#
# WHY IT IS NEEDED AT ALL
# -----------------------
# The default path for pre-GKI kernels is KSU_MANUAL_HOOK, which installs hooks
# with hook/inline_hook.c. On this kernel every install is refused:
#
#     inline_hook: reject non-text target=... dispatcher=...
#     ksu_hook_sys_execve: failed to hook do_execve: -22
#
# inline_hook.c gates on kernel_text_address() for both the target and the
# dispatcher, and this kernel builds with CONFIG_CFI_CLANG=y +
# CONFIG_LTO_CLANG=y, which places those functions outside the ranges that
# predicate accepts. All 7 inline hooks fail, including the execve one that
# rewrites /system/bin/su to /data/adb/ksud -- so `su` has no way to escalate.
#
# The tracepoint path does not patch function text at all. It redirects at
# syscall entry by rewriting regs->syscallno to a spare ni_syscall slot where a
# shared dispatcher was installed with ksu_syscall_table_hook() -- the same
# mechanism that already reports `patch result=0` on this device.
#
# WHAT THIS DOES
# --------------
#   1. Neutralises the GKI-2.0-only $(error) so the Kbuild accepts the mode.
#      The check is replaced by an informational line, and a guard is added so
#      the patch refuses to run if the block is not shaped as expected.
#   2. Nothing else. The mode itself is selected by the config profile via
#      CONFIG_KSU_TRACEPOINT_HOOK=y.
#
# This patches ReSukiSU's own source only. No kernel source file is touched.
# =============================================================================
set -euo pipefail

KSU_DIR=${1:?usage: resukisu_enable_tracepoint.sh <KernelSU-dir>}
KBUILD="${KSU_DIR}/kernel/Kbuild"

[ -f "$KBUILD" ] || { echo "Kbuild not found: ${KBUILD}" >&2; exit 1; }

if grep -q 'KSU_TRACEPOINT_ON_PRE_GKI_OK' "$KBUILD"; then
	echo "[-] tracepoint gate already neutralised"
	exit 0
fi

# Anchor on the exact block. If it does not match, this is a different ReSukiSU
# revision and silently skipping would ship a kernel that fails to build (the
# $(error) fires) or, worse, one whose hooks never install.
if ! grep -q 'TP hooks are incompatible with Non-GKI/GKI 1.0 kernels' "$KBUILD"; then
	echo "[-] the GKI 2.0 tracepoint gate is not present in this revision;" >&2
	echo "    either it is already fixed upstream or the Kbuild changed shape." >&2
	echo "    Inspect ${KBUILD} before proceeding." >&2
	exit 1
fi

# Rewrite the block with awk rather than sed: the replacement is multi-line and
# contains characters sed would need escaping ($, /, parentheses). awk can match
# the opening line, skip to the matching `endif`, and splice in the new text
# without any of that.
#
# Done with awk and a temp file (not `awk -i inplace`) so this works with the
# busybox/mawk variants on runners as well as GNU awk.
tmp="${KBUILD}.kpatch.$$"

awk -v marker='KSU_TRACEPOINT_ON_PRE_GKI_OK' '
	# Start of the block we are replacing.
	/^[[:space:]]*ifneq \(\$\(KERNEL_TYPE\), GKI 2\.0\)[[:space:]]*$/ {
		pending = 1; buf = $0 "\n"; next
	}
	pending {
		buf = buf $0 "\n"
		if ($0 ~ /TP hooks are incompatible with Non-GKI\/GKI 1\.0 kernels/) { saw_error = 1 }
		if ($0 ~ /^[[:space:]]*endif[[:space:]]*$/) {
			if (saw_error) {
				print "      # " marker
				print "      # Upstream gates the tracepoint hook to GKI 2.0. That is a statement"
				print "      # about which kernels were *tested*, not about what the code requires:"
				print "      # the hook needs the sys_enter tracepoint"
				print "      # (CONFIG_HAVE_SYSCALL_TRACEPOINTS, set here), not GKI 2.0. Kept as an"
				print "      # informational note so a build log still shows which path was taken."
				print "      ifneq ($(KERNEL_TYPE), GKI 2.0)"
				print "        $(info -- $(REPO_NAME) TP Hooks on $(KERNEL_TYPE): enabled by patch)"
				print "      endif"
				replaced++
			} else {
				printf "%s", buf
			}
			pending = 0; saw_error = 0; buf = ""
			next
		}
		next
	}
	{ print }
	END { if (pending) { printf "%s", buf } ; if (replaced != 1) exit 1 }
' "$KBUILD" >"$tmp" || {
	rm -f "$tmp"
	echo "[-] could not find the GKI 2.0 tracepoint gate block in ${KBUILD}" >&2
	echo "    Either it is already fixed upstream or the Kbuild changed shape." >&2
	echo "    Refusing to guess; inspect that file before proceeding." >&2
	exit 1
}

mv -f "$tmp" "$KBUILD"
echo "[+] patched: GKI 2.0 tracepoint gate neutralised"
