// lib/screens/backup_restore_screen.dart
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui show TextDirection;

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/tbian_ui.dart';
import 'package:aelmamclinic/models/storage_type.dart';
import 'package:aelmamclinic/services/backup_restore_service.dart';

class BackupRestoreScreen extends StatefulWidget {
  const BackupRestoreScreen({super.key});

  @override
  State<BackupRestoreScreen> createState() => _BackupRestoreScreenState();
}

class _BackupRestoreScreenState extends State<BackupRestoreScreen> {
  bool _busy = false;

  String _lastBackupSize = '';
  DateTime? _lastBackupDate;
  String? _lastBackupPath;

  final TextEditingController _driveIdController = TextEditingController();

  @override
  void dispose() {
    _driveIdController.dispose();
    super.dispose();
  }

  /*������������������ ????? ????????? ������������������*/
  Future<void> _backup({required StorageType storageType}) async {
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      final file = await BackupRestoreService.backupDatabase(
        storageType: storageType,
      );
      if (!mounted) return;

      File backupFile = file;
      if (storageType == StorageType.local && Platform.isAndroid) {
        try {
          final aelmamDir =
              Directory('/storage/emulated/0/Download/AelmamClinic');
          if (!await aelmamDir.exists()) {
            await aelmamDir.create(recursive: true);
          }
          final destPath = p.join(aelmamDir.path, p.basename(file.path));
          backupFile = await file.copy(destPath);
        } catch (_) {
          backupFile = file;
        }
      }

      final info = await backupFile.stat();
      if (!mounted) return;
      setState(() {
        _lastBackupDate = info.modified;
        _lastBackupSize = _formatFileSize(info.size);
        _lastBackupPath = backupFile.path;
      });

      if (!mounted) return;
      _showDetailedDialog(
        '?? ????? ?????? ?????????? ?????',
        '''
??????: ${backupFile.path}
?????: $_lastBackupSize
???????: ${DateFormat('yyyy/MM/dd HH:mm').format(_lastBackupDate!)}
?????????:
 ????? ????????
 ???? ????????
''',
      );
    } catch (e) {
      _showSnack('??? ?? ????? ?????????: ${e.toString()}', error: true);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  /*������������������ ????????? ������������������*/
  Future<void> _restore({required StorageType storageType}) async {
    String source;
    if (storageType == StorageType.local) {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['zip', 'db'],
        dialogTitle: '???? ??? ?????? ??????????',
      );
      if (!mounted) return;
      if (result == null || result.files.single.path == null) return;
      source = result.files.single.path!;
    } else {
      source = await _promptForDriveId();
      if (!mounted || source.isEmpty) return;
    }

    final merge = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('???? ??? ?????????'),
        content: const Text(
          '??? ???????? ??????? (????? ??? ???????) ?? ??????? ?????',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('??????? ????'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('??? ????????'),
          ),
        ],
      ),
    );
    if (!mounted || merge == null) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(merge ? '????? ??? ????????' : '????? ????????? ??????'),
        content: Text(
          merge
              ? '???? ????? ??????? ??????? ??? ??? ???????. ?????'
              : '???? ??? ???? ???????? ???????? ?????? ?????. ?????',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('?????'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red.shade700,
            ),
            child: const Text('?????'),
          ),
        ],
      ),
    );
    if (!mounted || confirm != true) return;

    setState(() => _busy = true);
    try {
      await BackupRestoreService.restoreDatabase(
        backupPath: source,
        storageType: storageType,
        merge: merge,
      );
      if (!mounted) return;
      _showSnack('??? ????????? ?????. ????? ????? ????? ???????.');
    } catch (e) {
      _showSnack('??? ?? ?????????: ${e.toString()}', error: true);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  /*������������������ ????? ?????? ������������������*/
  Future<String> _promptForDriveId() async {
    if (!mounted) return '';
    _driveIdController.clear();
    final result = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('??????? ?? Google Drive'),
        content: TextField(
          controller: _driveIdController,
          decoration: const InputDecoration(
            labelText: '????? ????? (33 ?????)',
            hintText: '???? ????? ?????? ??????????',
          ),
          maxLength: 33,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, ''),
            child: const Text('?????'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, _driveIdController.text),
            child: const Text('???????'),
          ),
        ],
      ),
    );
    return result ?? '';
  }

  void _showSnack(String msg, {bool error = false}) {
    if (!mounted) return;
    final scheme = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: error ? Colors.red.shade700 : scheme.primary,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _showDetailedDialog(String title, String content) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(content)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('??'),
          ),
        ],
      ),
    );
  }

  String _formatFileSize(int bytes) {
    if (bytes <= 0) return '0 B';
    const suffixes = ['B', 'KB', 'MB', 'GB', 'TB'];
    final i = (log(bytes) / log(1024)).floor();
    final size = bytes / pow(1024, i);
    return '${size.toStringAsFixed(2)} ${suffixes[i]}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('??? ???????'),
          actions: [
            if (_lastBackupPath != null)
              IconButton(
                tooltip: '?????? ??? ????',
                icon: const Icon(Icons.share_rounded),
                onPressed: () async {
                  try {
                    await SharePlus.instance.share(
                      ShareParams(
                        files: [XFile(_lastBackupPath!)],
                        text: '???? ELMAM Clinic',
                      ),
                    );
                  } catch (e) {
                    _showSnack('?????? ????????: $e', error: true);
                  }
                },
              ),
          ],
        ),
        body: SafeArea(
          child: Stack(
            children: [
              ListView(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
                children: [
                  const TSectionHeader('??? ???? ????????'),
                  NeuCard(
                    padding: const EdgeInsets.all(14),
                    child: _lastBackupDate == null
                        ? const Text(
                            '?? ????? ???? ???????? ???.',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          )
                        : Wrap(
                            spacing: 16,
                            runSpacing: 16,
                            children: [
                              TInfoCard(
                                icon: Icons.calendar_month_rounded,
                                label: '???????',
                                value: DateFormat('yyyy/MM/dd HH:mm')
                                    .format(_lastBackupDate!),
                              ),
                              TInfoCard(
                                icon: Icons.sd_storage_rounded,
                                label: '?????',
                                value: _lastBackupSize,
                              ),
                              if (_lastBackupPath != null)
                                TInfoCard(
                                  icon: Icons.folder_open_rounded,
                                  label: '??????',
                                  value: _lastBackupPath!,
                                  maxLines: 2,
                                ),
                              Row(
                                children: [
                                  Expanded(
                                    child: TOutlinedButton(
                                      icon: Icons.info_outline_rounded,
                                      label: '??????',
                                      onPressed: () => _showDetailedDialog(
                                        '??? ???? ????????',
                                        '''
???????: ${DateFormat('yyyy/MM/dd HH:mm').format(_lastBackupDate!)}
?????: $_lastBackupSize
??????: ${_lastBackupPath ?? '??? ????'}
''',
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  if (_lastBackupPath != null)
                                    NeuButton.flat(
                                      icon: Icons.share_rounded,
                                      label: '??????',
                                      onPressed: () async {
                                        try {
                                          await SharePlus.instance.share(
                                            ShareParams(
                                              files: [XFile(_lastBackupPath!)],
                                              text: '???? ELMAM Clinic',
                                            ),
                                          );
                                        } catch (e) {
                                          _showSnack(
                                            '?????? ????????: $e',
                                            error: true,
                                          );
                                        }
                                      },
                                    ),
                                ],
                              ),
                            ],
                          ),
                  ),
                  const SizedBox(height: 18),
                  const TSectionHeader('????? ???? ????????'),
                  Wrap(
                    spacing: 16,
                    runSpacing: 16,
                    children: [
                      NeuButton.primary(
                        icon: Icons.backup_rounded,
                        label: '???? ???????? (????)',
                        onPressed: _busy
                            ? null
                            : () => _backup(storageType: StorageType.local),
                      ),
                      NeuButton.flat(
                        icon: Icons.cloud_upload_rounded,
                        label: '???? ???????? (Google Drive)',
                        onPressed: _busy
                            ? null
                            : () =>
                                _backup(storageType: StorageType.googleDrive),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  const TSectionHeader('??????? ????'),
                  NeuCard(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: TOutlinedButton(
                                icon: Icons.download_rounded,
                                label: '??????? (????)',
                                onPressed: _busy
                                    ? null
                                    : () => _restore(
                                          storageType: StorageType.local,
                                        ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            NeuButton.flat(
                              icon: Icons.cloud_download_rounded,
                              label: '??????? (Google Drive)',
                              onPressed: _busy
                                  ? null
                                  : () => _restore(
                                        storageType: StorageType.googleDrive,
                                      ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text(
                          '??????: ?? ??? "??????? ????" ???? ??? ???????? ??????? ?????????? ???????.',
                          style: TextStyle(
                            color: scheme.onSurface.withValues(alpha: .75),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (_busy)
                Positioned.fill(
                  child: Container(
                    color: scheme.scrim.withValues(alpha: .06),
                    child: const Center(child: CircularProgressIndicator()),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
