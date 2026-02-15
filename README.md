# Disk Imager

`disk_imager.sh` creates disk backups with partition-table metadata and per-partition images, then restores from those backups.

Optional safe mode:
- Whole-disk image: `--safe-full-image` creates one compressed file (`disk-full.img.gz`) containing the entire disk.

Default behavior:
- Partition table: `sfdisk`
- Partition images: `partclone`

Fallback behavior (automatic when tools are missing):
- Partition table: `dd + gzip` raw headers
- Partition images: `dd + gzip`

Backup safety checks (automatic):
- Fails if source partitions are mounted (unless `ALLOW_MOUNTED_SOURCE=1`)
- Verifies every expected partition has an image
- Re-validates `sha256` checksums at end of backup
- Validates image integrity (`gzip -t` for gzip images, `partclone.chkimg` when available)
- Writes `audit_report.txt` in the backup folder

## Files
- `disk_imager.sh`: main script (CLI + TUI)
- `disk_imager.conf`: defaults (`SOURCE_DISK`, `BACKUP_ROOT`, `NAME_PREFIX`)
- `tests/run_tests.sh`: mock tests for normal, fallback, and realistic NVMe layouts

## Backup Folder Contents

Each backup snapshot directory contains:
- `partition_table.sfdisk` and `partition_table.json` (when `sfdisk` is available)
- `disk-head-2MiB.bin.gz` and `disk-tail-2MiB.bin.gz` (raw table/header fallback data)
- `disk-full.img.gz` (only when `--safe-full-image` is used)
- `manifest.tsv` (partition -> image mapping + method used)
- `inventory.tsv` (captured source partition inventory before imaging)
- `checksums.txt` (sha256 for each image)
- `audit_report.txt` (post-backup audit result; must include `result=ok`)
- `lsblk.json`, `partitions.tsv`, `metadata.txt`
- `part-*.img` or `part-*.img.gz` image files

## Basic Usage

Run preflight first:

```bash
sudo /share/saveas/disk_imager.sh preflight --source auto --backup-root /root/samba
```

Create backup:

```bash
sudo /share/saveas/disk_imager.sh backup --source auto --backup-root /root/samba
```

Create a single-file compressed full-disk backup (safe mode):

```bash
sudo /share/saveas/disk_imager.sh backup --source /dev/nvme0n1 --backup-root /root/samba --safe-full-image
```

Short command (auto source + default backup root + debug log):

```bash
sudo /share/saveas/disk_imager.sh qb
```

This command auto-writes debug logs to:
- `/tmp/disk_imager_quick_YYYYMMDD_HHMMSS.log`

Verify backup:

```bash
sudo /share/saveas/disk_imager.sh verify --backup-dir /root/samba/<backup-folder>
```

Restore backup:

```bash
sudo /share/saveas/disk_imager.sh restore --target /dev/nvme0n1 --backup-dir /root/samba/<backup-folder>
```

Start TUI:

```bash
sudo /share/saveas/disk_imager.sh tui
```

When TUI starts, debug logging is enabled automatically and a log is saved to:
- `/tmp/disk_imager_tui_YYYYMMDD_HHMMSS.log`

## NVMe Device Notes

- Use the disk node (for example `/dev/nvme0n1`), not controller node (`/dev/nvme0`).
- Script auto-corrects common `/dev/nvmeX -> /dev/nvmeXn1` mistakes when possible.
- If `/dev/nvme0n1` is reported as not a block device, your shell likely cannot access host disks (restricted container/chroot/remote environment).

## Remote Debug Logging

If you cannot access the machine directly, run with debug logging and share the log file.

Preflight debug:

```bash
sudo /share/saveas/disk_imager.sh preflight \
  --source auto \
  --backup-root /root/samba \
  --debug \
  --log-file /tmp/disk_imager_remote_debug.log
```

Backup debug:

```bash
sudo /share/saveas/disk_imager.sh backup \
  --source auto \
  --backup-root /root/samba \
  --debug \
  --log-file /tmp/disk_imager_remote_backup.log
```

Share logs:
- `/tmp/disk_imager_remote_debug.log`
- `/tmp/disk_imager_remote_backup.log`

If you can only send terminal output:

```bash
sudo tail -n 200 /tmp/disk_imager_remote_debug.log
sudo tail -n 200 /tmp/disk_imager_remote_backup.log
```

## Post-Backup Validation

Backup is considered successful only after automatic audit passes.

Required signals:
- script exits with code `0`
- `audit_report.txt` exists in backup folder
- `audit_report.txt` contains `result=ok`

Quick manual check:

```bash
grep -F "result=ok" /root/samba/<backup-folder>/audit_report.txt
```

Optional full verification:

```bash
sudo /share/saveas/disk_imager.sh verify --backup-dir /root/samba/<backup-folder>
```

## Tests

Run all mock tests:

```bash
./tests/run_tests.sh
```

Current suites:
- Normal path: `sfdisk + partclone`
- Fallback path: no `sfdisk`/`partclone` -> `dd+gzip`
- Realistic NVMe path:
  - disk `/dev/nvme0n1`
  - partitions `p1 vfat`, `p2 unknown/MSR-like`, `p3 ntfs`, `p4 ntfs`
  - asserts `p2` uses `dd+gzip` while filesystem partitions use `partclone`
- Safe full-disk image path: `--safe-full-image` creates and restores `disk-full.img.gz`

## Command Reference

```bash
disk_imager.sh preflight --source <disk|auto> [--backup-root <dir>] [--backup-dir <dir>] [--target <disk>] [--safe-full-image] [--debug] [--log-file <path>]
disk_imager.sh quick-backup|qb [--source <disk|auto>] [--backup-root <dir>] [--name <backup-name>] [--safe-full-image] [--debug] [--log-file <path>]
disk_imager.sh backup    --source <disk|auto> --backup-root <dir> [--name <backup-name>] [--safe-full-image] [--debug] [--log-file <path>]
disk_imager.sh restore   --target <disk> --backup-dir <dir> [--yes] [--debug] [--log-file <path>]
disk_imager.sh verify    --backup-dir <dir> [--compare-disk <disk>] [--debug] [--log-file <path>]
disk_imager.sh tui
```

## Safety

- `restore` is destructive and overwrites target disk structures and partition content.
- Always run `preflight` before `backup` and `restore`.
- Keep multiple backup snapshots before wiping a Windows disk.
- Default backup behavior refuses mounted source partitions for consistency.
