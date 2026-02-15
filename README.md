# Disk Imager

`disk_imager.sh` creates disk backups with partition-table metadata and per-partition images, then restores from those backups.

Default behavior:
- Partition table: `sfdisk`
- Partition images: `partclone`

Fallback behavior (automatic when tools are missing):
- Partition table: `dd + gzip` raw headers
- Partition images: `dd + gzip`

## Files
- `disk_imager.sh`: main script (CLI + TUI)
- `disk_imager.conf`: defaults (`SOURCE_DISK`, `BACKUP_ROOT`, `NAME_PREFIX`)
- `tests/run_tests.sh`: mock tests for normal and fallback paths

## Basic Usage

Run preflight first:

```bash
sudo /share/saveas/disk_imager.sh preflight --source auto --backup-root /root/samba
```

Create backup:

```bash
sudo /share/saveas/disk_imager.sh backup --source auto --backup-root /root/samba
```

Short command (auto source + default backup root + debug log):

```bash
sudo /share/saveas/disk_imager.sh qb
```

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

## Command Reference

```bash
disk_imager.sh preflight --source <disk|auto> [--backup-root <dir>] [--backup-dir <dir>] [--target <disk>] [--debug] [--log-file <path>]
disk_imager.sh quick-backup|qb [--source <disk|auto>] [--backup-root <dir>] [--name <backup-name>] [--debug] [--log-file <path>]
disk_imager.sh backup    --source <disk|auto> --backup-root <dir> [--name <backup-name>] [--debug] [--log-file <path>]
disk_imager.sh restore   --target <disk> --backup-dir <dir> [--yes] [--debug] [--log-file <path>]
disk_imager.sh verify    --backup-dir <dir> [--compare-disk <disk>] [--debug] [--log-file <path>]
disk_imager.sh tui
```

## Safety

- `restore` is destructive and overwrites target disk structures and partition content.
- Always run `preflight` before `backup` and `restore`.
- Keep multiple backup snapshots before wiping a Windows disk.
