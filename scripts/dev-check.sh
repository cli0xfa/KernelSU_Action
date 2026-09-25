#!/usr/bin/env bash
# Local sanity harness: validate every profile the way .github/workflows/ci.yml
# does, then print the make flags a profile produces. Not used by CI.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

fail=0
for f in config.env config/*.env; do
	[ -f "$f" ] || continue
	printf '%-34s ' "$f"
	if CONFIG_ENV="$f" bash scripts/config.sh >/dev/null 2>&1; then
		echo OK
	else
		echo FAIL
		CONFIG_ENV="$f" bash scripts/config.sh 2>&1 | tail -5
		fail=1
	fi
done

echo
echo "--- make_args (LLVM + both compat spellings) ---"
KERNEL_DIR=/tmp/kernel GCC_64='CROSS_COMPILE=/tc/aarch64-linux-android-' \
	GCC_32='CROSS_COMPILE_ARM32=/tc/arm-linux-androideabi-' \
	USE_LLVM=true CUSTOM_CMDS='CLANG_TRIPLE=aarch64-linux-gnu-' \
	bash -c '. scripts/lib.sh; . scripts/build.sh >/dev/null 2>&1; make_args; echo'

exit "$fail"
