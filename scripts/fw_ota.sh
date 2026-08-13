#!/bin/bash

die() {
	echo -e "\e[38;5;160m$1\e[0m" >&2
	exit 1
}

FORCE=0
NAND_OTA=0
SKIP_SPACE_CHECK=0
while getopts "fNn" opt; do
	case "$opt" in
		f) FORCE=1 ;;
		N) NAND_OTA=1 ;;
		n) SKIP_SPACE_CHECK=1 ;;
		*) die "Usage: $0 [-f] [-N] [-n] FIRMWARE_FILE IP_ADDRESS" ;;
	esac
done
shift $((OPTIND - 1))

[ "$#" -ne 2 ] && die "Usage: $0 [-f] [-N] [-n] FIRMWARE_FILE IP_ADDRESS"

cleanup() {
	[ -n "$LOCAL_NAND_ENV_FILE" ] && rm -f "$LOCAL_NAND_ENV_FILE"
	ssh -O exit $SSH_OPTS $REMOTE_HOST 2>/dev/null
	printf '\033[0m' 2>/dev/null || true
}

remote_copy() {
	echo -e "\e[38;5;122mscp -O $SSH_OPTS $1 $2\e[0m" >&2
	scp -O $SSH_OPTS "$1" "$2"
}

remote_run() {
	echo -e "\e[38;5;118mssh $SSH_OPTS $1\e[0m" >&2
	ssh $SSH_OPTS $REMOTE_HOST "$1"
}

remote_uptime_seconds() {
	remote_run "awk '{print int(\$1)}' /proc/uptime" 2>/dev/null | tr -d '[:space:]'
}

select_remote_fw_path() {
	if remote_run "mountpoint -q /mnt/mmcblk0p1 && [ -w /mnt/mmcblk0p1 ]" >/dev/null 2>&1; then
		REMOTE_FW_FILE="/mnt/mmcblk0p1/fw.bin"
		echo "Using SD card staging area at /mnt/mmcblk0p1."
	else
		REMOTE_FW_FILE="/tmp/fw.bin"
	fi

	REMOTE_FW_DIR="${REMOTE_FW_FILE%/*}"
}

remote_mem_available_kb() {
	remote_run "awk '\$1==\"MemAvailable:\" { print int(\$2); found=1 } \$1==\"MemFree:\" && !memfree { memfree=int(\$2) } END { if (!found) print memfree }' /proc/meminfo" 2>/dev/null | tr -d '[:space:]'
}

is_integer() {
	case "$1" in
		'' | *[!0-9]*)
			return 1
			;;
		*)
			return 0
			;;
	esac
}

prepare_upload_memory() {
	echo "Freeing memory before upload..."
	remote_run "rm -f /tmp/snapshot.jpg; sync; if [ -x /etc/init.d/S31raptor ]; then /etc/init.d/S31raptor stop; elif [ -x /etc/init.d/S31prudynt ]; then /etc/init.d/S31prudynt stop; elif pidof prudynt >/dev/null 2>&1; then killall prudynt 2>/dev/null || true; fi; sleep 1; [ -w /proc/sys/vm/drop_caches ] && echo 3 > /proc/sys/vm/drop_caches || true" >/dev/null ||
		echo "Warning: failed to free memory before upload."
}

wait_for_reboot_after_detach() {
	local previous_uptime current_uptime retries saw_disconnect

	previous_uptime="$1"
	retries=120
	saw_disconnect=0

	echo "Waiting for the device to reboot..."
	while [ "$retries" -gt 0 ]; do
		if current_uptime=$(remote_uptime_seconds); then
			if [ -n "$current_uptime" ] && [ "$current_uptime" -lt "$previous_uptime" ]; then
				echo "Device rebooted successfully."
				return 0
			fi

			if [ "$saw_disconnect" -eq 1 ]; then
				echo "Device is back online after reboot."
				return 0
			fi
		else
			saw_disconnect=1
		fi

		retries=$((retries - 1))
		sleep 2
	done

	return 1
}

nand_read_remote_value() {
	remote_run "fw_printenv -n $1" 2>/dev/null | tr -d '\r\n'
}

nand_reboot_and_wait() {
	local previous_uptime

	previous_uptime=$(remote_uptime_seconds)
	[ -n "$previous_uptime" ] || die "Failed to read device uptime before NAND OTA reboot."

	remote_run "sync; reboot" >/dev/null 2>&1 || true
	ssh -O exit $SSH_OPTS $REMOTE_HOST 2>/dev/null || true

	wait_for_reboot_after_detach "$previous_uptime" ||
		die "The camera did not return after the NAND OTA reboot."
}

nand_apply_sd_environment() {
	local autoupdate_value="$1"
	local bootcmd_value="$2"

	LOCAL_NAND_ENV_FILE=$(mktemp) || die "Failed to create the NAND OTA environment file."
	printf '%s\n' \
		"enable_updates=true" \
		"autoupdate=$autoupdate_value" \
		"bootcmd=$bootcmd_value" >"$LOCAL_NAND_ENV_FILE"

	remote_copy "$LOCAL_NAND_ENV_FILE" "$REMOTE_HOST:/tmp/nand-ota.env" ||
		die "Failed to transfer the NAND OTA environment update."
	remote_run "fw_setenv --script /tmp/nand-ota.env" ||
		die "Failed to persist the NAND OTA environment update."

	rm -f "$LOCAL_NAND_ENV_FILE"
	LOCAL_NAND_ENV_FILE=""

	[ "$(nand_read_remote_value enable_updates)" = "true" ] ||
		die "NAND OTA enable flag did not persist in the U-Boot environment."
	[ "$(nand_read_remote_value autoupdate)" = "$autoupdate_value" ] ||
		die "NAND OTA command did not persist in the U-Boot environment."
	[ "$(nand_read_remote_value bootcmd)" = "$bootcmd_value" ] ||
		die "NAND OTA boot command did not persist in the U-Boot environment."
}

nand_ota_upgrade() {
	local autoupdate_value backup_file boot_bad_blocks boot_mtd boot_size bootcmd
	local fw_size fw_size_kb
	local loadaddr loadaddr_num loadaddr_phys memory_end osmem osmem_addr osmem_mb
	local post_build_id pre_build_id remote_hash sd_avail_kb sd_needed_kb
	local total_flash_size ubi_bad_blocks ubi_magic ubi_mtd

	echo "Preparing an SD-staged, U-Boot-mediated SPI-NAND upgrade."

	[ "$(xxd -l 4 -p "$LOCAL_FW_FILE")" = "06050403" ] ||
		die "NAND firmware does not start with the Ingenic bootloader magic."
	ubi_magic=$(xxd -s 1048576 -l 4 -p "$LOCAL_FW_FILE")
	[ "$ubi_magic" = "55424923" ] ||
		die "NAND firmware does not contain a UBI image at offset 0x100000."

	fw_size=$(stat -c%s "$LOCAL_FW_FILE")
	[ $((fw_size % 131072)) -eq 0 ] ||
		die "NAND firmware size is not aligned to the 128 KiB erase size."
	fw_size_kb=$(((fw_size + 1023) / 1024))

	boot_mtd=$(remote_run "awk -F: '/\"boot\"$/{print \$1}' /proc/mtd" | tr -d '[:space:]')
	ubi_mtd=$(remote_run "awk -F: '/\"ubi\"$/{print \$1}' /proc/mtd" | tr -d '[:space:]')
	[ -n "$boot_mtd" ] && [ -n "$ubi_mtd" ] ||
		die "Device does not expose the expected NAND boot + ubi partition layout."

	boot_size=$(remote_run "cat /sys/class/mtd/$boot_mtd/size" | tr -d '[:space:]')
	[ "$boot_size" = "1048576" ] ||
		die "Unexpected NAND boot partition size: $boot_size (expected 1048576)."
	[ "$(remote_run "cat /sys/class/mtd/$boot_mtd/erasesize" | tr -d '[:space:]')" = "131072" ] ||
		die "Unexpected NAND erase size on $boot_mtd."
	[ "$(remote_run "cat /sys/class/mtd/$boot_mtd/writesize" | tr -d '[:space:]')" = "2048" ] ||
		die "Unexpected NAND page size on $boot_mtd."

	boot_bad_blocks=$(remote_run "cat /sys/class/mtd/$boot_mtd/bad_blocks" | tr -d '[:space:]')
	ubi_bad_blocks=$(remote_run "cat /sys/class/mtd/$ubi_mtd/bad_blocks" | tr -d '[:space:]')
	[ "$boot_bad_blocks" = "0" ] && [ "$ubi_bad_blocks" = "0" ] ||
		die "Refusing full-chip NAND OTA with bad blocks (boot=$boot_bad_blocks, ubi=$ubi_bad_blocks)."

	total_flash_size=$(remote_run "awk '/\"boot\"$|\"ubi\"$/{sum += (\"0x\" \$2) + 0} END {print sum}' /proc/mtd" | tr -d '[:space:]')
	is_integer "$total_flash_size" || die "Failed to read total NAND size from the device."
	[ "$fw_size" -le "$total_flash_size" ] ||
		die "NAND firmware is larger than the device: $fw_size > $total_flash_size."

	remote_run "awk '\$1==\"/dev/mmcblk0p1\" && \$2==\"/mnt/mmcblk0p1\" {found=1} END {exit !found}' /proc/mounts && test -w /mnt/mmcblk0p1" ||
		die "NAND OTA requires a mounted, writable SD card at /mnt/mmcblk0p1. Insert a FAT-formatted card and retry."
	sd_avail_kb=$(remote_run "df -k /mnt/mmcblk0p1 | awk 'NR==2{print \$4}'" | tr -d '[:space:]')
	is_integer "$sd_avail_kb" || die "Failed to read free space on the SD card."
	sd_needed_kb=$((fw_size_kb + 4096))
	[ "$sd_avail_kb" -ge "$sd_needed_kb" ] ||
		die "Not enough SD card space for NAND OTA: ${sd_avail_kb}KB < ${sd_needed_kb}KB."

	loadaddr=$(nand_read_remote_value loadaddr)
	osmem=$(nand_read_remote_value osmem)
	case "$loadaddr:$osmem" in
		0x*:*M@0x*) ;;
		*) die "Cannot validate U-Boot load memory from loadaddr=$loadaddr osmem=$osmem." ;;
	esac
	loadaddr_num=$((loadaddr))
	# Ingenic MIPS U-Boot uses a cached KSEG0 virtual load address. Compare its
	# physical alias against the physical osmem range from the environment.
	loadaddr_phys=$((loadaddr_num & 0x1fffffff))
	osmem_mb=${osmem%%M@*}
	osmem_addr=${osmem##*@}
	memory_end=$(($osmem_addr + osmem_mb * 1024 * 1024))
	[ "$loadaddr_phys" -ge "$((osmem_addr))" ] && [ $((loadaddr_phys + fw_size)) -le "$memory_end" ] ||
		die "NAND firmware does not fit in U-Boot OS memory at $loadaddr."

	pre_build_id=$(remote_run "sed -n 's/^BUILD_ID=//p' /etc/os-release" | tr -d '\r\n')
	echo "Preflight passed: ${fw_size_kb}KB image, 128 MiB NAND, no bad blocks."

	backup_file="/mnt/mmcblk0p1/thingino-overlay-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
	echo "Backing up the current overlay to $backup_file."
	remote_run "tar -czf $backup_file -C /overlay . && test -s $backup_file" ||
		die "Failed to back up the current overlay to the SD card."

	REMOTE_NAND_FW_FILE="/mnt/mmcblk0p1/autoupdate-full.bin"
	REMOTE_NAND_FW_NEW="${REMOTE_NAND_FW_FILE}.new"
	echo "Staging the full NAND image on the SD card."
	remote_copy "$LOCAL_FW_FILE" "$REMOTE_HOST:$REMOTE_NAND_FW_NEW" ||
		die "Failed to stage NAND firmware on the SD card."
	remote_hash=$(remote_run "sha256sum $REMOTE_NAND_FW_NEW | cut -d' ' -f1" | tr -d '[:space:]')
	[ "$remote_hash" = "$(sha256sum "$LOCAL_FW_FILE" | cut -d' ' -f1)" ] ||
		die "Staged NAND firmware checksum does not match."
	remote_run "stamp=\$(date +%s); if [ -e $REMOTE_NAND_FW_FILE ]; then mv $REMOTE_NAND_FW_FILE ${REMOTE_NAND_FW_FILE}.previous.\$stamp; fi; if [ -e /mnt/mmcblk0p1/autoupdate-full.done ]; then mv /mnt/mmcblk0p1/autoupdate-full.done /mnt/mmcblk0p1/autoupdate-full.done.previous.\$stamp; fi; mv $REMOTE_NAND_FW_NEW $REMOTE_NAND_FW_FILE; sync" ||
		die "Failed to publish the staged NAND firmware."

	bootcmd=$(nand_read_remote_value bootcmd)
	[ -n "$bootcmd" ] || die "Cannot read the current U-Boot bootcmd."
	case "$bootcmd" in
		"run autoupdate;run loaduenv;"*) bootcmd=${bootcmd#run autoupdate;run loaduenv;} ;;
		"run autoupdate;"*) bootcmd=${bootcmd#run autoupdate;} ;;
	esac
	case "$bootcmd" in
		*"ubi part ubi;ubi read "*) ;;
		*) die "Refusing to replace an unrecognized NAND bootcmd: $bootcmd" ;;
	esac

	autoupdate_value='if test "${enable_updates}" = "true"; then echo "checking for update file"; if fatsize mmc 0:1 autoupdate-full.done; then echo "AU: already applied"; else if fatload mmc 0:1 ${loadaddr} autoupdate-full.bin; then echo "AU: flashing autoupdate-full.bin"; if mtd erase spi-nand0 && mtd write spi-nand0 ${loadaddr} 0x0 ${filesize}; then fatwrite mmc 0:1 ${loadaddr} autoupdate-full.done 1; echo "AU: done, rebooting"; reset; fi; fi; fi; fi'
	nand_apply_sd_environment "$autoupdate_value" "run autoupdate;$bootcmd"

	echo "WARNING: the next reboot replaces the full SPI-NAND image, including overlay settings."
	echo "The image is checksum-verified on the SD card; U-Boot loads it before any erase."
	echo "Starting the NAND flash reboot in 5 seconds; press Ctrl-C to cancel."
	sleep 5
	nand_reboot_and_wait

	post_build_id=$(remote_run "sed -n 's/^BUILD_ID=//p' /etc/os-release" | tr -d '\r\n')
	remote_run "grep -q '\"boot\"' /proc/mtd && grep -q '\"ubi\"' /proc/mtd" ||
		die "Camera returned, but the expected NAND partitions are missing."
	remote_run "test \"\$(cat /sys/class/ubi/ubi0_0/name)\" = uboot-env && test \"\$(cat /sys/class/ubi/ubi0_1/name)\" = kernel && test \"\$(cat /sys/class/ubi/ubi0_2/name)\" = rootfs && test \"\$(cat /sys/class/ubi/ubi0_3/name)\" = overlay" ||
		die "Camera returned, but the expected UBI volumes are missing."

	echo "NAND firmware upgrade completed successfully."
	echo "Previous build: $pre_build_id"
	echo "Current build:  $post_build_id"
}

check_and_free_space() {
	local fw_size_kb remote_avail_kb remote_memavail_kb dir_needed_kb mem_needed_kb
	fw_size_kb=$((($(stat -c%s "$LOCAL_FW_FILE") + 1023) / 1024))
	# Uploading into tmpfs also needs extra RAM for dropbear/scp buffers and page cache.
	mem_needed_kb=$((fw_size_kb + 8192))

	select_remote_fw_path
	prepare_upload_memory

	if [ "$REMOTE_FW_DIR" = "/tmp" ]; then
		# Need room for the firmware plus sysupgrade working files in /tmp.
		dir_needed_kb=$((fw_size_kb + 4096))
	else
		# SD card staging does not require tmpfs working-space headroom.
		dir_needed_kb=$fw_size_kb
	fi

	remote_avail_kb=$(remote_run "df -k $REMOTE_FW_DIR | awk 'NR==2{print \$4}'" | tr -d '[:space:]')
	is_integer "$remote_avail_kb" || die "Failed to read available space in ${REMOTE_FW_DIR} on the device."
	echo "Firmware size: ${fw_size_kb}KB, available ${REMOTE_FW_DIR}: ${remote_avail_kb}KB, needed in ${REMOTE_FW_DIR}: ${dir_needed_kb}KB"

	if [ "$REMOTE_FW_DIR" != "/tmp" ]; then
		[ "$remote_avail_kb" -ge "$dir_needed_kb" ] && return 0
		die "Not enough free space in ${REMOTE_FW_DIR} on the device."
	fi

	remote_memavail_kb=$(remote_mem_available_kb)
	is_integer "$remote_memavail_kb" || die "Failed to read available RAM on the device."
	echo "Available RAM: ${remote_memavail_kb}KB, needed for upload: ${mem_needed_kb}KB"

	[ "$remote_avail_kb" -ge "$dir_needed_kb" ] && [ "$remote_memavail_kb" -ge "$mem_needed_kb" ] && return 0

	echo "Not enough upload headroom on the device. Attempting to free memory by remapping rmem..."

	local osmem rmem_val osmem_mb osmem_addr rmem_mb rmem_addr new_osmem_mb
	osmem=$(remote_run "fw_printenv -n osmem" | tr -d '[:space:]')
	rmem_val=$(remote_run "fw_printenv -n rmem" | tr -d '[:space:]')

	osmem_mb=$(echo "$osmem" | sed 's/M@.*//')
	osmem_addr=$(echo "$osmem" | sed 's/.*@//')
	rmem_mb=$(echo "$rmem_val" | sed 's/M@.*//')
	rmem_addr=$(echo "$rmem_val" | sed 's/.*@//')

	if [ -z "$rmem_mb" ] || [ "$rmem_mb" -le 0 ]; then
		die "Not enough upload headroom and rmem is not set or already zero. Cannot proceed."
	fi

	new_osmem_mb=$((osmem_mb + rmem_mb))
	echo "Remapping memory: osmem ${osmem_mb}M -> ${new_osmem_mb}M, rmem ${rmem_mb}M -> 0M (at ${rmem_addr})"

	remote_run "fw_setenv osmem ${new_osmem_mb}M@${osmem_addr} && fw_setenv rmem 0M@${rmem_addr} && reboot" || true

	echo "Closing SSH mux..."
	ssh -O exit $SSH_OPTS $REMOTE_HOST 2>/dev/null || true

	echo "Waiting for device to reboot..."
	sleep 15

	local retries=30
	while [ "$retries" -gt 0 ]; do
		if ssh $SSH_OPTS -o ConnectTimeout=5 $REMOTE_HOST "echo ok" >/dev/null 2>&1; then
			break
		fi
		retries=$((retries - 1))
		sleep 3
	done
	[ "$retries" -eq 0 ] && die "Device did not come back online after memory remap reboot."

	echo "Device is back online with remapped memory. Re-initializing SSH mux..."
	ssh -fN $SSH_OPTS $REMOTE_HOST >/dev/null 2>/dev/null || die "Failed to re-initialize SSH connection after reboot"

	echo "Re-uploading sysupgrade utility (tmpfs was cleared on reboot)..."
	upload_sysupgrade
	select_remote_fw_path
	prepare_upload_memory

	remote_avail_kb=$(remote_run "df -k $REMOTE_FW_DIR | awk 'NR==2{print \$4}'" | tr -d '[:space:]')
	is_integer "$remote_avail_kb" || die "Failed to read available space in ${REMOTE_FW_DIR} after memory remap."
	echo "Post-remap available ${REMOTE_FW_DIR}: ${remote_avail_kb}KB"

	if [ "$REMOTE_FW_DIR" = "/tmp" ]; then
		remote_memavail_kb=$(remote_mem_available_kb)
		is_integer "$remote_memavail_kb" || die "Failed to read available RAM after memory remap."
		echo "Post-remap available RAM: ${remote_memavail_kb}KB"
		[ "$remote_avail_kb" -ge "$dir_needed_kb" ] && [ "$remote_memavail_kb" -ge "$mem_needed_kb" ] && return 0
		die "Not enough upload headroom after memory remap."
	fi

	[ "$remote_avail_kb" -ge "$dir_needed_kb" ] || die "Not enough free space in ${REMOTE_FW_DIR} after memory remap."
}

trap cleanup EXIT

CAMERA_IP_ADDRESS="$2"

LOCAL_FW_FILE="$1"
LOCAL_SCRIPT="$(dirname "$0")/../package/thingino-sysupgrade/files/sysupgrade"
LOCAL_SCRIPT2="$(dirname "$0")/../package/thingino-sysupgrade/files/sysupgrade-stage2"

REMOTE_FW_FILE="/tmp/fw.bin"
REMOTE_FW_DIR="/tmp"
REMOTE_HOST="root@$CAMERA_IP_ADDRESS"
REMOTE_SCRIPT="/tmp/sup"

SSH_OPTS="-o ConnectTimeout=30 -o ServerAliveInterval=2 \
-o ControlMaster=auto -o ControlPath=/tmp/ssh_mux_%h_%p_%r \
-o ControlPersist=600 -o StrictHostKeyChecking=no \
-o UserKnownHostsFile=/dev/null"

echo "Initializing SSH connection to $REMOTE_HOST..."
ssh -fN $SSH_OPTS $REMOTE_HOST >/dev/null 2>/dev/null ||
	die "Failed to initialize ssh connection"

echo "SSH connection initialized."

echo "Checking firmware compatibility..."
REMOTE_IMAGE_ID=$(remote_run "grep '^IMAGE_ID=' /etc/os-release | cut -d'=' -f2" | tr -d '\n')
REMOTE_IMAGE_ID="${REMOTE_IMAGE_ID%-3.10}"
REMOTE_IMAGE_ID="${REMOTE_IMAGE_ID%-4.4}"

# IMAGE_ID is derived from CAMERA variable which should be set by the Makefile
LOCAL_IMAGE_ID="${CAMERA:-unknown}"

if [ -z "$REMOTE_IMAGE_ID" ]; then
	die "Failed to read IMAGE_ID from device"
fi

if [ "$LOCAL_IMAGE_ID" != "$REMOTE_IMAGE_ID" ]; then
	if [ "$FORCE" -eq 1 ]; then
		echo "Warning: IMAGE_ID mismatch: local=$LOCAL_IMAGE_ID, device=$REMOTE_IMAGE_ID (forced)"
	else
		die "Firmware IMAGE_ID mismatch: local=$LOCAL_IMAGE_ID, device=$REMOTE_IMAGE_ID (use -f to override)"
	fi
fi

echo "Firmware compatibility verified."

if [ "$NAND_OTA" -eq 1 ]; then
	nand_ota_upgrade
	exit 0
fi

upload_sysupgrade() {
	remote_copy $LOCAL_SCRIPT $REMOTE_HOST:$REMOTE_SCRIPT ||
		die "Failed to transfer sysupgrade utility"
	remote_copy $LOCAL_SCRIPT2 $REMOTE_HOST:/sbin/$(basename $LOCAL_SCRIPT2) ||
		die "Failed to transfer sysupgrade-stage2 utility"
	remote_run "chmod +x $REMOTE_SCRIPT" ||
		die "Failed to set execute permissions on sysupgrade utility"
	echo "Sysupgrade utility installed successfully."
}

echo "Transferring sysupgrade utility to device..."
upload_sysupgrade

if [ "$SKIP_SPACE_CHECK" -eq 1 ]; then
	echo "Skipping space/memory checks (-n)."
	select_remote_fw_path
	prepare_upload_memory
else
	echo "Checking available space in /tmp on device..."
	check_and_free_space
fi

echo "Transferring firmware file to the device..."
remote_copy $LOCAL_FW_FILE $REMOTE_HOST:$REMOTE_FW_FILE ||
	die "The firmware transfer process timed out or failed."

hash_l=$(sha256sum "$LOCAL_FW_FILE" | cut -d' ' -f1)
hash_r=$(remote_run "sha256sum $REMOTE_FW_FILE | cut -d' ' -f1")
[ "$hash_l" != "$hash_r" ] &&
	die "SHA256 checksum does not match, exiting..."

echo "Firmware file transferred and SHA256 checksum verified."

pre_flash_uptime=$(remote_uptime_seconds)
[ -z "$pre_flash_uptime" ] && die "Failed to read device uptime before flashing"

ota_log=$(mktemp)
remote_run "$REMOTE_SCRIPT -x $REMOTE_FW_FILE" 2>&1 | tee /dev/tty | tee "$ota_log" >/dev/null
ota_status=${PIPESTATUS[0]}

if grep -q "Rebooting" "$ota_log"; then
	rm -f "$ota_log"
	echo "Firmware flashed successfully. Device is rebooting."
	exit 0
fi

if grep -q "Flash process running with PID" "$ota_log"; then
	if wait_for_reboot_after_detach "$pre_flash_uptime"; then
		rm -f "$ota_log"
		echo "Firmware flashed successfully. Device is rebooting."
		exit 0
	fi

	if remote_log_tail=$(remote_run "tail -n 50 /tmp/sysupgrade-flash.log" 2>/dev/null); then
		echo "$remote_log_tail" >&2
	fi
	rm -f "$ota_log"
	die "Detached flash did not complete successfully"
fi

rm -f "$ota_log"
[ "$ota_status" -ne 0 ] && die "Failed to flash firmware"

die "Failed to flash firmware"

exit 0
