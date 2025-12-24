Phase 8 Backup/Restore Hardening

Goal
- Ensure backups include all application data needed for recovery.
- Prevent ZIP path traversal during restore.
- Preserve compatibility with earlier phases.

Changes
- Backup now includes config.json when present in the data directory.
- Restore validates archive paths to avoid writing outside target directories.
- Both full restore and merge paths enforce safe extraction.

Updated File
- lib/services/backup_restore_service.dart
