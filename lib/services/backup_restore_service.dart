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
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:archive/archive_io.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;

import 'db_service.dart';
import 'package:aelmamclinic/services/save_file_service.dart';
import 'package:aelmamclinic/core/active_account_store.dart';
import 'package:aelmamclinic/models/storage_type.dart';
import 'package:aelmamclinic/models/attachment.dart';
import 'package:aelmamclinic/utils/report_localizer.dart';

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
    if (folderId == null || folderId.isEmpty) {
      throw StateError('Failed to resolve Google Drive backup folder.');
    }

    final driveFile = drive.File()
      ..name = p.basename(backupZip.path)
      ..parents = [folderId];
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
    final List<Directory> extraDirs = [
      attachmentsDir,
      exportsDir,
      logsDir,
      debugDir,
    ];
    final List<File> extraFiles = [];

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
    // – ملفات إضافية
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
      await mergeTable('item_types', ['name']);
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

  /*──────────── Export (HTML) ────────────*/
  static Future<File> exportClinicHtml() async {
    final i18n = ReportLocalizer();
    final Database db = await DBService.instance.database;
    final fileName = _timestamped('clinic_export', 'html');
    final accountId = await ActiveAccountStore.readAccountId();
    final clinicProfile = (accountId == null || accountId.isEmpty)
        ? null
        : await DBService.instance.getClinicProfile(accountId);

    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;",
    );

    String esc(Object? v) {
      final s = v?.toString() ?? '';
      return s
          .replaceAll('&', '&amp;')
          .replaceAll('<', '&lt;')
          .replaceAll('>', '&gt;')
          .replaceAll('"', '&quot;')
          .replaceAll("'", '&#39;');
    }

    String quote(String name) => '"${name.replaceAll('"', '""')}"';

    final buffer = StringBuffer();
    buffer.writeln('<!doctype html>');
    buffer.writeln('<html lang="${i18n.htmlLang}" dir="${i18n.htmlDir}">');
    buffer.writeln('<head>');
    buffer.writeln('<meta charset="utf-8" />');
    buffer.writeln('<meta name="viewport" content="width=device-width, initial-scale=1" />');
    buffer.writeln("<title>${esc(i18n.tr('تصدير بيانات العيادة'))}</title>");
    buffer.writeln('<style>');
    buffer.writeln('body{font-family:Arial,Helvetica,sans-serif;background:#f5f7fb;color:#1b2430;margin:0;padding:24px;}');
    buffer.writeln('.wrap{max-width:1200px;margin:0 auto;}');
    buffer.writeln('h1{margin:0 0 8px 0;font-size:26px;}');
    buffer.writeln('.meta{color:#516173;font-size:13px;margin-bottom:20px;}');
    buffer.writeln('.card{background:#fff;border-radius:14px;box-shadow:0 8px 20px rgba(8,20,40,.08);padding:16px;margin:16px 0;}');
    buffer.writeln('.card h2{margin:0 0 8px 0;font-size:18px;}');
    buffer.writeln('.card .count{color:#6b7a8c;font-size:13px;margin-bottom:10px;}');
    buffer.writeln('table{width:100%;border-collapse:collapse;font-size:12.5px;}');
    buffer.writeln('th,td{border:1px solid #e2e8f0;padding:6px 8px;vertical-align:top;}');
    buffer.writeln('th{background:#f0f4f8;font-weight:700;}');
    buffer.writeln('.actions{display:flex;gap:8px;flex-wrap:wrap;margin-bottom:10px;}');
    buffer.writeln('.btn{background:#0b6efd;color:#fff;border:none;border-radius:8px;padding:6px 10px;font-size:12px;cursor:pointer;}');
    buffer.writeln('.btn.secondary{background:#5a6b7d;}');
    buffer.writeln('</style>');
    buffer.writeln('</head>');
    buffer.writeln('<body>');
    buffer.writeln('<div class="wrap">');
    buffer.writeln("<h1>${esc(i18n.tr('تصدير شامل لبيانات العيادة'))}</h1>");
    buffer.writeln(
      "<div class=\"meta\">${esc(i18n.tr('تم إنشاء الملف محليًا في'))} ${esc(i18n.formatDateTime(DateTime.now(), pattern: 'yyyy-MM-dd HH:mm:ss'))}.</div>",
    );
    if (clinicProfile != null) {
      buffer.writeln('<div class="card">');
      buffer.writeln("<h2>${esc(i18n.tr('معلومات العيادة'))}</h2>");
      buffer.writeln("<div class=\"count\">${esc(i18n.tr('بيانات تعريفية'))}</div>");
      buffer.writeln('<div style="overflow:auto;">');
      buffer.writeln('<table>');
      buffer.writeln('<tbody>');
      buffer.writeln(
          "<tr><th>${esc(i18n.isRtl ? 'الاسم (عربي)' : 'Arabic name')}</th><td>${esc(clinicProfile.nameAr)}</td></tr>");
      buffer.writeln(
          "<tr><th>${esc(i18n.isRtl ? 'الاسم (إنجليزي)' : 'English name')}</th><td>${esc(clinicProfile.nameEn)}</td></tr>");
      buffer.writeln(
          "<tr><th>${esc(i18n.isRtl ? 'المدينة (عربي)' : 'Arabic city')}</th><td>${esc(clinicProfile.cityAr)}</td></tr>");
      buffer.writeln(
          "<tr><th>${esc(i18n.isRtl ? 'المدينة (إنجليزي)' : 'English city')}</th><td>${esc(clinicProfile.cityEn)}</td></tr>");
      buffer.writeln(
          "<tr><th>${esc(i18n.isRtl ? 'الشارع/العنوان (عربي)' : 'Arabic street/address')}</th><td>${esc(clinicProfile.streetAr)}</td></tr>");
      buffer.writeln(
          "<tr><th>${esc(i18n.isRtl ? 'الشارع/العنوان (إنجليزي)' : 'English street/address')}</th><td>${esc(clinicProfile.streetEn)}</td></tr>");
      buffer.writeln(
          "<tr><th>${esc(i18n.isRtl ? 'أقرب معلم (عربي)' : 'Arabic landmark')}</th><td>${esc(clinicProfile.nearAr)}</td></tr>");
      buffer.writeln(
          "<tr><th>${esc(i18n.isRtl ? 'أقرب معلم (إنجليزي)' : 'English landmark')}</th><td>${esc(clinicProfile.nearEn)}</td></tr>");
      buffer.writeln(
          "<tr><th>${esc(i18n.isRtl ? 'هاتف' : 'Phone')}</th><td>${esc(clinicProfile.phone)}</td></tr>");
      buffer.writeln(
          "<tr><th>${esc(i18n.isRtl ? 'هاتف إضافي' : 'Additional phone')}</th><td>${esc(clinicProfile.phone2)}</td></tr>");
      buffer.writeln('</tbody></table></div></div>');
    }
    buffer.writeln('<div class="card">');
    buffer.writeln("<h2>${esc(i18n.tr('تصدير كامل'))}</h2>");
    buffer.writeln("<div class=\"count\">${esc(i18n.tr('تصدير كل الجداول دفعة واحدة'))}</div>");
    buffer.writeln('<div class="actions">');
    buffer.writeln(
        "<button class=\"btn\" onclick=\"exportAllXls()\">${esc(i18n.tr('تصدير كل البيانات Excel'))}</button>");
    buffer.writeln(
        "<button class=\"btn secondary\" onclick=\"exportAllCsv()\">${esc(i18n.tr('تصدير كل البيانات CSV'))}</button>");
    buffer.writeln('</div>');
    buffer.writeln('</div>');

    int totalRows = 0;
    for (final t in tables) {
      final table = t['name']?.toString() ?? '';
      if (table.isEmpty) continue;
      final cols = await db.rawQuery('PRAGMA table_info(${quote(table)});');
      final hiddenCols = <String>{
        'account_id',
        'device_id',
        'useruid',
        'user_uid',
        'uuid',
      };
      bool shouldHideColumn(String name) {
        final raw = name.trim();
        if (raw.isEmpty) return true;
        final key = raw.toLowerCase();
        if (hiddenCols.contains(key)) return true;

        // إخفاء أي عمود يدل على معرّف (id/ld) سواء كان CamelCase أو snake_case.
        if (key == 'id') return true;
        if (key.contains('_id') || key.contains('id_')) return true;
        if (raw.contains('Id') ||
            raw.contains('ID') ||
            raw.contains('Ld') ||
            raw.contains('LD')) {
          return true;
        }
        if (key.endsWith('id') || key.endsWith('ld')) return true;
        return false;
      }
      final colNames = cols
          .map((c) => c['name']?.toString() ?? '')
          .where((c) {
            return !shouldHideColumn(c);
          })
          .toList();
      final rows = await db.rawQuery('SELECT * FROM ${quote(table)};');
      totalRows += rows.length;

      final tableId = 'tbl_${table.replaceAll(RegExp(r"[^a-zA-Z0-9_]"), "_")}';
      buffer.writeln('<div class="card">');
      buffer.writeln('<h2>${esc(table)}</h2>');
      buffer.writeln("<div class=\"count\">${esc(i18n.tr('عدد السجلات'))}: ${esc(i18n.formatNumber(rows.length, decimalDigits: 0))}</div>");
      buffer.writeln('<div class="actions">');
      buffer.writeln("<button class=\"btn\" onclick=\"exportTableXls('$tableId', '$table')\">${esc(i18n.tr('تصدير Excel'))}</button>");
      buffer.writeln("<button class=\"btn secondary\" onclick=\"exportTableCsv('$tableId', '$table')\">${esc(i18n.tr('تصدير CSV'))}</button>");
      buffer.writeln('</div>');
      buffer.writeln('<div style="overflow:auto;">');
      buffer.writeln('<table id="$tableId">');
      buffer.writeln('<thead><tr>');
      for (final c in colNames) {
        buffer.writeln('<th>${esc(c)}</th>');
      }
      buffer.writeln('</tr></thead><tbody>');
      for (final r in rows) {
        buffer.writeln('<tr>');
        for (final c in colNames) {
          final v = r[c];
          buffer.writeln('<td>${esc(v)}</td>');
        }
        buffer.writeln('</tr>');
      }
      if (rows.isEmpty) {
        buffer.writeln("<tr><td colspan=\"${colNames.length}\">${esc(i18n.tr('لا توجد بيانات'))}</td></tr>");
      }
      buffer.writeln('</tbody></table></div></div>');
    }

    buffer.writeln(
      "<div class=\"meta\">${esc(i18n.tr('إجمالي الجداول'))}: ${esc(i18n.formatNumber(tables.length, decimalDigits: 0))} • ${esc(i18n.tr('إجمالي السجلات'))}: ${esc(i18n.formatNumber(totalRows, decimalDigits: 0))}</div>",
    );
    buffer.writeln('</div>');

    buffer.writeln('<script>');
    buffer.writeln('function exportTableXls(tableId, name){');
    buffer.writeln('const table=document.getElementById(tableId);');
    buffer.writeln('if(!table) return;');
    buffer.writeln('const html="\\ufeff"+table.outerHTML;');
    buffer.writeln('const blob=new Blob([html],{type:"application/vnd.ms-excel"});');
    buffer.writeln('const url=URL.createObjectURL(blob);');
    buffer.writeln('const a=document.createElement("a");');
    buffer.writeln('a.href=url; a.download=name+".xls"; a.click();');
    buffer.writeln('URL.revokeObjectURL(url);');
    buffer.writeln('}');
    buffer.writeln('function exportTableCsv(tableId, name){');
    buffer.writeln('const table=document.getElementById(tableId); if(!table) return;');
    buffer.writeln('let csv="";');
    buffer.writeln('for(const row of table.rows){');
    buffer.writeln("const cells=[...row.cells].map(c=>'\"'+c.innerText.replace(/\"/g,'\"\"')+'\"');");
    buffer.writeln('csv+=cells.join(",")+"\\n";');
    buffer.writeln('}');
    buffer.writeln('const blob=new Blob(["\\ufeff"+csv],{type:"text/csv;charset=utf-8;"});');
    buffer.writeln('const url=URL.createObjectURL(blob);');
    buffer.writeln('const a=document.createElement("a"); a.href=url; a.download=name+".csv"; a.click();');
    buffer.writeln('URL.revokeObjectURL(url);');
    buffer.writeln('}');
    buffer.writeln('function exportAllXls(){');
    buffer.writeln('const html="\\ufeff"+document.querySelector(".wrap").innerHTML;');
    buffer.writeln('const blob=new Blob([html],{type:"application/vnd.ms-excel"});');
    buffer.writeln('const url=URL.createObjectURL(blob);');
    buffer.writeln('const a=document.createElement("a"); a.href=url; a.download="clinic_export_all.xls"; a.click();');
    buffer.writeln('URL.revokeObjectURL(url);');
    buffer.writeln('}');
    buffer.writeln('function exportAllCsv(){');
    buffer.writeln('let csv="";');
    buffer.writeln('const tables=[...document.querySelectorAll(".card table")];');
    buffer.writeln('for(const table of tables){');
    buffer.writeln('const title=table.closest(".card")?.querySelector("h2")?.innerText || "table";');
    buffer.writeln("csv+='\\n# '+title+'\\n';");
    buffer.writeln('for(const row of table.rows){');
    buffer.writeln("const cells=[...row.cells].map(c=>'\"'+c.innerText.replace(/\"/g,'\"\"')+'\"');");
    buffer.writeln('csv+=cells.join(",")+"\\n";');
    buffer.writeln('}');
    buffer.writeln('}');
    buffer.writeln('const blob=new Blob([\"\\ufeff\"+csv],{type:\"text/csv;charset=utf-8;\"});');
    buffer.writeln('const url=URL.createObjectURL(blob);');
    buffer.writeln('const a=document.createElement(\"a\"); a.href=url; a.download=\"clinic_export_all.csv\"; a.click();');
    buffer.writeln('URL.revokeObjectURL(url);');
    buffer.writeln('}');
    buffer.writeln('</script>');

    buffer.writeln('</body></html>');

    final bytes = Uint8List.fromList(utf8.encode(buffer.toString()));
    final savedPath = await saveFileBytesWithPath(bytes, fileName);
    if (savedPath.isEmpty) {
      throw StateError(i18n.tr('تعذّر حفظ الملف في مجلد Downloads'));
    }
    return File(savedPath);
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
      final downloads = await getDownloadsDirectory();
      if (downloads != null) {
        return Directory(p.join(downloads.path, 'ClinicBackups'));
      }
      final userProfile = Platform.environment['USERPROFILE'];
      if (userProfile != null && userProfile.trim().isNotEmpty) {
        final fallback = Directory(p.join(userProfile, 'Downloads'));
        if (await fallback.exists()) {
          return Directory(p.join(fallback.path, 'ClinicBackups'));
        }
      }
      final docs = await getApplicationDocumentsDirectory();
      return Directory(p.join(docs.path, 'ClinicBackups'));
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
