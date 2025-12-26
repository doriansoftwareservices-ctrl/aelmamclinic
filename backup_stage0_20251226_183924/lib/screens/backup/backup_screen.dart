// lib/screens/backup_restore_screen.dart

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';

import 'package:aelmamclinic/services/backup_restore_service.dart';
import 'package:aelmamclinic/models/storage_type.dart';

// تصميم TBIAN
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/constants.dart';

class BackupScreen extends StatelessWidget {
  const BackupScreen({super.key});

  // ───────── Actions ─────────

  Future<void> _performBackup(
      BuildContext context, StorageType storageType) async {
    try {
      final backupFile =
          await BackupRestoreService.backupDatabase(storageType: storageType);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text("✅ تم إنشاء النسخة الاحتياطية:\n${backupFile.path}")),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("❌ فشل النسخ الاحتياطي: $e")),
      );
    }
  }

  Future<void> _performRestore(
      BuildContext context, StorageType storageType) async {
    String? path;

    if (storageType == StorageType.local) {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['zip', 'db'],
      );
      if (result == null || result.files.single.path == null) return;
      path = result.files.single.path!;
    } else {
      path = await _askForDriveFileId(context);
      if (path == null || path.isEmpty) return;
    }

    try {
      await BackupRestoreService.restoreDatabase(
        backupPath: path,
        storageType: storageType,
      );
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("✅ تم الاستيراد بنجاح")),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("❌ فشل الاستيراد: $e")),
      );
    }
  }

  Future<String?> _askForDriveFileId(BuildContext context) async {
    final ctrl = TextEditingController();
    final scheme = Theme.of(context).colorScheme;

    final ok = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text("استيراد من Google Drive"),
          content: NeuField(
            controller: ctrl,
            labelText: "معرّف ملف النسخة الاحتياطية",
            prefix: const Icon(Icons.cloud_outlined),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text("إلغاء")),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text("تأكيد"),
            ),
          ],
          backgroundColor: scheme.surface,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(kRadius)),
        );
      },
    );

    return ok == true ? ctrl.text.trim() : null;
  }

  // ───────── UI building blocks ─────────

  Widget _tile({
    required BuildContext context,
    required IconData icon,
    required String title,
    required String subtitle,
    required String primaryLabel,
    required VoidCallback onPrimary,
  }) {
    final scheme = Theme.of(context).colorScheme;

    return NeuCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: Container(
              decoration: BoxDecoration(
                color: kPrimaryColor.withValues(alpha: .1),
                borderRadius: BorderRadius.circular(14),
              ),
              padding: const EdgeInsets.all(10),
              child: Icon(icon, color: kPrimaryColor, size: 26),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: scheme.onSurface,
              fontSize: 18,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 6),
          Flexible(
            child: Text(
              subtitle,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: scheme.onSurface.withValues(alpha: .65),
                fontSize: 13.2,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            children: [
              NeuButton.primary(
                label: primaryLabel,
                icon: Icons.play_arrow_rounded,
                onPressed: onPrimary,
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ───────── Build ─────────

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final cross = width >= 1200
        ? 4
        : width >= 800
            ? 3
            : 2;
    final aspect = width >= 1200
        ? 1.15
        : width >= 800
            ? 1.05
            : (width < 420 ? 0.90 : 0.86);

    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset(
              'assets/images/logo.png',
              height: 24,
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            ),
            const SizedBox(width: 8),
            const Text('النسخ الاحتياطي والاستيراد'),
          ],
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: kScreenPadding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header card
              NeuCard(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: SizedBox(
                        width: 46,
                        height: 46,
                        child: Image.asset('assets/images/logo.png',
                            fit: BoxFit.contain),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        AppConstants.secBackup,
                        textAlign: TextAlign.right,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // Grid of actions
              Expanded(
                child: Directionality(
                  textDirection: TextDirection.rtl,
                  child: GridView.count(
                    crossAxisCount: cross,
                    mainAxisSpacing: 16,
                    crossAxisSpacing: 16,
                    childAspectRatio: aspect,
                    children: [
                      _tile(
                        context: context,
                        icon: Icons.backup_outlined,
                        title: 'نسخة احتياطية (محلي)',
                        subtitle: 'إنشاء ملف .zip أو .db على جهازك.',
                        primaryLabel: 'إنشاء نسخة',
                        onPrimary: () =>
                            _performBackup(context, StorageType.local),
                      ),
                      _tile(
                        context: context,
                        icon: Icons.cloud_upload_outlined,
                        title: 'نسخة احتياطية (Google Drive)',
                        subtitle: 'رفع النسخة إلى مساحة Drive المرتبطة.',
                        primaryLabel: 'إنشاء نسخة',
                        onPrimary: () =>
                            _performBackup(context, StorageType.googleDrive),
                      ),
                      _tile(
                        context: context,
                        icon: Icons.download_for_offline_outlined,
                        title: 'استيراد (محلي)',
                        subtitle: 'اختيار ملف النسخة (.zip أو .db) من جهازك.',
                        primaryLabel: 'استيراد',
                        onPrimary: () =>
                            _performRestore(context, StorageType.local),
                      ),
                      _tile(
                        context: context,
                        icon: Icons.cloud_download_outlined,
                        title: 'استيراد (Google Drive)',
                        subtitle: 'أدخل معرّف ملف النسخة للاسـتعادة من Drive.',
                        primaryLabel: 'استيراد',
                        onPrimary: () =>
                            _performRestore(context, StorageType.googleDrive),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
