// lib/services/attachment_cache.dart
//
// تخزين محلي بسيط للمرفقات (صور/ملفات) بنمط "Local-first":
// - ينزّل الملف أول مرة فقط ثم يعرضه من التخزين المحلي لاحقًا.
// - لا يعتمد على أي حزم خارجية (فقط dart:io). يستخدم مجلدًا داخل systemTemp.
// - تنظيف تلقائي (LRU تقريبًا): حسب العمر/الحجم/عدد الملفات.
// - تطبيع المفاتيح: يزيل معلمات الاستعلام الشائعة في الروابط الموقّعة لتقليل التكرار.
// - واجهة سهلة:
//     * await AttachmentCache.instance.fileFor(url)            → يعيد File ويوفّره محليًا
//     * await AttachmentCache.instance.ensureFileFor(url)      → يعيد String? لمسار الملف
//     * await AttachmentCache.instance.ensureFileForSupabase(
//           bucket, path, url: signedOrPublicUrl)              → يعيد String?
//     * AttachmentCache.instance.localPathIfAny(url)
//       AttachmentCache.instance.localPathIfAny(bucket, path)  → مسار محلي إن وُجد
//     * AttachmentCache.instance.localPathSyncIfAny(...)       → نسخة sync
//     * AttachmentCacheImage(url: ...)                         → ويدجت تعرض الصورة من الكاش
//
// ملاحظات:
// * الهدف الرئيسي هو تقليل إعادة التنزيل عند الدخول المتكرر لنفس الدردشة.
// * الملفات تُخزّن تحت: <systemTemp>/elmam_chat_cache/
// * إن تغيّرت محتويات المسار نفسه على الخادم مع نفس الـ URL (نادر)، استخدم evict(url).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class AttachmentCache {
  AttachmentCache._();
  static final AttachmentCache instance = AttachmentCache._();

  /// اسم مجلد الكاش داخل systemTemp
  static const String _kFolderName = 'elmam_chat_cache';

  /// ملف تعريف (ميتا) لكل عنصر: <key>.json
  static const String _kMetaExt = '.json';

  /// حدود تنظيف افتراضية
  static const int _kMaxFiles = 800; // أقصى عدد ملفات بالكاش
  static const int _kMaxTotalBytes = 500 * 1024 * 1024; // 500MB
  static const Duration _kMaxAge =
      Duration(days: 120); // ثابت → يصلح كقيمة افتراضية

  Directory? _root;
  final _inflight = <String, Future<File>>{};
  final _rng = Random();

  /// مسار الجذر المتوقع للكاش (حتى قبل الإنشاء).
  String get _rootPathGuess => '${Directory.systemTemp.path}/$_kFolderName';

  /// تهيئة مجلد الكاش (كسولًا عند أول استخدام).
  Future<Directory> _ensureRoot() async {
    if (_root != null) return _root!;
    final dir = Directory(_rootPathGuess);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _root = dir;
    return dir;
  }

  /* ======================== واجهة URL و (bucket,path) ======================== */

  /// مسار محلي إن كان موجودًا مسبقًا (بدون تنزيل). تعمل لِـ:
  /// - localPathIfAny(url)
  /// - localPathIfAny(bucket, path)
  Future<String?> localPathIfAny(String a, [String? b]) async {
    final root = await _ensureRoot();
    final key = (b == null) ? _keyForUrl(a) : _keyForSupabase(a, b);
    final f = File('${root.path}/$key');
    if (await f.exists()) {
      _touchMeta(key);
      return f.path;
    }
    return null;
  }

  /// نسخة متزامنة للتحقق السريع (بدون Await).
  /// - localPathSyncIfAny(url)
  /// - localPathSyncIfAny(bucket, path)
  String? localPathSyncIfAny(String a, [String? b]) {
    try {
      final key = (b == null) ? _keyForUrl(a) : _keyForSupabase(a, b);
      final f = File('$_rootPathGuess/$key');
      return f.existsSync() ? f.path : null;
    } catch (_) {
      return null;
    }
  }

  /// واجهة عامة: أعطني [File] محليًا لهذا [url] (سينزّله إن لم يكن موجودًا).
  Future<File> fileFor(String url) async {
    final root = await _ensureRoot();
    final key = _keyForUrl(url);
    final file = File('${root.path}/$key');

    // إن كان الملف موجودًا: حدّث اللمس الأخير وأعده
    if (await file.exists()) {
      _touchMeta(key);
      return file;
    }

    // دمج الطلبات المتزامنة لنفس الـ URL
    final existing = _inflight[key];
    if (existing != null) return existing;

    final fut = _downloadAndStore(url, key);
    _inflight[key] = fut;
    try {
      final f = await fut;
      // تنظيف بشكل كسول أحيانًا
      if (_rng.nextInt(7) == 0) {
        unawaited(_maybeCleanup());
      }
      return f;
    } finally {
      _inflight.remove(key);
    }
  }

  /// مرادف مريح يعيد **مسار الملف** بدل File — مفيد لطبقة المزوّد.
  Future<String?> ensureFileFor(String url) async {
    try {
      final f = await fileFor(url);
      return f.path;
    } catch (_) {
      return null;
    }
  }

  /// مفتاح ثابت لموارد سوبابيس (يعتمد bucket+path فقط) لتفادي تكرار التنزيل
  /// عند اختلاف معلمات الاستعلام في الروابط الموقعة.
  String _keyForSupabase(String bucket, String path) =>
      _fnv1a64hex(utf8.encode('supabase://$bucket/$path'));

  /// يضمن وجود ملف محلي لمسار سوبابيس (bucket+path).
  /// إن لم يكن موجودًا سيستخدم [url] (موقّع/عام) للتنزيل.
  /// يعيد مسارًا محليًا أو null عند الفشل.
  Future<String?> ensureFileForSupabase(
    String bucket,
    String path, {
    String? url,
  }) async {
    final root = await _ensureRoot();
    final key = _keyForSupabase(bucket, path);
    final dest = File('${root.path}/$key');

    if (await dest.exists()) {
      _touchMeta(key);
      return dest.path;
    }
    if (url == null || url.isEmpty) return null;

    final tmp = File('${root.path}/$key.downloading');
    try {
      final bytes = await _httpGetBytes(url);
      await tmp.writeAsBytes(bytes, flush: true);
      if (await dest.exists()) {
        try {
          await dest.delete();
        } catch (_) {}
      }
      await tmp.rename(dest.path);

      final mime = _guessMimeFromUrlOrBytes(url, bytes);
      await _writeMeta(
        key,
        _CacheMeta(
          url: 'supabase://$bucket/$path',
          createdAt: DateTime.now().toUtc(),
          lastAccess: DateTime.now().toUtc(),
          contentType: mime,
          size: bytes.length,
        ),
      );
      // تنظيف كسول أحيانًا
      if (_rng.nextInt(7) == 0) {
        unawaited(_maybeCleanup());
      }
      return dest.path;
    } catch (_) {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      return null;
    }
  }

  /// تحضير مسبق (prefetch) لرابط HTTP.
  Future<void> prefetch(String url) async {
    try {
      await fileFor(url);
    } catch (_) {
      // تجاهل أخطاء التحضير
    }
  }

  /// إخلاء عنصر محدد (بالـ URL).
  Future<void> evict(String url) async {
    try {
      final root = await _ensureRoot();
      final key = _keyForUrl(url);
      final f = File('${root.path}/$key');
      final m = File('${root.path}/$key$_kMetaExt');
      if (await f.exists()) await f.delete();
      if (await m.exists()) await m.delete();
    } catch (_) {}
  }

  /// حذف جميع الملفات (حالة طوارئ).
  Future<void> purgeAll() async {
    try {
      final root = await _ensureRoot();
      if (await root.exists()) {
        await for (final e in root.list(recursive: false, followLinks: false)) {
          try {
            await e.delete(recursive: true);
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  /// يحاول تنظيف الكاش إن تجاوز الحدود.
  Future<void> _maybeCleanup({
    int maxFiles = _kMaxFiles,
    int maxBytes = _kMaxTotalBytes,
    Duration maxAge = _kMaxAge,
  }) async {
    final root = await _ensureRoot();
    if (!await root.exists()) return;

    // اجمع الإدخالات
    final entries = <_CacheEntry>[];
    int totalBytes = 0;

    await for (final e in root.list(recursive: false, followLinks: false)) {
      if (e is File) {
        final name =
            e.uri.pathSegments.isNotEmpty ? e.uri.pathSegments.last : '';
        if (name.endsWith(_kMetaExt)) continue; // نستثني ملفات الميتا
        try {
          final stat = await e.stat();
          final meta = await _readMeta(e.path);
          final lastAccess = meta?.lastAccess ?? stat.changed;
          final ce = _CacheEntry(
            file: e,
            size: stat.size,
            lastAccess: lastAccess,
            metaPath: '${root.path}/$name$_kMetaExt',
          );
          entries.add(ce);
          totalBytes += stat.size;
        } catch (_) {}
      }
    }

    // 1) احذف القديم جدًا
    final threshold = DateTime.now().subtract(maxAge);
    for (final ce in entries.where((e) => e.lastAccess.isBefore(threshold))) {
      try {
        await ce.file.delete();
        final m = File(ce.metaPath);
        if (await m.exists()) await m.delete();
        totalBytes -= ce.size;
      } catch (_) {}
    }

    // أعِد تحميل القائمة بعد الحذف الأولي
    final remain = <_CacheEntry>[];
    await for (final e in root.list(recursive: false, followLinks: false)) {
      if (e is File) {
        final name =
            e.uri.pathSegments.isNotEmpty ? e.uri.pathSegments.last : '';
        if (name.endsWith(_kMetaExt)) continue;
        try {
          final stat = await e.stat();
          final meta = await _readMeta(e.path);
          final lastAccess = meta?.lastAccess ?? stat.changed;
          remain.add(
            _CacheEntry(
              file: e,
              size: stat.size,
              lastAccess: lastAccess,
              metaPath: '${root.path}/$name$_kMetaExt',
            ),
          );
        } catch (_) {}
      }
    }

    // 2) إن تجاوزنا الحدود: فرز حسب آخر وصول (أقدم أولًا) ثم احذف حتى ننزل تحت الحدود
    remain.sort((a, b) => a.lastAccess.compareTo(b.lastAccess));

    while (remain.length > maxFiles || totalBytes > maxBytes) {
      if (remain.isEmpty) break;
      final ce = remain.removeAt(0);
      try {
        await ce.file.delete();
        final m = File(ce.metaPath);
        if (await m.exists()) await m.delete();
        totalBytes -= ce.size;
      } catch (_) {}
    }
  }

  /* ======================== تنزيل وتخزين ======================== */

  Future<File> _downloadAndStore(String url, String key) async {
    final root = await _ensureRoot();
    final tmp = File('${root.path}/$key.downloading');
    final dest = File('${root.path}/$key');

    final bytes = await _httpGetBytes(url);
    await tmp.writeAsBytes(bytes, flush: true);

    if (await dest.exists()) {
      try {
        await dest.delete();
      } catch (_) {}
    }
    await tmp.rename(dest.path);

    final mime = _guessMimeFromUrlOrBytes(url, bytes);
    final meta = _CacheMeta(
      url: url,
      createdAt: DateTime.now().toUtc(),
      lastAccess: DateTime.now().toUtc(),
      contentType: mime,
      size: bytes.length,
    );
    await _writeMeta(key, meta);

    return dest;
  }

  Future<Uint8List> _httpGetBytes(String url) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final uri = Uri.parse(url);
      final req = await client.getUrl(uri);
      req.headers.set(HttpHeaders.acceptHeader, '*/*');
      final res = await req.close();

      if (res.statusCode != 200) {
        throw HttpException('HTTP ${res.statusCode}', uri: uri);
      }

      final bytes = await consolidateHttpClientResponseBytes(res);
      return Uint8List.fromList(bytes);
    } finally {
      client.close(force: true);
    }
  }

  /* ======================== مفاتيح + ميتاداتا ======================== */

  // تبسيط المفتاح: تجاهل معلمات الاستعلام الشائعة (token/expires/…)
  // واستعمل scheme+host+path فقط لتقليل ازدواج العناصر الموقعة.
  String _keyForUrl(String url) {
    try {
      final u = Uri.parse(url);
      final base = '${u.scheme}://${u.host}${u.path}'.toLowerCase();
      return _fnv1a64hex(utf8.encode(base));
    } catch (_) {
      return _fnv1a64hex(utf8.encode(url));
    }
  }

  // FNV-1a 64-bit (بلا تبعية خارجية)
  String _fnv1a64hex(List<int> bytes) {
    const int _offset = 0xcbf29ce484222325; // 14695981039346656037
    const int _prime = 0x100000001b3; // 1099511628211
    int hash = _offset;
    for (final b in bytes) {
      hash ^= b & 0xff;
      hash = (hash * _prime) & 0xFFFFFFFFFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }

  Future<void> _writeMeta(String key, _CacheMeta meta) async {
    try {
      final root = await _ensureRoot();
      final f = File('${root.path}/$key$_kMetaExt');
      await f.writeAsString(jsonEncode(meta.toJson()), flush: true);
    } catch (_) {}
  }

  Future<_CacheMeta?> _readMeta(String filePath) async {
    try {
      final file = File(filePath);
      final name =
          file.uri.pathSegments.isNotEmpty ? file.uri.pathSegments.last : '';
      final dir = file.parent;
      final metaFile = File('${dir.path}/$name$_kMetaExt');
      if (!await metaFile.exists()) return null;
      final txt = await metaFile.readAsString();
      final m = jsonDecode(txt) as Map<String, dynamic>;
      return _CacheMeta.fromJson(m);
    } catch (_) {
      return null;
    }
  }

  Future<void> _touchMeta(String key) async {
    try {
      final root = await _ensureRoot();
      final metaFile = File('${root.path}/$key$_kMetaExt');
      _CacheMeta meta;
      if (await metaFile.exists()) {
        try {
          final txt = await metaFile.readAsString();
          meta = _CacheMeta.fromJson(jsonDecode(txt) as Map<String, dynamic>);
        } catch (_) {
          meta = _CacheMeta(url: key, createdAt: DateTime.now().toUtc());
        }
      } else {
        meta = _CacheMeta(url: key, createdAt: DateTime.now().toUtc());
      }
      meta = meta.copyWith(lastAccess: DateTime.now().toUtc());
      await metaFile.writeAsString(jsonEncode(meta.toJson()), flush: true);
    } catch (_) {}
  }

  String _guessMimeFromUrlOrBytes(String url, Uint8List bytes) {
    final lower = url.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (bytes.length >= 12) {
      // PNG
      if (bytes[0] == 0x89 &&
          bytes[1] == 0x50 &&
          bytes[2] == 0x4E &&
          bytes[3] == 0x47) return 'image/png';
      // JPEG
      if (bytes[0] == 0xFF && bytes[1] == 0xD8) return 'image/jpeg';
      // WEBP
      if (bytes[0] == 0x52 &&
          bytes[1] == 0x49 &&
          bytes[2] == 0x46 &&
          bytes[3] == 0x46 &&
          bytes[8] == 0x57 &&
          bytes[9] == 0x45 &&
          bytes[10] == 0x42 &&
          bytes[11] == 0x50) return 'image/webp';
      // GIF
      if (bytes[0] == 0x47 &&
          bytes[1] == 0x49 &&
          bytes[2] == 0x46 &&
          bytes[3] == 0x38) return 'image/gif';
    }
    return 'application/octet-stream';
  }
}

/* ======================== نموذج الميتاداتا ======================== */

class _CacheMeta {
  final String url;
  final DateTime createdAt;
  final DateTime? lastAccess;
  final String? contentType;
  final int? size;

  _CacheMeta({
    required this.url,
    required this.createdAt,
    this.lastAccess,
    this.contentType,
    this.size,
  });

  _CacheMeta copyWith({
    String? url,
    DateTime? createdAt,
    DateTime? lastAccess,
    String? contentType,
    int? size,
  }) {
    return _CacheMeta(
      url: url ?? this.url,
      createdAt: createdAt ?? this.createdAt,
      lastAccess: lastAccess ?? this.lastAccess,
      contentType: contentType ?? this.contentType,
      size: size ?? this.size,
    );
  }

  Map<String, dynamic> toJson() => {
        'url': url,
        'created_at': createdAt.toIso8601String(),
        if (lastAccess != null) 'last_access': lastAccess!.toIso8601String(),
        if (contentType != null) 'content_type': contentType,
        if (size != null) 'size': size,
      };

  static _CacheMeta fromJson(Map<String, dynamic> m) {
    DateTime? _p(String? s) => s == null ? null : DateTime.tryParse(s)?.toUtc();
    return _CacheMeta(
      url: (m['url'] ?? '').toString(),
      createdAt:
          DateTime.tryParse((m['created_at'] ?? '').toString())?.toUtc() ??
              DateTime.now().toUtc(),
      lastAccess: _p((m['last_access'] ?? '').toString()),
      contentType: (() {
        final v = (m['content_type'] ?? '').toString();
        return v.isEmpty ? null : v;
      })(),
      size: (m['size'] is int) ? (m['size'] as int) : null,
    );
  }
}

class _CacheEntry {
  final File file;
  final int size;
  final DateTime lastAccess;
  final String metaPath;
  _CacheEntry({
    required this.file,
    required this.size,
    required this.lastAccess,
    required this.metaPath,
  });
}

/* ======================== ويدجت اختيارية لعرض الصور مع الكاش ======================== */

/// ويدجت خفيفة لعرض صورة من [url] باستخدام الكاش المحلي.
/// إن لم يكن الملف موجودًا سيتم تنزيله وعرضه، ثم يُستخدم محليًا لاحقًا.
class AttachmentCacheImage extends StatefulWidget {
  final String url;
  final double? width;
  final double? height;
  final BoxFit? fit;
  final AlignmentGeometry alignment;
  final BorderRadius? borderRadius;
  final Widget? placeholder;
  final Widget? errorWidget;
  final bool gaplessPlayback;
  final Color? backgroundColor;

  const AttachmentCacheImage({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.fit,
    this.alignment = Alignment.center,
    this.borderRadius,
    this.placeholder,
    this.errorWidget,
    this.gaplessPlayback = true,
    this.backgroundColor,
  });

  @override
  State<AttachmentCacheImage> createState() => _AttachmentCacheImageState();
}

class _AttachmentCacheImageState extends State<AttachmentCacheImage> {
  File? _file;
  Object? _error;
  late final String _url = widget.url;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant AttachmentCacheImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _file = null;
      _error = null;
      _load();
    }
  }

  Future<void> _load() async {
    setState(() {
      _file = null;
      _error = null;
    });
    try {
      // إن وُجد الملف محليًا بشكل متزامن، اعرضه فورًا
      final sync = AttachmentCache.instance.localPathSyncIfAny(_url);
      if (sync != null) {
        _file = File(sync);
        if (mounted) setState(() {});
      } else {
        final f = await AttachmentCache.instance.fileFor(_url);
        if (!mounted) return;
        setState(() => _file = f);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final radius = widget.borderRadius;

    Widget child;
    if (_file != null) {
      child = Image.file(
        _file!,
        width: widget.width,
        height: widget.height,
        fit: widget.fit ?? BoxFit.cover,
        alignment: widget.alignment,
        gaplessPlayback: widget.gaplessPlayback,
      );
    } else if (_error != null) {
      child = widget.errorWidget ??
          Center(
            child: Icon(
              Icons.broken_image_outlined,
              size: (widget.width != null && widget.height != null)
                  ? (min(widget.width!, widget.height!) * .4).clamp(20.0, 48.0)
                  : 32,
            ),
          );
    } else {
      child = widget.placeholder ??
          Center(
            child: SizedBox(
              width: 28,
              height: 28,
              child: const CircularProgressIndicator(strokeWidth: 2.6),
            ),
          );
    }

    if (radius != null) {
      child = ClipRRect(borderRadius: radius, child: child);
    }

    if (widget.backgroundColor != null) {
      child = ColoredBox(color: widget.backgroundColor!, child: child);
    }

    return child;
  }
}
