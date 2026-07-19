#!/usr/bin/env bash

set -euo pipefail

usage() {
	cat <<'EOF'
Usage: rebottle <block-device> <output-image.gz>

Converts a Raspberry Pi OS (Trixie) SD card back into a compressed image.

Arguments:
  <block-device>       Path to the SD card block device (e.g. /dev/sdb, /dev/mmcblk0)
  <output-image.gz>    Output path for gzip-compressed image (refuses to overwrite)
EOF
}

fatal() {
	echo "rebottle: error: $*" >&2
	exit 1
}

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || fatal "missing required command: $1"
}

is_mounted_anywhere() {
	local src="$1"
	# findmnt returns 0 if any mount matches.
	findmnt -rn -S "$src" >/dev/null 2>&1
}

partnum_from_path() {
	# Infer partition number from a partition path.
	# Supports /dev/sdX1, /dev/mmcblk0p1, /dev/nvme0n1p1, /dev/loop0p1.
	local dev="$1"
	local part="$2"
	local n=""
	case "$part" in
		"${dev}"p[0-9]*)
			n="${part#${dev}p}"
			;;
		"${dev}"[0-9]*)
			n="${part#${dev}}"
			;;
		*)
			return 1
			;;
	esac

	[[ "$n" =~ ^[0-9]+$ ]] || return 1
	echo "$n"
	return 0
}

TMP_MOUNT=""
cleanup() {
	set +e
	if [[ -n "${TMP_MOUNT}" ]] && mountpoint -q "${TMP_MOUNT}"; then
		umount "${TMP_MOUNT}" >/dev/null 2>&1 || true
	fi
	if [[ -n "${TMP_MOUNT}" ]] && [[ -d "${TMP_MOUNT}" ]]; then
		rmdir "${TMP_MOUNT}" >/dev/null 2>&1 || true
	fi
}
trap cleanup EXIT

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
	usage
	exit 0
fi

[[ $# -eq 2 ]] || { usage >&2; exit 2; }

DEV="$1"
OUT="$2"

[[ $EUID -eq 0 ]] || fatal "must run as root (try: sudo $0 <block-device> <output-image.gz>)"

DEV="$(readlink -f "$DEV")"

[[ -b "$DEV" ]] || fatal "not a block device: $DEV"
[[ -e "$OUT" ]] && fatal "output file already exists: $OUT"

OUT_DIR="$(dirname -- "$OUT")"
[[ -d "$OUT_DIR" ]] || fatal "output directory does not exist: $OUT_DIR"
[[ -w "$OUT_DIR" ]] || fatal "output directory not writable: $OUT_DIR"

need_cmd lsblk
need_cmd blkid
need_cmd sfdisk
need_cmd partprobe
need_cmd e2fsck
need_cmd resize2fs
need_cmd dumpe2fs
need_cmd blockdev
need_cmd mount
need_cmd umount
need_cmd dd
need_cmd gzip
need_cmd findmnt
need_cmd mountpoint

# --- Validation ---

PTTYPE="$(lsblk -dn -o PTTYPE "$DEV" 2>/dev/null || true)"
[[ -n "$PTTYPE" ]] || fatal "cannot determine partition table type for $DEV"
if [[ "$PTTYPE" == "gpt" ]]; then
	fatal "GPT partition tables are not supported (expected DOS/MBR/msdos)"
fi
if [[ "$PTTYPE" != "dos" && "$PTTYPE" != "msdos" ]]; then
	fatal "unsupported partition table type '$PTTYPE' (expected DOS/MBR/msdos)"
fi

# Enumerate partitions without relying on lsblk's PARTNUM column (not available everywhere).
mapfile -t PARTS_RAW < <(
	lsblk -nr -o PATH,TYPE "$DEV" |
		awk '$2=="part" {print $1}'
)

[[ ${#PARTS_RAW[@]} -eq 2 ]] || fatal "expected exactly 2 partitions on $DEV (found ${#PARTS_RAW[@]})"

declare -a PARTS
for p in "${PARTS_RAW[@]}"; do
	if ! n="$(partnum_from_path "$DEV" "$p")"; then
		fatal "cannot infer partition number for $p"
	fi
	PARTS+=("$p:$n")
done

IFS=$'\n' PARTS=($(printf '%s\n' "${PARTS[@]}" | sort -t: -k2,2n))
unset IFS

P1="${PARTS[0]%%:*}"
P1_NUM="${PARTS[0]##*:}"
P2="${PARTS[1]%%:*}"
P2_NUM="${PARTS[1]##*:}"

[[ "$P1_NUM" == "1" && "$P2_NUM" == "2" ]] || fatal "expected partitions numbered 1 and 2 (found $P1_NUM and $P2_NUM)"

# Refuse if anything is mounted.
if is_mounted_anywhere "$DEV" || is_mounted_anywhere "$P1" || is_mounted_anywhere "$P2"; then
	fatal "device or partitions are mounted; please unmount $DEV (and $P1/$P2) first"
fi
if [[ -n "$(lsblk -nr -o MOUNTPOINT "$P1" | tr -d '[:space:]')" ]] || [[ -n "$(lsblk -nr -o MOUNTPOINT "$P2" | tr -d '[:space:]')" ]]; then
	fatal "device or partitions appear mounted; please unmount first"
fi

P2_FSTYPE="$(blkid -o value -s TYPE "$P2" 2>/dev/null || true)"
[[ "$P2_FSTYPE" == "ext4" ]] || fatal "partition 2 must be ext4 (found '${P2_FSTYPE:-unknown}')"

# Verify cmdline.txt exists on partition 1.
TMP_MOUNT="$(mktemp -d -t rebottle.XXXXXX)"
mount -o ro "$P1" "$TMP_MOUNT"
if [[ ! -f "$TMP_MOUNT/cmdline.txt" ]]; then
	fatal "cmdline.txt not found on first partition"
fi
umount "$TMP_MOUNT"

# --- Shrink filesystem and partition ---

echo "[1/4] Shrinking ext4 filesystem on $P2..." >&2
e2fsck -f -y "$P2" >/dev/null

RESIZE_OUT="$(resize2fs -M "$P2" 2>&1)"
echo "$RESIZE_OUT" >&2

NEW_BLOCKS="$(printf '%s\n' "$RESIZE_OUT" | sed -n 's/.*is now \([0-9]\+\) (.* blocks long.*/\1/p' | tail -n1)"
if [[ -z "$NEW_BLOCKS" ]]; then
	NEW_BLOCKS="$(dumpe2fs -h "$P2" 2>/dev/null | awk -F': *' '/^Block count:/{print $2; exit}')"
fi

BLOCK_SIZE="$(dumpe2fs -h "$P2" 2>/dev/null | awk -F': *' '/^Block size:/{print $2; exit}')"
[[ -n "$NEW_BLOCKS" && -n "$BLOCK_SIZE" ]] || fatal "failed to determine ext4 block count/size after shrinking"

SECTOR_SIZE="$(blockdev --getss "$DEV")"
[[ -n "$SECTOR_SIZE" ]] || fatal "failed to determine device sector size"

SLACK_BYTES=$((8 * 1024 * 1024))
REQ_BYTES=$((NEW_BLOCKS * BLOCK_SIZE + SLACK_BYTES))
REQ_SECTORS=$(((REQ_BYTES + SECTOR_SIZE - 1) / SECTOR_SIZE))

# Align to 1MiB boundaries (2048 * 512B sectors). For non-512 sectors this is still reasonable as a sector multiple.
ALIGN_SECTORS=2048
ALIGNED_SECTORS=$(((REQ_SECTORS + ALIGN_SECTORS - 1) / ALIGN_SECTORS * ALIGN_SECTORS))

DUMP="$(sfdisk -d "$DEV")"
echo "$DUMP" | grep -qE '^label: dos' || fatal "expected DOS/MBR (sfdisk label: dos)"

P2_INFO="$(echo "$DUMP" | sed -n "s|^$P2 : start= *\\([0-9]\\+\\), size= *\\([0-9]\\+\\), type=\\([^, ]\\+\\).*|\\1 \\2 \\3|p")"
[[ -n "$P2_INFO" ]] || fatal "failed to parse partition 2 geometry from sfdisk"

P2_START="${P2_INFO%% *}"
REST="${P2_INFO#* }"
P2_SIZE_CUR="${REST%% *}"
P2_TYPE="${REST#* }"

NEW_P2_SIZE="$ALIGNED_SECTORS"
if (( NEW_P2_SIZE > P2_SIZE_CUR )); then
	# Don't grow; keep current size if our computation overshoots.
	NEW_P2_SIZE="$P2_SIZE_CUR"
fi

if (( NEW_P2_SIZE < P2_SIZE_CUR )); then
	echo "[2/4] Shrinking partition 2 from ${P2_SIZE_CUR} to ${NEW_P2_SIZE} sectors..." >&2
	printf 'start=%s, size=%s, type=%s\n' "$P2_START" "$NEW_P2_SIZE" "$P2_TYPE" | sfdisk --force -N2 "$DEV" >/dev/null
	partprobe "$DEV" >/dev/null 2>&1 || true
else
	echo "[2/4] Partition 2 already minimal enough; not resizing partition table." >&2
fi

# --- Re-enable resize in cmdline.txt ---

echo "[3/4] Ensuring 'resize' token in cmdline.txt..." >&2
mount -o rw "$P1" "$TMP_MOUNT"

CMDLINE="$(head -n 1 "$TMP_MOUNT/cmdline.txt" || true)"
if [[ -z "$CMDLINE" ]]; then
	umount "$TMP_MOUNT"
	fatal "cmdline.txt is empty or unreadable"
fi

if ! printf '%s\n' "$CMDLINE" | grep -Eq '(^|[[:space:]])resize([[:space:]]|$)'; then
	CMDLINE="$CMDLINE resize"
	printf '%s\n' "$CMDLINE" > "$TMP_MOUNT/cmdline.txt"
	# Best-effort flush.
	sync
fi

umount "$TMP_MOUNT"

# --- Create flat copy ---

echo "[4/4] Creating compressed image (dd | gzip)..." >&2

# Re-read partition geometry to compute copy length (bytes up to end of partition 2).
DUMP2="$(sfdisk -d "$DEV")"
P2_INFO2="$(echo "$DUMP2" | sed -n "s|^$P2 : start= *\\([0-9]\\+\\), size= *\\([0-9]\\+\\), type=\\([^, ]\\+\\).*|\\1 \\2 \\3|p")"
[[ -n "$P2_INFO2" ]] || fatal "failed to parse updated partition 2 geometry"

P2_START2="${P2_INFO2%% *}"
REST2="${P2_INFO2#* }"
P2_SIZE2="${REST2%% *}"

TOTAL_SECTORS=$((P2_START2 + P2_SIZE2))
COUNT_BYTES=$((TOTAL_SECTORS * SECTOR_SIZE))

sync

dd if="$DEV" bs=4M iflag=fullblock,count_bytes count="$COUNT_BYTES" status=progress | gzip -c > "$OUT"

chown "$SUDO_USER" "$OUT"

echo "rebottle: wrote $OUT" >&2
