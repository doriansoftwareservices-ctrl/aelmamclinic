// lib/core/storage_service.dart
//
// StorageService: خدمة موحّدة للتعامل مع تخزين Supabase (رفع/توقيع/روابط عامة)
// مع أدوات إضافية مخصّصة لمرفقات الدردشة.
//
// الميزات:
// - رفع صور الدردشة إلى bucket: AppConstants.chatBucketName بمسار هرمي:
//   الافتراضي (الموصى به):  attachments/<conversationId>/<messageId>/<fileName>
//   القديم (مدعوم للتوافق): accountId/<conversationId>/<messageId>/<fileName>
// - إنشاء اسم ملف آمن + تخمين نوع الميديا MIME.
// - استخراج أبعاد الصورة (width/height) إن أمكن.
// - إنشاء رابط عام (Public) أو رابط موقَّع (Signed) مع تخزين مؤقت (Cache).
// - فك ترميز عناوين "storage://bucket/path" إلى http(s).
// - حذف ملف مفرد أو كل الملفات تحت بادئة prefix.
//
// المتطلبات في pubspec.yaml:
//   supabase_flutter: ^2.5.0
//
// الملاحظات:
// - دالة Edge: sign-attachment تتوقع مسارًا بعدة مقاطع (>=4). النمط الافتراضي لدينا
//   "attachments/<conv>/<msg>/<file>" متوافق تمامًا معها.
// - لا يوفّر عميل Flutter تقدمًا للرفع؛ الرفع يتم دفعة واحدة.
// - إن لم تتوفر الـ Edge Function فهناك fallback إلى createSignedUrl.

import 'dart:async';
import 'dart:io' show File;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:supabase_flutter/supabase_flutter.dart';
import 'constants.dart';

/// تمثيل لمسار تخزين منسوب إلى bucket معيّن.
/// يقبل صيغة: storage://bucket/path/to/file.ext
class StoragePath {
  final String bucket;
  final String path;

  StoragePath({required this.bucket, required this.path});

  static StoragePath? tryParse(String url) {
    if (!url.startsWith('storage://')) return null;
    final rest = url.substring('storage://'.length);
    final slash = rest.indexOf('/');
    if (slash <= 0) return null;
    final bucket = rest.substring(0, slash);
    final path = rest.substring(slash + 1);
    if (bucket.isEmpty || path.isEmpty) return null;
    return StoragePath(bucket: bucket, path: path);
  }

  @override
  String toString() => 'storage://$bucket/$path';
}

class _SignedCacheEntry {
  final String url;
  final DateTime expiresAt;

  _SignedCacheEntry({required this.url, required this.expiresAt});
}

/// نتيجة الرفع المفصلة
class UploadResult {
  final String bucket;
  final String path;
  final String mimeType;
  final int sizeBytes;
  final int? width;
  final int? height;

  /// روابط مساعدة (قد تكون فارغة إن تعذّر توليدها)
  final String publicUrl;
  final String? signedUrl;

  const UploadResult({
    required this.bucket,
    required this.path,
    required this.mimeType,
    required this.sizeBytes,
    this.width,
    this.height,
    required this.publicUrl,
    this.signedUrl,
  });

  Map<String, dynamic> toMap() => {
        'bucket': bucket,
        'path': path,
        'mime_type': mimeType,
        'size_bytes': sizeBytes,
        if (width != null) 'width': width,
        if (height != null) 'height': height,
        'public_url': publicUrl,
        if (signedUrl != null) 'signed_url': signedUrl,
      };
}

class StorageService {
  StorageService._();
  static final StorageService instance = StorageService._();

  final SupabaseClient _sb = Supabase.instance.client;

  /// اسم الـ bucket الافتراضي لمرفقات الدردشة (مركزي)
  static const String chatBucket = AppConstants.chatBucketName;

  // ─────────────────────── Helpers: أسماء الملفات + MIME ───────────────────────

  /// اسم ملف آمن للاستخدام في مسارات التخزين
  String safeFileName(String name) {
    final s = name.trim().replaceAll(RegExp(r'[^a-zA-Z0-9_\.-]'), '_');
    return s.isEmpty ? 'img_${DateTime.now().millisecondsSinceEpoch}.jpg' : s;
  }

  /// تخمين نوع الميديا حسب الامتداد (افتراضي image/jpeg)
  String guessMimeByPath(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.webp')) return 'image/webp';
    return 'image/jpeg';
  }

  // ───────────────────────────── Public/Signed URLs ─────────────────────────────

  /// رابط عام مباشر (إن كان الـ bucket عامًّا)
  String publicUrl(String bucket, String path) {
    return _sb.storage.from(bucket).getPublicUrl(path);
  }

  /// محاولة إنشاء رابط موقَّع عبر Edge Function (إن وُجدت) ثم fallback إلى
  /// createSignedUrl من Supabase Storage.
  Future<String?> signUrl(
    String bucket,
    String path, {
    Duration expiresIn = const Duration(minutes: 15),
  }) async {
    // 1) جرّب الـ Edge Function (sign-attachment)
    try {
      final res = await _sb.functions.invoke(
        'sign-attachment',
        body: {
          'bucket': bucket,
          'path': path,
          'expiresIn': expiresIn.inSeconds,
        },
      );
      final data = res.data;
      if (data is Map && data['signedUrl'] is String) {
        return data['signedUrl'] as String;
      }
      if (data is Map && data['url'] is String) {
        return data['url'] as String;
      }
    } catch (_) {
      // تجاهل واستمر للفالباك
    }

    // 2) fallback: createSignedUrl من Storage (تعيد String في ^2.x)
    try {
      final signed = await _sb.storage
          .from(bucket)
          .createSignedUrl(path, expiresIn.inSeconds);
      return signed;
    } catch (_) {
      return null;
    }
  }

  // ───────────────────────────── Signed URL Cache ─────────────────────────────

  final Map<String, _SignedCacheEntry> _signedCache = {};

  String _signedKey(String bucket, String path) => '$bucket::$path';

  /// يعيد رابطًا موقَّعًا Cached إن كان صالحًا، وإلا يولّده ويخزّنه.
  Future<String?> signedUrlCached(
    String bucket,
    String path, {
    Duration expiresIn = const Duration(minutes: 15),
    // نخفّض الصلاحية الفعلية قليلًا داخل الكاش لتجنّب الانقضاء الفوري
    Duration safety = const Duration(seconds: 20),
  }) async {
    final key = _signedKey(bucket, path);
    final now = DateTime.now();
    final hit = _signedCache[key];
    if (hit != null && now.isBefore(hit.expiresAt)) {
      return hit.url;
    }
    final signed = await signUrl(bucket, path, expiresIn: expiresIn);
    if (signed == null) return null;
    final ttl = expiresIn - safety;
    _signedCache[key] = _SignedCacheEntry(
      url: signed,
      expiresAt: now.add(ttl.isNegative ? const Duration(seconds: 1) : ttl),
    );
    return signed;
  }

  // ─────────────────────── storage://bucket/path Resolver ───────────────────────

  /// يحوِّل storage://bucket/path إلى http(s) URL (موقّع أو عام)
  Future<String> resolveUrl(
    String maybeStorageUrl, {
    bool preferSigned = false,
    Duration signedTtl = const Duration(minutes: 15),
  }) async {
    final sp = StoragePath.tryParse(maybeStorageUrl);
    if (sp == null) return maybeStorageUrl; // أصلًا http(s) أو غير معروف
    if (preferSigned) {
      final signed =
          await signedUrlCached(sp.bucket, sp.path, expiresIn: signedTtl);
      if (signed != null) return signed;
    }
    return publicUrl(sp.bucket, sp.path);
  }

  // ───────────────────────────── Image Introspection ────────────────────────────

  /// يحاول استخراج أبعاد الصورة من الملف. قد يعود null إن فشل التحليل.
  Future<({int width, int height})?> tryImageSizeFromFile(File file) async {
    try {
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return null;
      final img = await _decodeImage(bytes);
      return (width: img.width, height: img.height);
    } catch (_) {
      return null;
    }
  }

  Future<ui.Image> _decodeImage(Uint8List bytes) {
    final c = Completer<ui.Image>();
    ui.decodeImageFromList(bytes, (ui.Image img) => c.complete(img));
    return c.future;
  }

  // ─────────────────────────────── Upload Utilities ─────────────────────────────

  /// يبني مسار المرفق داخل bucket لمحتوى الدردشة.
  /// الافتراضي (الموصى به):  attachments/<conversationId>/<messageId>/<fileName>
  /// القديم (للتوافق فقط):   accountId/<conversationId>/<messageId>/<fileName>
  String buildChatAttachmentPath({
    required String accountId,
    required String conversationId,
    required String messageId,
    required String fileName,
    bool useAttachmentsPrefix = true,
  }) {
    final fname = safeFileName(fileName);
    if (useAttachmentsPrefix) {
      // النمط المتوافق مع Edge Function و SQL الحالية
      return '${AppConstants.attachmentsSubdir}/$conversationId/$messageId/$fname';
    }
    // نمط قديم مدعوم للتوافق (إن احتجته)
    final acc = accountId.trim().isEmpty ? 'account' : accountId.trim();
    return '$acc/$conversationId/$messageId/$fname';
  }

  /// يرفع صورة دردشة إلى bucket الافتراضي، ويعيد معلوماتها.
  /// لا ينشئ أي سجلات DB — فقط يرفع الملف ويعطيك المسار/الروابط.
  Future<UploadResult> uploadChatImage({
    required File file,
    required String accountId,
    required String conversationId,
    required String messageId,
    String? fileNameOverride,
    bool upsert = false,
    bool useAttachmentsPrefix = true,
    Duration signedTtl = const Duration(minutes: 15),
  }) async {
    // 1) حدد الاسم والنوع
    final origName = file.uri.pathSegments.isNotEmpty
        ? file.uri.pathSegments.last
        : 'image.jpg';
    var fname = safeFileName(fileNameOverride ?? origName);
    if (!fname.contains('.')) {
      fname = '$fname.jpg';
    }
    final mime = guessMimeByPath(fname);

    // 2) المسار
    final path = buildChatAttachmentPath(
      accountId: accountId,
      conversationId: conversationId,
      messageId: messageId,
      fileName: fname,
      useAttachmentsPrefix: useAttachmentsPrefix,
    );

    // 3) الرفع
    await _sb.storage.from(chatBucket).upload(
          path,
          file,
          fileOptions: FileOptions(contentType: mime, upsert: upsert),
        );

    // 4) إحصاءات
    final stat = await file.stat();
    final sizeB = stat.size;
    final dim = await tryImageSizeFromFile(file);

    // 5) الروابط
    final pub = publicUrl(chatBucket, path);
    final signed =
        await signedUrlCached(chatBucket, path, expiresIn: signedTtl);

    return UploadResult(
      bucket: chatBucket,
      path: path,
      mimeType: mime,
      sizeBytes: sizeB,
      width: dim?.width,
      height: dim?.height,
      publicUrl: pub,
      signedUrl: signed,
    );
  }

  // ─────────────────────────────── Deletion Helpers ─────────────────────────────

  /// حذف ملف محدد
  Future<void> deleteFile({
    required String bucket,
    required String path,
  }) async {
    await _sb.storage.from(bucket).remove([path]);
    // تنظيف الكاش لو موجود
    _signedCache.remove(_signedKey(bucket, path));
  }

  /// حذف جميع الملفات تحت بادئة (prefix) معيّنة
  /// مثال: حذف كل مرفقات رسالة: prefix = attachments/<conv>/<msg>/
  Future<void> deleteByPrefix({
    required String bucket,
    required String prefix,
  }) async {
    // ملاحظة: Storage.list تُرجع List<FileObject> مع limit/offset.
    const int limit = 100;
    int offset = 0;
    final toRemove = <String>[];

    while (true) {
      final List<FileObject> list = await _sb.storage.from(bucket).list(
            path: prefix,
            searchOptions: SearchOptions(limit: limit, offset: offset),
          );
      if (list.isEmpty) break;

      for (final obj in list) {
        toRemove.add('$prefix${obj.name}');
      }

      if (list.length < limit) break; // آخر صفحة
      offset += limit;
    }

    if (toRemove.isNotEmpty) {
      await _sb.storage.from(bucket).remove(toRemove);
      // نظّف كاش التوقيع للمدخلات المحذوفة
      for (final p in toRemove) {
        _signedCache.remove(_signedKey(bucket, p));
      }
    }
  }
}
