#!/usr/bin/env bash
# Package build output: AnyKernel3 flashable zip and, optionally, a boot image.

set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KERNEL_DIR=${KERNEL_DIR:?KERNEL_DIR must be set}
WORKSPACE=${WORKSPACE:-$(cd "${KERNEL_DIR}/.." && pwd)}
ARCH=${ARCH:-arm64}
BOOT_OUT="${KERNEL_DIR}/out/arch/${ARCH}/boot"
AK3="${WORKSPACE}/AnyKernel3"

# Replace AnyKernel3's bundled sample install body with a minimal plain
# boot install.
#
# AnyKernel3 ships a Galaxy Nexus (tuna) example whose body calls
# backup_file/replace_string/insert_line/append_file/patch_fstab on init.rc,
# init.tuna.rc and fstab.tuna. None of those files exist on a modern device:
# the calls are no-ops at best, and on some devices they rewrite a file that
# happens to share a name. What we want is the plain install every real
# device uses -- unpack the active boot slot, swap the kernel, repack -- so
# the stock ramdisk comes out byte-identical and the only variable under test
# is the kernel itself.
write_anykernel_body() {
	local ak3=$1

	# Keep the header (properties/boot_attributes) and the shell variables
	# that select the partition; replace everything from dump_boot onward.
	local head
	head=$(mktemp)
	awk '/^dump_boot/ { exit } { print }' "${ak3}/anykernel.sh" >"$head"

	{
		cat "$head"
		cat <<'AK3BODY'
# boot install: unpack the active slot, replace the kernel, repack.
# split_boot (not dump_boot) is used deliberately: the vendor ramdisk is
# left exactly as it is, so the flash is kernel-only and the ramdisk that
# boots is the one already on the device.
split_boot;

# On header v3+ devices the dtb lives in vendor_boot, not in the boot image;
# flash_boot skips the ramdisk repack entirely and only writes the new kernel
# plus the boot header.
flash_boot;
## end boot install
AK3BODY
	} >"${ak3}/anykernel.sh"
	rm -f "$head"

	grep -q '^split_boot;' "${ak3}/anykernel.sh" \
		|| die "failed to write the AnyKernel3 install body"
}

# Turn "modules/vendor/lib/modules/*.ko" into an ak3-helper systemless module.
#
# do.systemless=1 makes AnyKernel3 package the modules/ tree as a Magisk or
# KernelSU module that bind-mounts over /vendor, rather than writing into the
# (read-only, erofs, dm-verity'd) vendor partition. On this device there is no
# vendor_dlkm partition to flash either, so an overlay is the only mechanism
# that can replace a module at all.
attach_modules() {
	[ -n "${MODULE_STAGE:-}" ] && [ -d "${MODULE_STAGE}" ] || return 0
	group "Attaching module overlay"

	local src="${MODULE_STAGE}/vendor/lib/modules"
	[ -d "$src" ] || die "MODULE_STAGE is set but ${src} does not exist"

	rm -rf "${AK3}/modules"
	mkdir -p "${AK3}/modules/vendor/lib/modules"
	cp -a "${src}/." "${AK3}/modules/vendor/lib/modules/"

	local nmod
	nmod=$(find "${AK3}/modules" -name '*.ko' | wc -l)
	[ "$nmod" -gt 0 ] || die "no .ko files found under ${src}"

	# do.systemless=1 is already the AnyKernel3 default; do.modules must be
	# turned on for the modules/ tree to be packaged at all.
	sed -i 's/^do\.modules=0$/do.modules=1/' "${AK3}/anykernel.sh"
	grep -q '^do\.modules=1' "${AK3}/anykernel.sh" \
		|| die "could not enable do.modules in anykernel.sh"

	ok "${nmod} modules attached as a systemless overlay"
	summary "| AnyKernel3 modules | \`${nmod}\` (\`do.modules=1\`, \`do.systemless=1\`) |"
	endgroup
}

make_anykernel3() {
	group "Building AnyKernel3 package"
	rm -rf "$AK3"

	if is_true "${USE_CUSTOM_ANYKERNEL3:-false}"; then
		local src=${CUSTOM_ANYKERNEL3_SOURCE:?CUSTOM_ANYKERNEL3_SOURCE required}
		case "$src" in
			*.tar.gz | *.tgz)
				fetch "$src" "${WORKSPACE}/ak3.tar.gz"
				extract_archive "${WORKSPACE}/ak3.tar.gz" "$AK3" ;;
			*.zip)
				fetch "$src" "${WORKSPACE}/ak3.zip"
				extract_archive "${WORKSPACE}/ak3.zip" "$AK3" ;;
			*git*)
				retry 3 git clone -q --depth=1 ${CUSTOM_ANYKERNEL3_BRANCH:+-b "$CUSTOM_ANYKERNEL3_BRANCH"} \
					"$src" "$AK3" || die "failed to clone ${src}" ;;
			*)
				fetch "$src" "${WORKSPACE}/ak3.zip"
				extract_archive "${WORKSPACE}/ak3.zip" "$AK3" ;;
		esac
	else
		retry 3 git clone -q --depth=1 https://github.com/osm0sis/AnyKernel3 "$AK3" \
			|| die "failed to clone AnyKernel3"
		# Device checks are meaningless here: we do not know the target's
		# ro.product.device, and the zip is flashed deliberately by its builder.
		sed -i 's/do.devicecheck=1/do.devicecheck=0/g' "${AK3}/anykernel.sh"
		sed -i 's!BLOCK=/dev/block/platform/omap/omap_hsmmc.0/by-name/boot;!BLOCK=auto;!g' "${AK3}/anykernel.sh"
		sed -i 's/IS_SLOT_DEVICE=0;/is_slot_device=auto;/g' "${AK3}/anykernel.sh"
	fi

	# The sample install body always needs replacing; both the stock AnyKernel3
	# clone and most custom templates ship the tuna example.
	write_anykernel_body "$AK3"
	attach_modules

	cp "${BOOT_OUT}/${KERNEL_IMAGE_NAME}" "${AK3}/" \
		|| die "kernel image missing at ${BOOT_OUT}/${KERNEL_IMAGE_NAME}"
	if is_true "${CHECK_DTBO_IS_OK:-false}"; then
		cp "${BOOT_OUT}/dtbo.img" "${AK3}/"
	fi
	rm -rf "${AK3}/.git" "${AK3}/.github" "${AK3}/README.md"

	ok "AnyKernel3 package assembled"
	endgroup
}

make_boot_image() {
	is_true "${BUILD_BOOT_IMG:-false}" || return 0
	group "Repacking boot image"

	local tools="${WORKSPACE}/tools"
	[ -x "${tools}/unpack_bootimg.py" ] || [ -f "${tools}/unpack_bootimg.py" ] \
		|| die "mkbootimg tools not found at ${tools}"

	fetch "${SOURCE_BOOT_IMAGE:?SOURCE_BOOT_IMAGE required}" "${WORKSPACE}/boot-source.img"

	cd "$WORKSPACE"
	local fmt
	fmt=$(python3 "${tools}/unpack_bootimg.py" --boot_img boot-source.img --format mkbootimg) \
		|| die "failed to read the source boot image"
	info "source boot image args: ${fmt}"

	python3 "${tools}/unpack_bootimg.py" --boot_img boot-source.img >/dev/null \
		|| die "failed to unpack the source boot image"

	cp "${BOOT_OUT}/${KERNEL_IMAGE_NAME}" "${WORKSPACE}/out/kernel" \
		|| die "could not stage the new kernel into the unpacked ramdisk"

	# shellcheck disable=SC2086
	python3 "${tools}/mkbootimg.py" $fmt -o boot.img || die "mkbootimg failed"
	[ -s "${WORKSPACE}/boot.img" ] || die "boot.img was not produced"

	ok "boot.img built ($(du -h "${WORKSPACE}/boot.img" | cut -f1))"
	export_env MAKE_BOOT_IMAGE_IS_OK true
	endgroup
}

write_summary() {
	summary ""
	summary "### Build artifacts"
	summary ""
	summary "| Artifact | Size |"
	summary "| --- | --- |"
	local f
	for f in "${BOOT_OUT}/${KERNEL_IMAGE_NAME}" "${BOOT_OUT}/dtbo.img" "${WORKSPACE}/boot.img"; do
		[ -f "$f" ] && summary "| \`$(basename "$f")\` | $(du -h "$f" | cut -f1) |"
	done
	[ -d "$AK3" ] && summary "| \`AnyKernel3\` (flashable zip) | $(du -sh "$AK3" | cut -f1) |"
	summary ""
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
	case "${1:-all}" in
		anykernel3) make_anykernel3 ;;
		bootimg)    make_boot_image ;;
		all)        make_anykernel3; make_boot_image; write_summary ;;
		*) die "unknown package step '$1'" ;;
	esac
fi
