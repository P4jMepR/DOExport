#!/usr/bin/env bash
set -euo pipefail

VERSION="2.2.0"

# ─────────────────────────────────────────────
#  do-export — disk imaging script
#  All config via environment variables.
#  No interactive prompts — safe to run from systemd.
#
#  Usage:
#    OUTPUT_DIR=/tmp/do-export FORMAT=raw COMPRESS=yes ./do-export.sh
#
#  Variables:
#    DEVICE        Block device to image (default: auto-detect)
#    OUTPUT_DIR    Where to save the image (default: /tmp/do-export)
#    FORMAT        raw | vmdk | qcow2 | vhd (default: raw)
#    COMPRESS      yes | no (default: yes)
#    VERIFY        yes | no — sha256 checksum (default: yes)
#    REMOTE_TARGET SSH target user@host (default: none)
#    REMOTE_PATH   Path on remote host (default: ~)
# ─────────────────────────────────────────────

# ── Config ────────────────────────────────────
DEVICE="${DEVICE:-}"
OUTPUT_DIR="${OUTPUT_DIR:-/tmp/do-export}"
FORMAT="${FORMAT:-raw}"
COMPRESS="${COMPRESS:-yes}"
VERIFY="${VERIFY:-yes}"
REMOTE_TARGET="${REMOTE_TARGET:-}"
REMOTE_PATH="${REMOTE_PATH:-~}"

IMAGE_NAME="snapshot.img"
COMPRESSED_NAME="snapshot.img.gz"
CHECKSUM_NAME="snapshot.img.sha256"

# ── Logging ───────────────────────────────────
log()  { echo "[+] $(date '+%H:%M:%S') $1"; }
warn() { echo "[!] $(date '+%H:%M:%S') $1"; }
fail() { echo "[x] $(date '+%H:%M:%S') $1" >&2; exit 1; }

# ── Internal state ────────────────────────────
_FS_FROZEN=0
_FREEZE_MOUNTS=()

# ── Preflight ─────────────────────────────────
require_root() {
  [[ "$EUID" -eq 0 ]] || fail "Must run as root"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

validate_format() {
  case "$FORMAT" in
    raw|vmdk|qcow2|vhd) ;;
    *) fail "Invalid FORMAT '$FORMAT'. Choose: raw, vmdk, qcow2, vhd" ;;
  esac
}

validate_remote() {
  [[ -z "$REMOTE_TARGET" ]] && return
  [[ "$REMOTE_TARGET" =~ ^[^@/]+@[^@/]+$ ]] || \
    fail "REMOTE_TARGET must be 'user@host'. Set REMOTE_PATH separately."
}

# ── Device detection ──────────────────────────
detect_device() {
  if [[ -n "$DEVICE" ]]; then
    [[ -b "$DEVICE" ]] || fail "Specified DEVICE '$DEVICE' is not a block device"
    log "Using device: $DEVICE"
    return
  fi
  log "Auto-detecting primary disk..."
  DEVICE=$(lsblk -ndo NAME,TYPE | awk '$2=="disk"{print "/dev/"$1; exit}')
  [[ -b "$DEVICE" ]] || fail "Could not auto-detect a disk device"
  log "Detected: $DEVICE"
}

# ── Detect partition to image ─────────────────
# e2image works on partitions, not whole disks.
# Find the first ext2/3/4 partition on the device,
# fall back to the device itself for dd.
detect_partition() {
  PARTITION=$(lsblk -nlo NAME,FSTYPE "$DEVICE" \
    | awk '$2 ~ /^ext[234]$/ {print "/dev/"$1; exit}')
  if [[ -n "$PARTITION" ]]; then
    log "Found ext partition: $PARTITION"
  else
    warn "No ext2/3/4 partition found on $DEVICE — will use dd"
    PARTITION="$DEVICE"
  fi
}

# ── Prepare output dir ────────────────────────
prepare() {
  mkdir -p "$OUTPUT_DIR"

  local dev_bytes free_bytes
  dev_bytes=$(blockdev --getsize64 "$DEVICE" 2>/dev/null || echo 0)
  free_bytes=$(df --output=avail -B1 "$OUTPUT_DIR" | tail -1)

  # Warn if output dir is on the same device being imaged
  local out_dev img_dev
  out_dev=$(df --output=source "$OUTPUT_DIR" | tail -1)
  img_dev=$(lsblk -ndo PKNAME "$DEVICE" 2>/dev/null || basename "$DEVICE")
  if [[ "$out_dev" == *"$img_dev"* ]]; then
    warn "Output directory is on the same disk being imaged!"
    warn "Using e2image (used-blocks only) — this is safe, but consider a remote target."
  fi

  if (( dev_bytes > 0 && free_bytes < dev_bytes / 4 )); then
    warn "Low disk space: device is $(( dev_bytes / 1073741824 ))G, \
output dir has $(( free_bytes / 1073741824 ))G free"
  fi
}

# ── Filesystem freeze ─────────────────────────
freeze_fs() {
  if ! command -v fsfreeze >/dev/null 2>&1; then
    warn "fsfreeze not available — imaging live filesystem"
    return
  fi

  local mount_point fstype
  while IFS= read -r line; do
    mount_point=$(echo "$line" | awk '{print $2}')
    fstype=$(echo "$line"      | awk '{print $3}')
    [[ "$mount_point" == "/" ]] && continue
    [[ "$fstype" =~ ^(tmpfs|devtmpfs|sysfs|proc|cgroup|overlay|squashfs)$ ]] && continue
    _FREEZE_MOUNTS+=("$mount_point")
  done < <(findmnt -n -o TARGET,FSTYPE --source "$DEVICE" 2>/dev/null || true)

  if [[ ${#_FREEZE_MOUNTS[@]} -eq 0 ]]; then
    warn "No freezable mount points found for $DEVICE — imaging live"
    return
  fi

  for mp in "${_FREEZE_MOUNTS[@]}"; do
    log "Freezing: $mp"
    fsfreeze -f "$mp"
  done
  _FS_FROZEN=1
}

thaw_fs() {
  [[ "$_FS_FROZEN" -eq 0 ]] && return
  for mp in "${_FREEZE_MOUNTS[@]}"; do
    log "Thawing: $mp"
    fsfreeze -u "$mp" || warn "Failed to thaw $mp"
  done
  _FS_FROZEN=0
}

trap 'thaw_fs' EXIT

# ── Imaging ───────────────────────────────────
is_ext_partition() {
  local fstype
  fstype=$(blkid -o value -s TYPE "$PARTITION" 2>/dev/null || true)
  [[ "$fstype" =~ ^ext[234]$ ]]
}

create_image() {
  # Skip compression here if converting later — avoid compress→decompress waste
  local do_compress="$COMPRESS"
  [[ "$FORMAT" != "raw" ]] && do_compress="no"

  if is_ext_partition; then
    log "Using e2image (used blocks only) on $PARTITION..."
    create_image_e2image "$do_compress"
  else
    warn "Non-ext filesystem — falling back to dd (full disk copy)"
    create_image_dd "$do_compress"
  fi
}

create_image_e2image() {
  local do_compress="$1"
  require_cmd e2image

  if [[ "$do_compress" == "yes" ]]; then
    log "Streaming $PARTITION → compressed image..."
    # e2image supports stdout via '-' — pipe straight into gzip, no temp file
    e2image -rap "$PARTITION" - | gzip -1 > "$OUTPUT_DIR/$COMPRESSED_NAME"
    log "Saved: $OUTPUT_DIR/$COMPRESSED_NAME ($(du -sh "$OUTPUT_DIR/$COMPRESSED_NAME" | cut -f1))"
  else
    log "Imaging $PARTITION → sparse raw..."
    e2image -rap "$PARTITION" "$OUTPUT_DIR/$IMAGE_NAME"
    log "Saved: $OUTPUT_DIR/$IMAGE_NAME ($(du -sh "$OUTPUT_DIR/$IMAGE_NAME" | cut -f1))"

    if [[ "$VERIFY" == "yes" ]]; then
      log "Computing checksum..."
      sha256sum "$OUTPUT_DIR/$IMAGE_NAME" > "$OUTPUT_DIR/$CHECKSUM_NAME"
      log "SHA256: $(awk '{print $1}' "$OUTPUT_DIR/$CHECKSUM_NAME")"
    fi
  fi
}

create_image_dd() {
  local do_compress="$1"

  if [[ "$do_compress" == "yes" ]]; then
    log "Streaming $PARTITION → compressed image (dd)..."
    dd if="$PARTITION" bs=4M status=progress 2>&1 | gzip -1 > "$OUTPUT_DIR/$COMPRESSED_NAME"
    log "Saved: $OUTPUT_DIR/$COMPRESSED_NAME ($(du -sh "$OUTPUT_DIR/$COMPRESSED_NAME" | cut -f1))"
  else
    log "Imaging $PARTITION → raw (dd)..."
    dd if="$PARTITION" bs=4M status=progress of="$OUTPUT_DIR/$IMAGE_NAME"
    log "Saved: $OUTPUT_DIR/$IMAGE_NAME ($(du -sh "$OUTPUT_DIR/$IMAGE_NAME" | cut -f1))"

    if [[ "$VERIFY" == "yes" ]]; then
      log "Computing checksum..."
      sha256sum "$OUTPUT_DIR/$IMAGE_NAME" > "$OUTPUT_DIR/$CHECKSUM_NAME"
      log "SHA256: $(awk '{print $1}' "$OUTPUT_DIR/$CHECKSUM_NAME")"
    fi
  fi
}

# ── Format conversion ─────────────────────────
install_qemu() {
  command -v qemu-img >/dev/null 2>&1 && return
  log "Installing qemu-img..."
  if   command -v apt-get >/dev/null 2>&1; then apt-get -qq update && apt-get -qq install -y qemu-utils
  elif command -v dnf     >/dev/null 2>&1; then dnf install -y qemu-img
  elif command -v yum     >/dev/null 2>&1; then yum install -y qemu-img
  elif command -v pacman  >/dev/null 2>&1; then pacman -Sy --noconfirm qemu-img
  else fail "Cannot install qemu-img: unsupported package manager"
  fi
}

convert_format() {
  [[ "$FORMAT" == "raw" ]] && return
  install_qemu

  if [[ -f "$OUTPUT_DIR/$COMPRESSED_NAME" && ! -f "$OUTPUT_DIR/$IMAGE_NAME" ]]; then
    log "Decompressing for conversion..."
    gunzip -f "$OUTPUT_DIR/$COMPRESSED_NAME"
  fi

  local input="$OUTPUT_DIR/$IMAGE_NAME"
  local output="$OUTPUT_DIR/snapshot.${FORMAT}"
  [[ -f "$input" ]] || fail "Raw image not found: $input"

  log "Converting to $FORMAT..."
  local qemu_opts=("-p" "-f" "raw" "-O" "$FORMAT")
  [[ "$COMPRESS" == "yes" && "$FORMAT" =~ ^(vmdk|qcow2)$ ]] && qemu_opts+=("-c")
  qemu-img convert "${qemu_opts[@]}" "$input" "$output"

  if [[ "$VERIFY" == "yes" ]]; then
    log "Verifying converted image..."
    qemu-img check -f "$FORMAT" "$output" \
      && log "Image check passed" \
      || warn "Image check reported issues — inspect manually"
  fi

  log "Converted: $output ($(du -sh "$output" | cut -f1))"
}

cleanup_raw() {
  [[ "$FORMAT" == "raw" ]] && return
  rm -f "$OUTPUT_DIR/$IMAGE_NAME"
  log "Removed intermediate raw image"
}

# ── Remote transfer ───────────────────────────
transfer_remote() {
  [[ -z "$REMOTE_TARGET" ]] && return

  local src
  if   [[ "$FORMAT" != "raw" && -f "$OUTPUT_DIR/snapshot.${FORMAT}" ]]; then
    src="$OUTPUT_DIR/snapshot.${FORMAT}"
  elif [[ "$COMPRESS" == "yes" && -f "$OUTPUT_DIR/$COMPRESSED_NAME" ]]; then
    src="$OUTPUT_DIR/$COMPRESSED_NAME"
  else
    src="$OUTPUT_DIR/$IMAGE_NAME"
  fi

  log "Transferring $(basename "$src") → ${REMOTE_TARGET}:${REMOTE_PATH} ..."
  rsync -ah --progress \
    -e "ssh -o StrictHostKeyChecking=accept-new" \
    "$src" "${REMOTE_TARGET}:${REMOTE_PATH}/"

  if [[ "$VERIFY" == "yes" && -f "$OUTPUT_DIR/$CHECKSUM_NAME" ]]; then
    rsync -ah -e "ssh -o StrictHostKeyChecking=accept-new" \
      "$OUTPUT_DIR/$CHECKSUM_NAME" "${REMOTE_TARGET}:${REMOTE_PATH}/"
    log "Verifying checksum on remote..."
    ssh "$REMOTE_TARGET" "cd ${REMOTE_PATH} && sha256sum -c ${CHECKSUM_NAME}" \
      && log "Remote checksum verified" \
      || warn "Remote checksum mismatch — transfer may be corrupt"
  fi

  log "Transfer complete"
}

# ── Summary ───────────────────────────────────
summary() {
  log "Export complete"
  echo
  ls -lh "$OUTPUT_DIR"
  echo
  touch /tmp/export-ok
}

# ── Main ──────────────────────────────────────
main() {
  require_root
  require_cmd lsblk
  require_cmd gzip

  validate_format
  validate_remote
  detect_device
  detect_partition
  prepare
  freeze_fs
  create_image
  thaw_fs
  convert_format
  cleanup_raw
  transfer_remote
  summary
}

main "$@"
