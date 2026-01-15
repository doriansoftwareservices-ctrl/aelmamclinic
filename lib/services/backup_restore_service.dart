// ── lib/services/backup_restore_service.dart ────────────────────────────────
// نسخة موسَّعة – Sep 2025 (متوافقة مع google_sign_in: ^7.2.0)
//
// • يشمل المجلدات: attachments/ , exports/ , logs/ , debug-info/
//   إضافةً إلى shared_prefs (Android) والمرفقات الخارجية.
// • يدعم الدمج أو الاستبدال الكامل أثناء الاستعادة.
// • Google Drive اختياري (ومعطّل على Windows/Linux).
//
// لإضافة مجلدات جديدة يكفى إدراجها فى قائمة extraDirs أدناه.

import 'dart:async';
import 'dart:io';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:archive/archive_io.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;

import 'db_service.dart';
import 'package:aelmamclinic/models/storage_type.dart';
import 'package:aelmamclinic/models/attachment.dart';

/*──────────────── Google auth helper ───────────────*/
class GoogleHttpClient extends http.BaseClient {
  final Map<String, String> _headers;
  final http.Client _client = http.Client();
  GoogleHttpClient(this._headers);
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers.addAll(_headers);
    return _client.send(request);
  }

  @override
  void close() => _client.close();
}

/*──────────────── Google Drive service ─────────────*/
class GoogleDriveService {
  // واجهة google_sign_in المتوافقة مع 7.2.0
  static final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: <String>[drive.DriveApi.driveFileScope],
  );
  static drive.DriveApi? _driveApi;

  static bool get _isDesktopUnsupported =>
      Platform.isWindows || Platform.isLinux;

  static Future<drive.DriveApi> _getApi() async {
    if (_driveApi != null) return _driveApi!;

    if (_isDesktopUnsupported) {
      throw UnsupportedError(
        'Google Drive backup is not supported on ${Platform.operatingSystem}. '
        'Use local storage or run on Android/iOS/macOS.',
      );
    }

    // تسجيل دخول (صامت ثم تفاعلي)
    GoogleSignInAccount? account = await _googleSignIn.signInSilently();
    account ??= await _googleSignIn.signIn();
    if (account == null) {
      throw Exception('User cancelled Google Sign-In.');
    }

    // احصل على رمز الدخول واستخدمه كهيدر Authorization
    final auth = await account.authentication;
    final accessToken = auth.accessToken;
    if (accessToken == null || accessToken.isEmpty) {
      throw Exception('Failed to obtain Google access token.');
    }

    final headers = <String, String>{'Authorization': 'Bearer $accessToken'};
    _driveApi = drive.DriveApi(GoogleHttpClient(headers));
    return _driveApi!;
  }

  static Future<drive.File> uploadBackup(File backupZip) async {
    final api = await _getApi();
    const folderName = 'ClinicBackups';
    String? folderId;

    final found = await api.files.list(
      q: "mimeType='application/vnd.google-apps.folder' and name='$folderName'",
      $fields: 'files(id,name)',
      spaces: 'drive',
    );
    if (found.files != null && found.files!.isNotEmpty) {
      folderId = found.files!.first.id;
    } else {
      final meta = drive.File()
        ..name = folderName
        ..mimeType = 'application/vnd.google-apps.folder';
      folderId = (await api.files.create(meta)).id;
    }

    final driveFile = drive.File()
      ..name = p.basename(backupZip.path)
      ..parents = [folderId!];
    final media = drive.Media(backupZip.openRead(), backupZip.lengthSync());
    return api.files.create(driveFile, uploadMedia: media);
  }

  static Future<File> downloadBackup(String fileId) async {
    final api = await _getApi();
    final res = await api.files.get(
      fileId,
      downloadOptions: drive.DownloadOptions.fullMedia,
    );
    if (res is! drive.Media) throw Exception('Download failed');
    final temp = await getTemporaryDirectory();
    final out = File(p.join(temp.path, 'restore_backup.zip'));
    final sink = out.openWrite();
    await res.stream.pipe(sink);
    await sink.flush();
    await sink.close();
    return out;
  }
}

/*──────────────── Backup / Restore ───────────────*/
class BackupRestoreService {
  BackupRestoreService._();
  static final BackupRestoreService instance = BackupRestoreService._();

  /*──────────── Backup ────────────*/
  static Future<File> backupDatabase({
    StorageType storageType = StorageType.local,
    bool includeSharedPrefs = true,
  }) async {
    // 🔒 ضمان التماسك: checkpoint + مزامنة WAL
    final Database liveDb = await DBService.instance.database;
    await liveDb.rawQuery('PRAGMA wal_checkpoint(FULL)');

    // 1️⃣ لمّ ملفات القاعدة
    final dbPath = await DBService.instance.getDatabasePath();
    final dbDir = Directory(p.dirname(dbPath));
    final baseName = p.basename(dbPath);
    final dbFiles = dbDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.contains(baseName))
        .toList();

    if (dbFiles.isEmpty) throw Exception('No database files found to back-up');

    // 2️⃣ المرفقات الخارجية
    final rows =
        await liveDb.query(Attachment.tableName, columns: ['filePath']);
    final externalFiles = <File>[];
    for (final r in rows) {
      final path = r['filePath'] as String?;
      if (path == null) continue;
      final f = File(path);
      if (await f.exists() && !p.isWithin(dbDir.path, path)) {
        externalFiles.add(f);
      }
    }

    // 3️⃣ مجلدات إضافية
    final attachmentsDir =
        Directory(await DBService.instance.getAttachmentsDir());
    final exportsDir = Directory(p.join(dbDir.path, 'exports'));
    final logsDir = Directory(p.join(dbDir.path, 'logs'));
    final debugDir = Directory(p.join(dbDir.path, 'debug-info'));
    final configFile = File(p.join(dbDir.path, 'config.json'));

    final List<Directory> extraDirs = [
      attachmentsDir,
      exportsDir,
      logsDir,
      debugDir,
    ];
    final List<File> extraFiles = [];
    if (await configFile.exists()) {
      extraFiles.add(configFile);
    }

    if (includeSharedPrefs && !Platform.isWindows) {
      final appDocs = await getApplicationDocumentsDirectory();
      final shared = Directory(p.join(appDocs.parent.path, 'shared_prefs'));
      if (await shared.exists()) extraDirs.add(shared);
    }

    // 4️⃣ ضغط كل شيء
    final targetDir = await targetDirectory();
    await targetDir.create(recursive: true);
    final zipName = _timestamped('backup', 'zip');
    final zipPath = p.join(targetDir.path, zipName);
    final encoder = ZipFileEncoder()..create(zipPath);

    // – ملفات القاعدة
    for (final file in dbFiles) {
      encoder.addFile(file, p.relative(file.path, from: dbDir.path));
    }
    // – الأدلة الإضافية
    for (final dir in extraDirs) {
      if (await dir.exists()) encoder.addDirectory(dir, includeDirName: true);
    }
    // – ملفات إضافية (مثل config.json)
    for (final file in extraFiles) {
      encoder.addFile(file, p.basename(file.path));
    }
    // – المرفقات الخارجية (مجلد افتراضى داخل الـ ZIP)
    for (final file in externalFiles) {
      final rel = p.join('attachments_external', p.basename(file.path));
      encoder.addFile(file, rel);
    }
    encoder.close();

    // 5️⃣ أعد إغلاق القاعدة
    await DBService.instance.flushAndClose();
    final zipFile = File(zipPath);

    // 6️⃣ رفع إلى Google Drive إن لزم
    if (storageType == StorageType.googleDrive) {
      final uploaded = await GoogleDriveService.uploadBackup(zipFile);
      // نعيد مُعرّف Drive بشكل رمزى
      return File('GoogleDrive:${uploaded.id}');
    }
    return zipFile;
  }

  /*──────────── Restore ────────────*/
  static Future<void> restoreDatabase({
    required String backupPath,
    StorageType storageType = StorageType.local,
    bool merge = false,
  }) async {
    String localPath = backupPath;
    if (storageType == StorageType.googleDrive) {
      final downloaded = await GoogleDriveService.downloadBackup(backupPath);
      localPath = downloaded.path;
    }

    final backupFile = File(localPath);
    if (!await backupFile.exists()) throw Exception('Backup file not found');

    // إغلاق القاعدة الحالية
    await DBService.instance.flushAndClose();

    final bytes = await backupFile.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    final dbDir =
        Directory(p.dirname(await DBService.instance.getDatabasePath()));
    final attachDir = Directory(await DBService.instance.getAttachmentsDir());

    if (!merge) {
      // ▶️ استبدال كامل
      // نحسب مسار shared_prefs الأساسي (Android/iOS)
      late final Directory sharedBaseDir;
      if (Platform.isWindows) {
        sharedBaseDir = dbDir;
      } else {
        final appDocs = await getApplicationDocumentsDirectory();
        sharedBaseDir = appDocs.parent;
      }

      for (final file in archive) {
        if (!file.isFile) continue;
        final name = file.name;

        final mapping = <String, Directory>{
          'attachments/': dbDir,
          'exports/': dbDir,
          'logs/': dbDir,
          'debug-info/': dbDir,
          'attachments_external/': attachDir.parent,
          'shared_prefs/': sharedBaseDir,
        };

        Directory baseDir = dbDir;
        String relative = name;
        mapping.forEach((prefix, dir) {
          if (name.startsWith(prefix)) {
            baseDir = dir;
            relative = name; // احتفظ بالمسار داخل الـ ZIP تحت نفس المجلد
          }
        });
        if (name == 'config.json') {
          baseDir = dbDir;
          relative = name;
        }

        final outPath = _safeExtractPath(baseDir.path, relative);
        if (outPath == null) {
          continue;
        }
        final outFile = File(outPath);
        await outFile.create(recursive: true);
        await outFile.writeAsBytes(file.content as List<int>);
      }
    } else {
      // ▶️ دمج
      final tempDir = await getTemporaryDirectory();
      final tempBackupDir = Directory(p.join(tempDir.path, 'temp_backup'));
      await tempBackupDir.create(recursive: true);

      for (final file in archive) {
        if (!file.isFile) continue;
        final safePath = _safeExtractPath(tempBackupDir.path, file.name);
        if (safePath == null) {
          continue;
        }
        final out = File(safePath);
        await out.create(recursive: true);
        await out.writeAsBytes(file.content as List<int>);
      }

      // دمج الجداول
      final currentDb = await openDatabase(p.join(dbDir.path, 'clinic.db'));
      final backupDb = await openDatabase(
        p.join(tempBackupDir.path, 'clinic.db'),
        readOnly: true,
      );

      Future<void> mergeTable(String table, List<String> uniqueCols) =>
          _mergeTable(currentDb, backupDb, table, uniqueColumns: uniqueCols);

      await mergeTable('patients', ['phoneNumber', 'registerDate']);
      await mergeTable('doctors', ['name', 'specialization']);
      await mergeTable('appointments', ['patientId', 'appointmentTime']);
      await mergeTable('returns', ['patientName', 'date']);
      await mergeTable('medical_services', ['name', 'serviceType']);
      await mergeTable('service_doctor_share', ['serviceId', 'doctorId']);
      await mergeTable('employees', ['identityNumber']);
      await mergeTable('items', ['name', 'type_id']);
      await mergeTable('purchases', ['item_id', 'created_at']);
      await mergeTable('consumptions', ['itemId', 'date']);
      await mergeTable('alert_settings', ['item_id']);
      await mergeTable('drugs', ['name']);
      await mergeTable('prescriptions', ['patientId', 'recordDate']);
      await mergeTable('prescription_items', ['prescriptionId', 'drugId']);
      await mergeTable('complaints', ['createdAt', 'subject']);

      // دمج المجلدات
      await _mergeSubDir(tempBackupDir, dbDir, 'attachments');
      await _mergeSubDir(tempBackupDir, dbDir, 'exports');
      await _mergeSubDir(tempBackupDir, dbDir, 'logs');
      await _mergeSubDir(tempBackupDir, dbDir, 'debug-info');
      await _mergeSubDir(
          tempBackupDir, attachDir.parent, 'attachments_external');

      await backupDb.close();
      await currentDb.close();
    }
  }

  /*──────── helpers ─────────────────*/
  static Future<void> _mergeTable(
    Database currentDb,
    Database backupDb,
    String tableName, {
    required List<String> uniqueColumns,
  }) async {
    final batch = currentDb.batch();
    final backupData = await backupDb.query(tableName);
    for (final record in backupData) {
      final whereClause = uniqueColumns.map((col) => '$col = ?').join(' AND ');
      final exists = await currentDb.query(
        tableName,
        where: whereClause,
        whereArgs: uniqueColumns.map((col) => record[col]).toList(),
        limit: 1,
      );
      if (exists.isEmpty) batch.insert(tableName, record);
    }
    await batch.commit(noResult: true);
  }

  /* دمج أى مجلد فرعى: attachments / exports / logs / debug-info … */
  static Future<void> _mergeSubDir(
    Directory backupRoot,
    Directory targetParent,
    String subDirName,
  ) async {
    final inside = Directory(p.join(backupRoot.path, subDirName));
    if (!await inside.exists()) return;

    await for (final entity in inside.list(recursive: true)) {
      if (entity is! File) continue;
      final relative = p.relative(entity.path, from: inside.path);
      final dest = File(p.join(targetParent.path, subDirName, relative));
      if (!await dest.exists()) {
        await dest.create(recursive: true);
        await entity.copy(dest.path);
      }
    }
  }

  /// المجلد الافتراضى للنسخ الاحتياطية
  static Future<Directory> targetDirectory() async {
    if (Platform.isWindows) {
      final user = Platform.environment['USERNAME'] ?? 'User';
      return Directory('C:\\Users\\$user\\Downloads\\ClinicBackups');
    }
    final downloads = await getDownloadsDirectory() ??
        await getApplicationDocumentsDirectory();
    return Directory(p.join(downloads.path, 'ClinicBackups'));
  }

  static String _timestamped(String prefix, String ext) {
    final now = DateTime.now();
    final ts =
        '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_'
        '${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}';
    return '${prefix}_$ts.$ext';
  }

  /// جدولة نسخ احتياطى يومى
  static void schedulePeriodicBackup() {
    Timer.periodic(const Duration(hours: 24), (_) async {
      try {
        final file = await backupDatabase();
        // يمكنك استبدال الطباعة بإشعار داخل التطبيق
        // ignore: avoid_print
        print('Auto-backup created: ${file.path}');
      } catch (e) {
        // ignore: avoid_print
        print('Auto-backup failed: $e');
      }
    });
  }

  static String? _safeExtractPath(String baseDir, String entryName) {
    final normalized = p.normalize(entryName);
    if (p.isAbsolute(normalized)) return null;
    final outPath = p.normalize(p.join(baseDir, normalized));
    if (p.equals(outPath, baseDir) || p.isWithin(baseDir, outPath)) {
      return outPath;
    }
    return null;
  }
}
