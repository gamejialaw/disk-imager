#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/disk_imager.conf"

DEFAULT_SOURCE_DISK="auto"
DEFAULT_BACKUP_ROOT="/root/samba"
DEFAULT_NAME_PREFIX="disk-image"

if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"
fi

SOURCE_DISK="${SOURCE_DISK:-$DEFAULT_SOURCE_DISK}"
BACKUP_ROOT="${BACKUP_ROOT:-$DEFAULT_BACKUP_ROOT}"
NAME_PREFIX="${NAME_PREFIX:-$DEFAULT_NAME_PREFIX}"

SKIP_ROOT_CHECK="${SKIP_ROOT_CHECK:-0}"
SKIP_RAW_HEADERS="${DISK_IMAGER_SKIP_RAW_HEADERS:-0}"
DEBUG="${DEBUG:-0}"
LOG_FILE="${DISK_IMAGER_LOG_FILE:-}"

_write_log_line() {
  local line="$1"
  printf '%s\n' "$line" >&2
  if [[ -n "${LOG_FILE:-}" ]]; then
    printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null || true
  fi
}

log() { _write_log_line "[$(date '+%F %T')] $*"; }
debug_log() {
  if [[ "${DEBUG:-0}" == "1" ]]; then
    _write_log_line "[DEBUG $(date '+%F %T')] $*"
  fi
}
err() { _write_log_line "ERROR: $*"; }
die() {
  err "$*"
  if [[ -n "${LOG_FILE:-}" ]]; then
    err "Debug log: $LOG_FILE"
  fi
  exit 1
}

init_logging() {
  if [[ -n "${LOG_FILE:-}" ]]; then
    mkdir -p "$(dirname -- "$LOG_FILE")" 2>/dev/null || true
    : >"$LOG_FILE" || die "Cannot write log file: $LOG_FILE"
    log "Logging enabled: $LOG_FILE"
  fi
}

run_debug_cmd() {
  local label="$1"
  shift
  local out rc
  debug_log "CMD: $*"
  out="$("$@" 2>&1)" || rc=$?
  rc="${rc:-0}"
  if [[ -n "$out" ]]; then
    while IFS= read -r line; do
      debug_log "$label: $line"
    done <<< "$out"
  fi
  debug_log "$label exit=$rc"
}

emit_debug_snapshot() {
  [[ "${DEBUG:-0}" == "1" ]] || return 0
  debug_log "===== Debug Snapshot Start ====="
  run_debug_cmd "id" id
  run_debug_cmd "uname" uname -a
  run_debug_cmd "pwd" pwd
  run_debug_cmd "mount" mount
  run_debug_cmd "lsblk_disks" lsblk -d -o NAME,PATH,TYPE,SIZE,MODEL
  run_debug_cmd "lsblk_all" lsblk -o NAME,PATH,TYPE,FSTYPE,SIZE,MOUNTPOINT
  run_debug_cmd "ls_dev_nvme" ls -l /dev/nvme0 /dev/nvme0n1 /dev/nvme0n1p1 /dev/nvme0n1p2 /dev/nvme0n1p3 /dev/nvme0n1p4
  run_debug_cmd "test_nvme0n1_block" bash -lc 'if test -b /dev/nvme0n1; then echo "/dev/nvme0n1 is block"; else echo "/dev/nvme0n1 is NOT block"; fi'
  run_debug_cmd "sys_block" ls -l /sys/block
  run_debug_cmd "sys_nvme" ls -l /sys/class/nvme
  debug_log "===== Debug Snapshot End ====="
}

require_cmd() {
  local missing=()
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if (( ${#missing[@]} > 0 )); then
    die "Missing required commands: ${missing[*]}"
  fi
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

available_disks_text() {
  if has_cmd lsblk; then
    lsblk -dnpo NAME,TYPE,SIZE,MODEL 2>/dev/null | awk '$2=="disk"{print $1" size="$3" model="$4}'
  elif [[ -d /sys/block ]]; then
    ls /sys/block 2>/dev/null | sed 's#^#/dev/#'
  fi
}

show_available_disks() {
  local disks
  disks="$(available_disks_text || true)"
  if [[ -n "$disks" ]]; then
    err "Available disks detected:"
    while IFS= read -r line; do
      [[ -n "$line" ]] && err "  $line"
    done <<< "$disks"
  else
    err "No disks detected via lsblk/sysfs in this environment."
  fi
}

require_root() {
  if [[ "$SKIP_ROOT_CHECK" == "1" ]]; then
    return
  fi
  if [[ "$(id -u)" -ne 0 ]]; then
    die "This script must run as root (or set SKIP_ROOT_CHECK=1 for tests)."
  fi
}

resolve_disk_device() {
  local disk="$1"
  if [[ "$SKIP_ROOT_CHECK" == "1" ]]; then
    printf '%s\n' "$disk"
    return
  fi
  if [[ -b "$disk" ]]; then
    printf '%s\n' "$disk"
    return
  fi

  if [[ -L "$disk" ]]; then
    local resolved
    resolved="$(readlink -f "$disk" 2>/dev/null || true)"
    if [[ -n "$resolved" && -b "$resolved" ]]; then
      printf '%s\n' "$resolved"
      return
    fi
  fi

  # Common pitfall: /dev/nvme0 is a controller node, while /dev/nvme0n1 is the disk.
  if [[ "$disk" =~ ^/dev/nvme[0-9]+$ ]] && [[ -b "${disk}n1" ]]; then
    log "Device $disk is a controller node; using ${disk}n1"
    printf '%s\n' "${disk}n1"
    return
  fi

  if [[ "$disk" =~ ^/dev/nvme[0-9]+n[0-9]+$ ]]; then
    err "Path exists but is not a usable block disk node: $disk"
    err "This usually means your current environment cannot access raw host disks."
    err "Run from a real Linux live system (not a restricted container/VM shell) and verify with: lsblk -d -o NAME,PATH,TYPE,SIZE"
  fi
  show_available_disks
  die "Device is not a block disk: $disk (for NVMe use /dev/nvmeXn1)"
}

is_nvme_controller_node() {
  local disk="$1"
  local node="${disk##/dev/}"
  [[ "$disk" =~ ^/dev/nvme[0-9]+$ ]] || return 1
  [[ -e "/sys/class/nvme/$node" ]] || return 1
  [[ ! -b "$disk" ]]
}

confirm_nvme_controller() {
  local disk="$1"
  if [[ "$SKIP_ROOT_CHECK" == "1" ]]; then
    return 1
  fi
  is_nvme_controller_node "$disk"
}

auto_detect_source_disk() {
  if [[ "$SKIP_ROOT_CHECK" == "1" ]]; then
    printf '%s\n' "/dev/mock0"
    return
  fi

  if [[ -b /dev/nvme0n1 ]]; then
    printf '%s\n' "/dev/nvme0n1"
    return
  fi

  require_cmd lsblk
  local disk
  disk="$(lsblk -dnpo NAME,TYPE,RM 2>/dev/null | awk '$2=="disk" && $3==0 {print $1; exit}')"
  [[ -n "$disk" ]] || die "Could not auto-detect a non-removable disk. Use --source <disk>."
  printf '%s\n' "$disk"
}

resolve_source_disk() {
  local disk="${1:-}"
  if [[ -z "$disk" || "$disk" == "auto" ]]; then
    disk="$(auto_detect_source_disk)"
    log "Auto-detected source disk: $disk"
  fi
  resolve_disk_device "$disk"
}

part_path_from_num() {
  local disk="$1"
  local partn="$2"
  if [[ "$disk" =~ [0-9]$ ]]; then
    printf '%sp%s\n' "$disk" "$partn"
  else
    printf '%s%s\n' "$disk" "$partn"
  fi
}

partclone_tool_for_fstype() {
  local fstype="${1,,}"
  case "$fstype" in
    ext2|ext3|ext4) echo "partclone.extfs" ;;
    xfs) echo "partclone.xfs" ;;
    btrfs) echo "partclone.btrfs" ;;
    ntfs) echo "partclone.ntfs" ;;
    vfat|fat|fat16|fat32) echo "partclone.fat" ;;
    exfat) echo "partclone.exfat" ;;
    swap) echo "partclone.swap" ;;
    reiserfs) echo "partclone.reiserfs" ;;
    hfsplus) echo "partclone.hfsp" ;;
    "") echo "partclone.dd" ;;
    *) echo "partclone.dd" ;;
  esac
}

ensure_backup_dir() {
  local dir="$1"
  mkdir -p "$dir" || die "Cannot create backup directory: $dir"
}

save_metadata() {
  local disk="$1"
  local outdir="$2"

  local ptable_method=""
  if has_cmd sfdisk; then
    sfdisk --dump "$disk" >"$outdir/partition_table.sfdisk"
    sfdisk --json "$disk" >"$outdir/partition_table.json"
    ptable_method="sfdisk"
  else
    ptable_method="dd-gzip"
  fi
  lsblk -J -b -o NAME,PATH,SIZE,TYPE,FSTYPE,PARTUUID,UUID,LABEL "$disk" >"$outdir/lsblk.json"
  lsblk -lnbpo NAME,TYPE,SIZE,FSTYPE "$disk" >"$outdir/partitions.tsv"

  {
    echo "source_disk=$disk"
    echo "backup_time_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "hostname=$(hostname 2>/dev/null || true)"
    echo "kernel=$(uname -r 2>/dev/null || true)"
    echo "partition_table_method=$ptable_method"
  } >"$outdir/metadata.txt"

  # Always keep compressed raw table headers as a robust fallback.
  if [[ "$SKIP_RAW_HEADERS" != "1" ]] && has_cmd blockdev && has_cmd dd && has_cmd gzip; then
      local sectors start
      dd if="$disk" bs=512 count=4096 status=none | gzip -1 >"$outdir/disk-head-2MiB.bin.gz" || true
      sectors="$(blockdev --getsz "$disk" 2>/dev/null || echo 0)"
      if [[ "$sectors" =~ ^[0-9]+$ ]] && (( sectors > 4096 )); then
        start=$((sectors - 4096))
        dd if="$disk" bs=512 skip="$start" count=4096 status=none | gzip -1 >"$outdir/disk-tail-2MiB.bin.gz" || true
      fi
  fi
}

list_partitions() {
  local disk="$1"
  lsblk -lnpo NAME,TYPE,FSTYPE "$disk" | awk '$2 == "part" {print $1"\t"$3}'
}

preflight_backup() {
  local disk="$1"
  local backup_root="$2"
  local mode_ptable="dd+gzip"

  log "Preflight (backup)"
  log "Source disk: $disk"
  log "Backup root: $backup_root"

  if has_cmd sfdisk; then
    mode_ptable="sfdisk"
  fi
  log "Partition table backup method: $mode_ptable"

  if has_cmd sfdisk; then log "Tool available: sfdisk"; else log "Tool missing: sfdisk (fallback active)"; fi
  if has_cmd dd; then log "Tool available: dd"; else die "Required fallback tool missing: dd"; fi
  if has_cmd gzip; then log "Tool available: gzip"; else die "Required fallback tool missing: gzip"; fi

  if confirm_nvme_controller "/dev/nvme0"; then
    log "Confirmed: /dev/nvme0 is an NVMe controller node (non-block); use /dev/nvme0n1 for disk imaging."
  fi

  local part fstype tool
  while IFS=$'\t' read -r part fstype; do
    [[ -n "$part" ]] || continue
    tool="$(partclone_tool_for_fstype "$fstype")"
    if has_cmd "$tool"; then
      log "Partition $part fstype=${fstype:-unknown} -> method=partclone ($tool)"
    else
      log "Partition $part fstype=${fstype:-unknown} -> method=dd+gzip (missing $tool)"
    fi
  done < <(list_partitions "$disk")
}

preflight_restore() {
  local target_disk="$1"
  local backup_dir="$2"
  local ptable_method="dd+gzip"

  log "Preflight (restore)"
  log "Target disk: $target_disk"
  log "Backup dir: $backup_dir"

  [[ -d "$backup_dir" ]] || die "Backup directory does not exist: $backup_dir"
  [[ -f "$backup_dir/manifest.tsv" ]] || die "Missing manifest.tsv"

  if [[ -f "$backup_dir/partition_table.sfdisk" ]] && has_cmd sfdisk; then
    ptable_method="sfdisk"
  fi
  log "Partition table restore method: $ptable_method"

  local partn fstype tool relimg img
  while IFS=$'\t' read -r partn fstype tool relimg; do
    [[ -n "$partn" ]] || continue
    img="$backup_dir/$relimg"
    [[ -f "$img" ]] || die "Missing image file: $img"
    if [[ "$tool" == "dd+gzip" ]]; then
      log "Partition $partn restore method=dd+gzip"
    elif has_cmd "$tool"; then
      log "Partition $partn restore method=partclone ($tool)"
    elif [[ "$img" == *.gz ]]; then
      log "Partition $partn restore method=dd+gzip fallback (missing $tool)"
    else
      die "Partition $partn cannot be restored: missing $tool and image is not .gz"
    fi
  done <"$backup_dir/manifest.tsv"
}

backup_drive() {
  local disk="$1"
  local backup_root="$2"
  local name_override="${3:-}"

  require_root
  require_cmd lsblk sha256sum dd gzip

  local stamp backup_name outdir
  disk="$(resolve_source_disk "$disk")"
  stamp="$(date '+%Y%m%d-%H%M%S')"
  if [[ -n "$name_override" ]]; then
    backup_name="$name_override"
  else
    backup_name="${NAME_PREFIX}-${stamp}"
  fi
  outdir="${backup_root%/}/$backup_name"

  preflight_backup "$disk" "$backup_root"
  ensure_backup_dir "$outdir"
  save_metadata "$disk" "$outdir"

  : >"$outdir/manifest.tsv"
  : >"$outdir/checksums.txt"

  local line part fstype partn tool img relimg sum
  while IFS=$'\t' read -r part fstype; do
    [[ -n "$part" ]] || continue
    partn="$(lsblk -no PARTN "$part" | tr -d '[:space:]')"
    if [[ -z "$partn" ]]; then
      die "Could not determine partition number for $part"
    fi

    if [[ -z "$fstype" ]]; then
      fstype="$(blkid -o value -s TYPE "$part" 2>/dev/null || true)"
    fi

    tool="$(partclone_tool_for_fstype "$fstype")"
    if has_cmd "$tool"; then
      relimg="part-${partn}-${fstype:-unknown}.img"
      img="$outdir/$relimg"
      log "Backing up $part (fstype=${fstype:-unknown}, method=partclone, tool=$tool)"
      "$tool" -c -s "$part" -o "$img"
    else
      tool="dd+gzip"
      relimg="part-${partn}-${fstype:-unknown}.img.gz"
      img="$outdir/$relimg"
      log "Backing up $part (fstype=${fstype:-unknown}, method=dd+gzip)"
      dd if="$part" bs=16M status=none | gzip -1 >"$img"
    fi

    sum="$(sha256sum "$img" | awk '{print $1}')"
    printf '%s  %s\n' "$sum" "$relimg" >>"$outdir/checksums.txt"
    printf '%s\t%s\t%s\t%s\n' "$partn" "${fstype:-unknown}" "$tool" "$relimg" >>"$outdir/manifest.tsv"
  done < <(list_partitions "$disk")

  log "Backup finished: $outdir"
  printf '%s\n' "$outdir"
}

verify_backup() {
  local backup_dir="$1"
  local compare_disk="${2:-}"

  require_cmd sha256sum
  [[ -d "$backup_dir" ]] || die "Backup directory does not exist: $backup_dir"
  [[ -f "$backup_dir/manifest.tsv" ]] || die "Missing manifest.tsv"
  [[ -f "$backup_dir/checksums.txt" ]] || die "Missing checksums.txt"
  [[ -f "$backup_dir/partition_table.sfdisk" || -f "$backup_dir/disk-head-2MiB.bin.gz" ]] || die "Missing partition table backup files"

  log "Checking checksums"
  (cd "$backup_dir" && sha256sum -c checksums.txt >/dev/null)

  local partn fstype tool relimg
  while IFS=$'\t' read -r partn fstype tool relimg; do
    [[ -n "$partn" ]] || continue
    [[ -f "$backup_dir/$relimg" ]] || die "Image missing: $relimg"
  done <"$backup_dir/manifest.tsv"

  if [[ -n "$compare_disk" ]]; then
    require_cmd lsblk
    log "Comparing backup manifest against current disk layout: $compare_disk"

    local expected_count actual_count
    expected_count="$(awk 'NF>0{c++} END{print c+0}' "$backup_dir/manifest.tsv")"
    actual_count="$(lsblk -lnpo NAME,TYPE "$compare_disk" | awk '$2=="part"{c++} END{print c+0}')"
    if [[ "$expected_count" != "$actual_count" ]]; then
      die "Partition count mismatch: backup=$expected_count current=$actual_count"
    fi

    while IFS=$'\t' read -r partn fstype tool relimg; do
      [[ -n "$partn" ]] || continue
      local part curfst
      part="$(part_path_from_num "$compare_disk" "$partn")"
      curfst="$(lsblk -no FSTYPE "$part" | tr -d '[:space:]')"
      if [[ -z "$curfst" ]]; then
        curfst="unknown"
      fi
      if [[ "${fstype:-unknown}" != "unknown" && "$curfst" != "${fstype:-unknown}" ]]; then
        die "Filesystem mismatch on part $partn: backup=${fstype:-unknown} current=$curfst"
      fi
    done <"$backup_dir/manifest.tsv"
  fi

  log "Backup verification successful: $backup_dir"
}

restore_drive() {
  local target_disk="$1"
  local backup_dir="$2"
  local assume_yes="${3:-0}"

  require_root
  require_cmd lsblk partprobe udevadm dd gzip
  target_disk="$(resolve_disk_device "$target_disk")"
  [[ -d "$backup_dir" ]] || die "Backup directory does not exist: $backup_dir"
  [[ -f "$backup_dir/partition_table.sfdisk" || -f "$backup_dir/disk-head-2MiB.bin.gz" ]] || die "Missing partition table backup files"
  [[ -f "$backup_dir/manifest.tsv" ]] || die "Missing manifest.tsv"

  verify_backup "$backup_dir"
  preflight_restore "$target_disk" "$backup_dir"

  if [[ "$assume_yes" != "1" ]]; then
    printf 'About to wipe and restore %s from %s\n' "$target_disk" "$backup_dir"
    printf 'Type RESTORE to continue: '
    local confirm
    read -r confirm
    [[ "$confirm" == "RESTORE" ]] || die "Restore cancelled"
  fi

  log "Unmounting partitions on $target_disk (if mounted)"
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    if mountpoint -q "$p" 2>/dev/null; then
      umount "$p"
    fi
  done < <(lsblk -lnpo NAME,TYPE "$target_disk" | awk '$2=="part"{print $1}')

  if command -v wipefs >/dev/null 2>&1; then
    wipefs -a "$target_disk" || true
  fi

  if has_cmd sfdisk && [[ -f "$backup_dir/partition_table.sfdisk" ]]; then
    log "Restoring partition table onto $target_disk using sfdisk"
    sfdisk "$target_disk" <"$backup_dir/partition_table.sfdisk"
  else
    log "sfdisk unavailable or missing table dump; restoring raw table headers with dd+gzip"
    [[ -f "$backup_dir/disk-head-2MiB.bin.gz" ]] || die "Missing disk-head-2MiB.bin.gz"
    gzip -dc "$backup_dir/disk-head-2MiB.bin.gz" | dd of="$target_disk" bs=512 conv=fsync status=none
    if [[ -f "$backup_dir/disk-tail-2MiB.bin.gz" ]] && has_cmd blockdev; then
      local sectors start
      sectors="$(blockdev --getsz "$target_disk" 2>/dev/null || echo 0)"
      if [[ "$sectors" =~ ^[0-9]+$ ]] && (( sectors > 4096 )); then
        start=$((sectors - 4096))
        gzip -dc "$backup_dir/disk-tail-2MiB.bin.gz" | dd of="$target_disk" bs=512 seek="$start" conv=fsync status=none
      fi
    fi
  fi
  partprobe "$target_disk" || true
  udevadm settle || true
  sleep 1

  local partn fstype tool relimg target_part img
  while IFS=$'\t' read -r partn fstype tool relimg; do
    [[ -n "$partn" ]] || continue
    target_part="$(part_path_from_num "$target_disk" "$partn")"
    img="$backup_dir/$relimg"

    [[ -f "$img" ]] || die "Missing image file: $img"

    if [[ "$tool" == "dd+gzip" ]]; then
      log "Restoring partition $target_part using dd+gzip"
      gzip -dc "$img" | dd of="$target_part" bs=16M conv=fsync status=none
    else
      if has_cmd "$tool"; then
        log "Restoring partition $target_part using $tool"
        "$tool" -r -s "$img" -o "$target_part"
      else
        if [[ "$img" == *.gz ]]; then
          log "Tool $tool unavailable, falling back to dd+gzip restore for $target_part"
          gzip -dc "$img" | dd of="$target_part" bs=16M conv=fsync status=none
        else
          die "Restore tool $tool is unavailable and image is not gzip fallback format: $img"
        fi
      fi
    fi
  done <"$backup_dir/manifest.tsv"

  partprobe "$target_disk" || true
  udevadm settle || true
  log "Restore completed: $target_disk"
}

choose_with_whiptail() {
  whiptail --title "Disk Imager" --menu "Choose an action" 16 70 8 \
    "backup" "Create backup image set" \
    "quick-backup" "One-step backup (auto disk + default path)" \
    "restore" "Restore disk from backup" \
    "verify" "Verify backup integrity" \
    "exit" "Quit" 3>&1 1>&2 2>&3
}

input_with_whiptail() {
  local title="$1"
  local prompt="$2"
  local init="$3"
  whiptail --title "$title" --inputbox "$prompt" 10 80 "$init" 3>&1 1>&2 2>&3
}

run_tui() {
  local action
  if [[ -n "${LOG_FILE:-}" ]]; then
    log "TUI debug log file: $LOG_FILE"
  fi
  if command -v whiptail >/dev/null 2>&1; then
    while true; do
      action="$(choose_with_whiptail || true)"
      case "$action" in
        backup)
          local disk dir name
          disk="$(input_with_whiptail "Backup" "Source disk" "$SOURCE_DISK")" || continue
          dir="$(input_with_whiptail "Backup" "Backup root directory" "$BACKUP_ROOT")" || continue
          name="$(input_with_whiptail "Backup" "Backup name (blank = auto)" "")" || true
          backup_drive "$disk" "$dir" "$name"
          ;;
        quick-backup)
          backup_drive "auto" "$BACKUP_ROOT" ""
          ;;
        restore)
          local tdisk bdir
          tdisk="$(input_with_whiptail "Restore" "Target disk to wipe and restore" "$SOURCE_DISK")" || continue
          bdir="$(input_with_whiptail "Restore" "Backup directory" "$BACKUP_ROOT")" || continue
          restore_drive "$tdisk" "$bdir" 0
          ;;
        verify)
          local vdir cdisk
          vdir="$(input_with_whiptail "Verify" "Backup directory" "$BACKUP_ROOT")" || continue
          cdisk="$(input_with_whiptail "Verify" "Optional compare disk (blank to skip)" "")" || true
          verify_backup "$vdir" "$cdisk"
          ;;
        exit|"")
          break
          ;;
      esac
    done
  else
    cat <<'TXT'
whiptail not found. Falling back to text prompts.
Actions: backup | quick-backup | restore | verify | exit
TXT
    while true; do
      printf 'Action: '
      read -r action
      case "$action" in
        backup)
          local disk dir name
          printf 'Source disk [%s]: ' "$SOURCE_DISK"; read -r disk; disk="${disk:-$SOURCE_DISK}"
          printf 'Backup root [%s]: ' "$BACKUP_ROOT"; read -r dir; dir="${dir:-$BACKUP_ROOT}"
          printf 'Backup name (blank=auto): '; read -r name
          backup_drive "$disk" "$dir" "$name"
          ;;
        quick-backup)
          backup_drive "auto" "$BACKUP_ROOT" ""
          ;;
        restore)
          local tdisk bdir
          printf 'Target disk [%s]: ' "$SOURCE_DISK"; read -r tdisk; tdisk="${tdisk:-$SOURCE_DISK}"
          printf 'Backup directory: '; read -r bdir
          restore_drive "$tdisk" "$bdir" 0
          ;;
        verify)
          local vdir cdisk
          printf 'Backup directory: '; read -r vdir
          printf 'Compare disk (blank=skip): '; read -r cdisk
          verify_backup "$vdir" "$cdisk"
          ;;
        exit) break ;;
      esac
    done
  fi
}

usage() {
  cat <<'TXT'
Usage:
  disk_imager.sh preflight --source <disk|auto> [--backup-root <dir>] [--backup-dir <dir>] [--target <disk>]
  disk_imager.sh quick-backup|qb [--source <disk|auto>] [--backup-root <dir>] [--name <backup-name>]
  disk_imager.sh backup  --source <disk|auto> --backup-root <dir> [--name <backup-name>]
  disk_imager.sh restore --target <disk> --backup-dir <dir> [--yes]
  disk_imager.sh verify  --backup-dir <dir> [--compare-disk <disk>]
  disk_imager.sh tui
  disk_imager.sh <cmd> [--debug] [--log-file <path>]

Defaults can be set in disk_imager.conf:
  SOURCE_DISK=auto
  BACKUP_ROOT=/root/samba
  NAME_PREFIX=disk-image
TXT
}

main() {
  local cmd="${1:-tui}"
  shift || true

  local source="$SOURCE_DISK"
  local target="$SOURCE_DISK"
  local backup_root="$BACKUP_ROOT"
  local backup_dir=""
  local compare_disk=""
  local name=""
  local yes=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --source) source="$2"; shift 2 ;;
      --target) target="$2"; shift 2 ;;
      --backup-root) backup_root="$2"; shift 2 ;;
      --backup-dir) backup_dir="$2"; shift 2 ;;
      --compare-disk) compare_disk="$2"; shift 2 ;;
      --name) name="$2"; shift 2 ;;
      --yes) yes=1; shift ;;
      --debug) DEBUG=1; shift ;;
      --log-file) LOG_FILE="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown argument: $1" ;;
    esac
  done

  if [[ "$cmd" == "tui" && "$DEBUG" != "1" && -z "$LOG_FILE" ]]; then
    DEBUG=1
    LOG_FILE="/tmp/disk_imager_tui_$(date '+%Y%m%d_%H%M%S').log"
  fi
  if [[ ( "$cmd" == "quick-backup" || "$cmd" == "qb" ) && "$DEBUG" != "1" && -z "$LOG_FILE" ]]; then
    DEBUG=1
    LOG_FILE="/tmp/disk_imager_quick_$(date '+%Y%m%d_%H%M%S').log"
  fi
  if [[ "$DEBUG" == "1" && -z "$LOG_FILE" ]]; then
    LOG_FILE="/tmp/disk_imager_debug_$(date '+%Y%m%d_%H%M%S').log"
  fi
  init_logging
  emit_debug_snapshot

  case "$cmd" in
    preflight)
      source="$(resolve_source_disk "$source")"
      preflight_backup "$source" "$backup_root"
      if [[ -n "$backup_dir" ]]; then
        target="$(resolve_source_disk "$target")"
        preflight_restore "$target" "$backup_dir"
      fi
      ;;
    backup)
      backup_drive "$source" "$backup_root" "$name"
      ;;
    quick-backup|qb)
      backup_drive "${source:-auto}" "$backup_root" "$name"
      ;;
    restore)
      [[ -n "$backup_dir" ]] || die "--backup-dir is required for restore"
      restore_drive "$target" "$backup_dir" "$yes"
      ;;
    verify)
      [[ -n "$backup_dir" ]] || die "--backup-dir is required for verify"
      if [[ -n "$compare_disk" ]]; then
        compare_disk="$(resolve_disk_device "$compare_disk")"
      fi
      verify_backup "$backup_dir" "$compare_disk"
      ;;
    tui)
      run_tui
      ;;
    *)
      usage
      die "Unknown command: $cmd"
      ;;
  esac
}

main "$@"
