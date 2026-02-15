#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
MOCK_LOG="$TMP_DIR/mock.log"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

assert_file() {
  [[ -f "$1" ]] || { echo "Missing file: $1" >&2; exit 1; }
}

assert_contains() {
  local needle="$1"
  local file="$2"
  grep -F "$needle" "$file" >/dev/null || {
    echo "Expected '$needle' in $file" >&2
    cat "$file" >&2
    exit 1
  }
}

assert_not_file() {
  [[ ! -f "$1" ]] || { echo "File should not exist: $1" >&2; exit 1; }
}

setup_common_mocks() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"

  cat > "$bin_dir/lsblk" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
args="$*"

case "$args" in
  "-lnpo NAME,TYPE,FSTYPE /dev/mock0")
    cat <<'OUT'
/dev/mock0 disk 
/dev/mock0p1 part ntfs
/dev/mock0p2 part ext4
OUT
    ;;
  "-no PARTN /dev/mock0p1") echo 1 ;;
  "-no PARTN /dev/mock0p2") echo 2 ;;
  "-J -b -o NAME,PATH,SIZE,TYPE,FSTYPE,PARTUUID,UUID,LABEL /dev/mock0")
    echo '{"blockdevices":[{"name":"mock0","path":"/dev/mock0","size":1000000,"type":"disk","children":[{"name":"mock0p1","path":"/dev/mock0p1","size":500000,"type":"part","fstype":"ntfs"},{"name":"mock0p2","path":"/dev/mock0p2","size":500000,"type":"part","fstype":"ext4"}]}]}'
    ;;
  "-lnbpo NAME,TYPE,SIZE,FSTYPE /dev/mock0")
    cat <<'OUT'
/dev/mock0 disk 1000000 
/dev/mock0p1 part 500000 ntfs
/dev/mock0p2 part 500000 ext4
OUT
    ;;
  "-lnpo NAME,TYPE /dev/mock0")
    cat <<'OUT'
/dev/mock0 disk
/dev/mock0p1 part
/dev/mock0p2 part
OUT
    ;;
  "-lnpo NAME,TYPE /dev/mock1")
    cat <<'OUT'
/dev/mock1 disk
/dev/mock1p1 part
/dev/mock1p2 part
OUT
    ;;
  "-no FSTYPE /dev/mock0p1") echo ntfs ;;
  "-no FSTYPE /dev/mock0p2") echo ext4 ;;
  "-no FSTYPE /dev/mock1p1") echo ntfs ;;
  "-no FSTYPE /dev/mock1p2") echo ext4 ;;
  *)
    echo "Unexpected lsblk args: $args" >&2
    exit 1
    ;;
esac
MOCK
  chmod +x "$bin_dir/lsblk"

  cat > "$bin_dir/blkid" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
part="${*: -1}"
case "$part" in
  /dev/mock0p1|/dev/mock1p1) echo ntfs ;;
  /dev/mock0p2|/dev/mock1p2) echo ext4 ;;
  *) exit 1 ;;
esac
MOCK
  chmod +x "$bin_dir/blkid"

  cat > "$bin_dir/dd" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if_arg=""
of_arg=""
seek_arg="0"
for a in "$@"; do
  case "$a" in
    if=*) if_arg="${a#if=}" ;;
    of=*) of_arg="${a#of=}" ;;
    seek=*) seek_arg="${a#seek=}" ;;
  esac
done

if [[ -n "$of_arg" ]]; then
  if [[ -p /dev/stdin || ! -t 0 ]]; then
    cat >/dev/null || true
  fi
  if [[ "$of_arg" == /dev/mock* ]]; then
    echo "dd_write:${of_arg}:if=${if_arg}:seek=${seek_arg}" >> "${MOCK_LOG}"
  else
    if [[ -n "$if_arg" ]]; then
      printf 'dd_data:%s\n' "$if_arg" > "$of_arg"
    fi
  fi
else
  if [[ -n "$if_arg" ]]; then
    printf 'dd_data:%s\n' "$if_arg"
  fi
fi
MOCK
  chmod +x "$bin_dir/dd"

  cat > "$bin_dir/blockdev" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--getsz" ]]; then
  echo 100000
else
  exit 1
fi
MOCK
  chmod +x "$bin_dir/blockdev"

  for cmd in partprobe udevadm wipefs; do
    cat > "$bin_dir/$cmd" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
    chmod +x "$bin_dir/$cmd"
  done

  cat > "$bin_dir/mountpoint" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
  chmod +x "$bin_dir/mountpoint"

  cat > "$bin_dir/umount" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
  chmod +x "$bin_dir/umount"
}

setup_normal_mocks() {
  local bin_dir="$1"
  setup_common_mocks "$bin_dir"

  cat > "$bin_dir/sfdisk" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--dump" ]]; then
  cat <<'OUT'
label: gpt
device: /dev/mock0
unit: sectors

/dev/mock0p1 : start=2048, size=500000, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7
/dev/mock0p2 : start=502048, size=497952, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4
OUT
elif [[ "${1:-}" == "--json" ]]; then
  echo '{"partitiontable":{"label":"gpt","device":"/dev/mock0","partitions":[{"node":"/dev/mock0p1"},{"node":"/dev/mock0p2"}]}}'
else
  disk="${1:-unknown}"
  cat >/dev/null
  echo "sfdisk_restore:${disk}" >> "${MOCK_LOG}"
fi
MOCK
  chmod +x "$bin_dir/sfdisk"

  cat > "$bin_dir/partclone-mock" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
mode=""
src=""
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c) mode="clone"; shift ;;
    -r) mode="restore"; shift ;;
    -s) src="$2"; shift 2 ;;
    -o) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
name="$(basename "$0")"
if [[ "$mode" == "clone" ]]; then
  echo "${name}:$src" > "$out"
elif [[ "$mode" == "restore" ]]; then
  echo "restore:${name}:${src}:${out}" >> "${MOCK_LOG}"
else
  echo "invalid mode" >&2
  exit 1
fi
MOCK
  chmod +x "$bin_dir/partclone-mock"
  ln -s "$bin_dir/partclone-mock" "$bin_dir/partclone.extfs"
  ln -s "$bin_dir/partclone-mock" "$bin_dir/partclone.ntfs"
  ln -s "$bin_dir/partclone-mock" "$bin_dir/partclone.dd"
}

setup_fallback_mocks() {
  local bin_dir="$1"
  setup_common_mocks "$bin_dir"
  # Intentionally no sfdisk and no partclone binaries in fallback mode.
}

setup_realistic_nvme_mocks() {
  local bin_dir="$1"
  setup_common_mocks "$bin_dir"

  cat > "$bin_dir/lsblk" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
args="$*"

case "$args" in
  "-lnpo NAME,TYPE,FSTYPE /dev/nvme0n1")
    cat <<'OUT'
/dev/nvme0n1 disk
/dev/nvme0n1p1 part vfat
/dev/nvme0n1p2 part
/dev/nvme0n1p3 part ntfs
/dev/nvme0n1p4 part ntfs
OUT
    ;;
  "-no PARTN /dev/nvme0n1p1") echo 1 ;;
  "-no PARTN /dev/nvme0n1p2") echo 2 ;;
  "-no PARTN /dev/nvme0n1p3") echo 3 ;;
  "-no PARTN /dev/nvme0n1p4") echo 4 ;;
  "-J -b -o NAME,PATH,SIZE,TYPE,FSTYPE,PARTUUID,UUID,LABEL /dev/nvme0n1")
    cat <<'OUT'
{"blockdevices":[{"name":"nvme0n1","path":"/dev/nvme0n1","size":512110190592,"type":"disk","children":[{"name":"nvme0n1p1","path":"/dev/nvme0n1p1","size":104857600,"type":"part","fstype":"vfat"},{"name":"nvme0n1p2","path":"/dev/nvme0n1p2","size":16777216,"type":"part","fstype":null},{"name":"nvme0n1p3","path":"/dev/nvme0n1p3","size":510242791424,"type":"part","fstype":"ntfs"},{"name":"nvme0n1p4","path":"/dev/nvme0n1p4","size":1048576000,"type":"part","fstype":"ntfs"}]}]}
OUT
    ;;
  "-lnbpo NAME,TYPE,SIZE,FSTYPE /dev/nvme0n1")
    cat <<'OUT'
/dev/nvme0n1 disk 512110190592
/dev/nvme0n1p1 part 104857600 vfat
/dev/nvme0n1p2 part 16777216
/dev/nvme0n1p3 part 510242791424 ntfs
/dev/nvme0n1p4 part 1048576000 ntfs
OUT
    ;;
  "-lnpo NAME,TYPE /dev/nvme0n1")
    cat <<'OUT'
/dev/nvme0n1 disk
/dev/nvme0n1p1 part
/dev/nvme0n1p2 part
/dev/nvme0n1p3 part
/dev/nvme0n1p4 part
OUT
    ;;
  "-no FSTYPE /dev/nvme0n1p1") echo vfat ;;
  "-no FSTYPE /dev/nvme0n1p2") echo "" ;;
  "-no FSTYPE /dev/nvme0n1p3") echo ntfs ;;
  "-no FSTYPE /dev/nvme0n1p4") echo ntfs ;;
  "-no PARTUUID /dev/nvme0n1p1") echo "1111-AAAA" ;;
  "-no PARTUUID /dev/nvme0n1p2") echo "2222-BBBB" ;;
  "-no PARTUUID /dev/nvme0n1p3") echo "3333-CCCC" ;;
  "-no PARTUUID /dev/nvme0n1p4") echo "4444-DDDD" ;;
  "-no UUID /dev/nvme0n1p1") echo "EFI-UUID" ;;
  "-no UUID /dev/nvme0n1p2") echo "" ;;
  "-no UUID /dev/nvme0n1p3") echo "WIN-UUID" ;;
  "-no UUID /dev/nvme0n1p4") echo "REC-UUID" ;;
  *)
    echo "Unexpected lsblk args: $args" >&2
    exit 1
    ;;
esac
MOCK
  chmod +x "$bin_dir/lsblk"

  cat > "$bin_dir/blkid" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
part="${*: -1}"
case "$part" in
  /dev/nvme0n1p1) echo vfat ;;
  /dev/nvme0n1p3|/dev/nvme0n1p4) echo ntfs ;;
  /dev/nvme0n1p2) exit 1 ;;
  *) exit 1 ;;
esac
MOCK
  chmod +x "$bin_dir/blkid"

  cat > "$bin_dir/blockdev" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--getsz" ]]; then
  echo 100000
elif [[ "${1:-}" == "--getsize64" ]]; then
  echo 104857600
else
  exit 1
fi
MOCK
  chmod +x "$bin_dir/blockdev"

  cat > "$bin_dir/sfdisk" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--dump" ]]; then
  cat <<'OUT'
label: gpt
device: /dev/nvme0n1
unit: sectors

/dev/nvme0n1p1 : start=2048, size=204800, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
/dev/nvme0n1p2 : start=206848, size=32768, type=E3C9E316-0B5C-4DB8-817D-F92DF00215AE
/dev/nvme0n1p3 : start=239616, size=996567040, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7
/dev/nvme0n1p4 : start=996806656, size=2048000, type=DE94BBA4-06D1-4D40-A16A-BFD50179D6AC
OUT
elif [[ "${1:-}" == "--json" ]]; then
  echo '{"partitiontable":{"label":"gpt","device":"/dev/nvme0n1","partitions":[{"node":"/dev/nvme0n1p1"},{"node":"/dev/nvme0n1p2"},{"node":"/dev/nvme0n1p3"},{"node":"/dev/nvme0n1p4"}]}}'
else
  disk="${1:-unknown}"
  cat >/dev/null
  echo "sfdisk_restore:${disk}" >> "${MOCK_LOG}"
fi
MOCK
  chmod +x "$bin_dir/sfdisk"

  cat > "$bin_dir/partclone-mock" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
mode=""
src=""
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c) mode="clone"; shift ;;
    -r) mode="restore"; shift ;;
    -s) src="$2"; shift 2 ;;
    -o) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
name="$(basename "$0")"
if [[ "$mode" == "clone" ]]; then
  echo "${name}:$src" > "$out"
elif [[ "$mode" == "restore" ]]; then
  echo "restore:${name}:${src}:${out}" >> "${MOCK_LOG}"
else
  echo "invalid mode" >&2
  exit 1
fi
MOCK
  chmod +x "$bin_dir/partclone-mock"
  ln -s "$bin_dir/partclone-mock" "$bin_dir/partclone.fat"
  ln -s "$bin_dir/partclone-mock" "$bin_dir/partclone.ntfs"
}

run_normal_path_tests() {
  local bin_dir="$TMP_DIR/mockbin-normal"
  setup_normal_mocks "$bin_dir"

  export PATH="$bin_dir:/usr/bin:/bin"
  export SKIP_ROOT_CHECK=1
  export DISK_IMAGER_SKIP_RAW_HEADERS=1
  export MOCK_LOG

  local backup_root="$TMP_DIR/backups-normal"
  mkdir -p "$backup_root"

  "$ROOT_DIR/disk_imager.sh" backup --source /dev/mock0 --backup-root "$backup_root" --name snap1 >/dev/null

  local snap="$backup_root/snap1"
  assert_file "$snap/manifest.tsv"
  assert_file "$snap/checksums.txt"
  assert_file "$snap/partition_table.sfdisk"
  assert_file "$snap/part-1-ntfs.img"
  assert_file "$snap/part-2-ext4.img"

  (cd "$snap" && sha256sum -c checksums.txt >/dev/null)
  "$ROOT_DIR/disk_imager.sh" verify --backup-dir "$snap" --compare-disk /dev/mock0 >/dev/null

  : > "$MOCK_LOG"
  "$ROOT_DIR/disk_imager.sh" restore --target /dev/mock1 --backup-dir "$snap" --yes >/dev/null

  assert_contains "sfdisk_restore:/dev/mock1" "$MOCK_LOG"
  assert_contains "restore:partclone.ntfs:$snap/part-1-ntfs.img:/dev/mock1p1" "$MOCK_LOG"
  assert_contains "restore:partclone.extfs:$snap/part-2-ext4.img:/dev/mock1p2" "$MOCK_LOG"
}

run_fallback_path_tests() {
  local bin_dir="$TMP_DIR/mockbin-fallback"
  setup_fallback_mocks "$bin_dir"

  export PATH="$bin_dir:/usr/bin:/bin"
  export SKIP_ROOT_CHECK=1
  export DISK_IMAGER_SKIP_RAW_HEADERS=0
  export MOCK_LOG

  local backup_root="$TMP_DIR/backups-fallback"
  mkdir -p "$backup_root"

  "$ROOT_DIR/disk_imager.sh" backup --source /dev/mock0 --backup-root "$backup_root" --name snap2 >/dev/null

  local snap="$backup_root/snap2"
  assert_file "$snap/manifest.tsv"
  assert_file "$snap/checksums.txt"
  assert_not_file "$snap/partition_table.sfdisk"
  assert_file "$snap/disk-head-2MiB.bin.gz"
  assert_file "$snap/disk-tail-2MiB.bin.gz"
  assert_file "$snap/part-1-ntfs.img.gz"
  assert_file "$snap/part-2-ext4.img.gz"

  assert_contains $'1\tntfs\tdd+gzip\tpart-1-ntfs.img.gz' "$snap/manifest.tsv"
  assert_contains $'2\text4\tdd+gzip\tpart-2-ext4.img.gz' "$snap/manifest.tsv"

  (cd "$snap" && sha256sum -c checksums.txt >/dev/null)
  "$ROOT_DIR/disk_imager.sh" verify --backup-dir "$snap" --compare-disk /dev/mock0 >/dev/null

  : > "$MOCK_LOG"
  "$ROOT_DIR/disk_imager.sh" restore --target /dev/mock1 --backup-dir "$snap" --yes >/dev/null

  assert_contains "dd_write:/dev/mock1:if=:seek=0" "$MOCK_LOG"
  assert_contains "dd_write:/dev/mock1p1:if=:seek=0" "$MOCK_LOG"
  assert_contains "dd_write:/dev/mock1p2:if=:seek=0" "$MOCK_LOG"
}

run_realistic_nvme_tests() {
  local bin_dir="$TMP_DIR/mockbin-nvme"
  setup_realistic_nvme_mocks "$bin_dir"

  export PATH="$bin_dir:/usr/bin:/bin"
  export SKIP_ROOT_CHECK=1
  export DISK_IMAGER_SKIP_RAW_HEADERS=1
  export MOCK_LOG

  local backup_root="$TMP_DIR/backups-nvme"
  mkdir -p "$backup_root"

  "$ROOT_DIR/disk_imager.sh" backup --source /dev/nvme0n1 --backup-root "$backup_root" --name snap-nvme >/dev/null

  local snap="$backup_root/snap-nvme"
  assert_file "$snap/manifest.tsv"
  assert_file "$snap/checksums.txt"
  assert_file "$snap/partition_table.sfdisk"
  assert_file "$snap/inventory.tsv"
  assert_file "$snap/audit_report.txt"
  assert_file "$snap/part-1-vfat.img"
  assert_file "$snap/part-2-unknown.img.gz"
  assert_file "$snap/part-3-ntfs.img"
  assert_file "$snap/part-4-ntfs.img"

  assert_contains $'1\tvfat\tpartclone.fat\tpart-1-vfat.img' "$snap/manifest.tsv"
  assert_contains $'2\tunknown\tdd+gzip\tpart-2-unknown.img.gz' "$snap/manifest.tsv"
  assert_contains $'3\tntfs\tpartclone.ntfs\tpart-3-ntfs.img' "$snap/manifest.tsv"
  assert_contains $'4\tntfs\tpartclone.ntfs\tpart-4-ntfs.img' "$snap/manifest.tsv"
  assert_contains "result=ok" "$snap/audit_report.txt"

  "$ROOT_DIR/disk_imager.sh" verify --backup-dir "$snap" --compare-disk /dev/nvme0n1 >/dev/null
}

run_normal_path_tests
run_fallback_path_tests
run_realistic_nvme_tests

echo "All tests passed"
