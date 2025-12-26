// lib/widgets/chat/image_viewer_screen.dart
//
// شاشة عرض الصور (عارض كامل مع تكبير/تصغير وسحب أفقي بين الصور).
// - تدعم مصادر Nhost Storage عبر تحويل fileId إلى رابط عام.
// - دعم RTL، شريط علوي/سفلي يظهران/يختفيان عند الضغط.
// - تكبير/تصغير عبر السحب/القرص + نقر مزدوج (toggle).
// - إجراءات: نسخ الرابط، معلومات، حذف اختياري، و✅ تنزيل إلى مجلد Downloads في Windows/Android.
//
// ملاحظات:
// - لا تعتمد على حِزم خارجية؛ الحفظ يتم عبر dart:io مباشرة.
// - للاستخدام مع ChatAttachment أو روابط مباشرة.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart'
    show consolidateHttpClientResponseBytes;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:aelmamclinic/core/theme.dart' show kPrimaryColor;
import 'package:aelmamclinic/services/nhost_storage_service.dart';
import 'package:aelmamclinic/models/chat_models.dart' show ChatAttachment;
import 'package:aelmamclinic/utils/time.dart' as time;

/// عنصر داخلي موحّد لتمثيل صورة للعرض
class _ImageItem {
  final String? displayName;
  final String? url; // قد تكون http(s) أو storage://bucket/path
  final String? bucket; // عند توافرها مع path نشتق storage://
  final String? path;
  final int? width;
  final int? height;
  final DateTime? createdAt;

  const _ImageItem({
    this.displayName,
    this.url,
    this.bucket,
    this.path,
    this.width,
    this.height,
    this.createdAt,
  });

  String? get storageUrl {
    if (bucket != null && path != null) return 'storage://$bucket/$path';
    return url?.startsWith('storage://') == true ? url : null;
  }

  String get bestKey {
    if (url != null && url!.isNotEmpty) return url!;
    if (bucket != null && path != null) return 'storage://$bucket/$path';
    if (displayName != null) return displayName!;
    return hashCode.toString();
  }

  factory _ImageItem.fromAttachment(ChatAttachment a) {
    return _ImageItem(
      displayName: a.path?.split('/').last ?? a.url.split('/').last,
      url: a.url, // قد يكون موجودًا بعد _normalizeAttachmentsToHttp
      bucket: a.bucket,
      path: a.path,
      width: a.width,
      height: a.height,
      createdAt: a.createdAt,
    );
  }
}

class ImageViewerScreen extends StatefulWidget {
  /// عناصر الصور (مهيّأة مسبقًا)
  final List<_ImageItem> items;

  /// الفهرس الابتدائي
  final int initialIndex;

  /// كولباكات اختيارية (إن رغبت بتمكين وظائف إضافية داخل التطبيق).
  final Future<void> Function(String resolvedUrl)? onSaveCurrent;
  final Future<void> Function(String resolvedUrl)? onOpenExternal;
  final Future<void> Function(int index, _ImageItem item)? onDeleteCurrent;

  const ImageViewerScreen({
    super.key,
    required this.items,
    this.initialIndex = 0,
    this.onSaveCurrent,
    this.onOpenExternal,
    this.onDeleteCurrent,
  });

  /// مُنشئ مناسب من روابط مباشرة (قد تكون http(s) أو storage://)
  factory ImageViewerScreen.fromUrls({
    required List<String> urls,
    int initialIndex = 0,
    Future<void> Function(String url)? onSaveCurrent,
    Future<void> Function(String url)? onOpenExternal,
    Future<void> Function(int, _ImageItem)? onDeleteCurrent,
  }) {
    final items = urls
        .map(
          (u) => _ImageItem(
            url: u,
            displayName: u.split('/').isNotEmpty
                ? u.split('/').last.split('?').first
                : null,
          ),
        )
        .toList(growable: false);
    return ImageViewerScreen(
      items: items,
      initialIndex: initialIndex,
      onSaveCurrent: onSaveCurrent,
      onOpenExternal: onOpenExternal,
      onDeleteCurrent: onDeleteCurrent,
    );
  }

  /// مُنشئ مناسب من ChatAttachment (بعد جلب الرسالة)
  factory ImageViewerScreen.fromAttachments({
    required List<ChatAttachment> attachments,
    int initialIndex = 0,
    Future<void> Function(String url)? onSaveCurrent,
    Future<void> Function(String url)? onOpenExternal,
    Future<void> Function(int, _ImageItem)? onDeleteCurrent,
  }) {
    final items = attachments
        .map((a) => _ImageItem.fromAttachment(a))
        .toList(growable: false);
    return ImageViewerScreen(
      items: items,
      initialIndex: initialIndex,
      onSaveCurrent: onSaveCurrent,
      onOpenExternal: onOpenExternal,
      onDeleteCurrent: onDeleteCurrent,
    );
  }

  @override
  State<ImageViewerScreen> createState() => _ImageViewerScreenState();
}

class _ImageViewerScreenState extends State<ImageViewerScreen> {
  late final PageController _pageController;
  late int _index;
  bool _chromeVisible = true;

  // كاش روابط موقعة/نهائية
  final Map<int, Future<String>> _resolvedUrlFutures = {};
  final NhostStorageService _storage = NhostStorageService();

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.items.length - 1);
    _pageController = PageController(initialPage: _index);
    // نحل مسبقًا العنصر الابتدائي لتحسين زمن ظهور الصورة
    _resolvedUrlFutures[_index] = _resolveAt(_index);
  }

  Future<String> _resolveAt(int i) async {
    final item = widget.items[i];
    if (item.url != null && item.url!.startsWith('http')) {
      return item.url!;
    }
    final fileId = item.path;
    if (fileId != null && fileId.isNotEmpty) {
      return _storage.publicFileUrl(fileId);
    }
    throw Exception('No URL or file id to resolve.');
  }

  void _toggleChrome() => setState(() => _chromeVisible = !_chromeVisible);

  _ImageItem get _currentItem => widget.items[_index];

  Future<void> _copyCurrentLink() async {
    try {
      final url = await (_resolvedUrlFutures[_index] ??= _resolveAt(_index));
      await Clipboard.setData(ClipboardData(text: url));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم نسخ الرابط')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تعذّر نسخ الرابط')),
      );
    }
  }

  Future<void> _showInfo() async {
    final it = _currentItem;
    final created =
        it.createdAt != null ? time.formatMessageTimestamp(it.createdAt!) : '—';
    final wh = (it.width != null || it.height != null)
        ? '${it.width ?? "?"}×${it.height ?? "?"}'
        : '—';
    final name = it.displayName ?? (it.path?.split('/').last ?? '—');
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('معلومات الصورة'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _kv('الاسم', name),
            _kv('الأبعاد', wh),
            _kv(
                'Bucket',
                it.bucket ??
                    (it.url?.startsWith('http') == true ? '—' : 'غير محدد')),
            _kv('Path', it.path ?? '—'),
            _kv('التاريخ', created),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).maybePop(),
            child: const Text('إغلاق'),
          )
        ],
      ),
    );
  }

  Widget _kv(String k, String v) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SelectableText.rich(
        TextSpan(children: [
          TextSpan(
              text: '$k: ',
              style: const TextStyle(fontWeight: FontWeight.w700)),
          TextSpan(text: v),
        ]),
      ),
    );
  }

  /// حفظ الصورة الحالية: إن وُجد كولباك onSaveCurrent نستخدمه،
  /// وإلا ننزّل إلى مجلد Downloads في Windows/Android.
  Future<void> _saveCurrent() async {
    try {
      final url = await (_resolvedUrlFutures[_index] ??= _resolveAt(_index));
      if (widget.onSaveCurrent != null) {
        await widget.onSaveCurrent!.call(url);
        return;
      }
      await _downloadToDownloads(url,
          suggestedName: _suggestFileName(_currentItem, url));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('تعذّر الحفظ: $e')));
    }
  }

  Future<void> _openExternal() async {
    if (widget.onOpenExternal == null) return;
    try {
      final url = await (_resolvedUrlFutures[_index] ??= _resolveAt(_index));
      await widget.onOpenExternal!.call(url);
    } catch (_) {}
  }

  Future<void> _deleteCurrent() async {
    if (widget.onDeleteCurrent == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('حذف الصورة'),
        content: const Text('هل تريد بالتأكيد حذف هذه الصورة؟'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('إلغاء')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('حذف'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    try {
      await widget.onDeleteCurrent!.call(_index, _currentItem);
      if (!mounted) return;
      final removedIndex = _index;
      setState(() {});
      if (Navigator.canPop(context)) Navigator.pop(context, removedIndex);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final total = widget.items.length;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            // الصفحات (الصور)
            PageView.builder(
              controller: _pageController,
              itemCount: total,
              onPageChanged: (i) {
                setState(() => _index = i);
                // ابدأ حل الرابط التالي مسبقًا لتحسين الانتقال
                _resolvedUrlFutures[i] ??= _resolveAt(i);
              },
              itemBuilder: (context, i) {
                return _ImagePage(
                  futureUrl: _resolvedUrlFutures[i] ??= _resolveAt(i),
                  heroTag: widget.items[i].bestKey,
                  onTap: _toggleChrome,
                );
              },
            ),

            // الشريط العلوي
            AnimatedPositioned(
              duration: const Duration(milliseconds: 160),
              left: 0,
              right: 0,
              top: _chromeVisible ? 0 : -80,
              child: SafeArea(
                bottom: false,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  color: Colors.black38,
                  height: 56,
                  child: Row(
                    children: [
                      IconButton(
                        onPressed: () => Navigator.of(context).maybePop(),
                        icon: const Icon(Icons.arrow_back_rounded,
                            color: Colors.white),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'صورة ${_index + 1} / $total',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 16,
                          ),
                        ),
                      ),
                      // قائمة المزيد
                      PopupMenuButton<_MenuAction>(
                        color: cs.surface,
                        icon: const Icon(Icons.more_vert_rounded,
                            color: Colors.white),
                        onSelected: (a) {
                          switch (a) {
                            case _MenuAction.copyLink:
                              _copyCurrentLink();
                              break;
                            case _MenuAction.info:
                              _showInfo();
                              break;
                            case _MenuAction.save:
                              _saveCurrent();
                              break;
                            case _MenuAction.openExternal:
                              _openExternal();
                              break;
                            case _MenuAction.delete:
                              _deleteCurrent();
                              break;
                          }
                        },
                        itemBuilder: (ctx) {
                          final items = <PopupMenuEntry<_MenuAction>>[
                            const PopupMenuItem(
                              value: _MenuAction.copyLink,
                              child: ListTile(
                                leading: Icon(Icons.link_rounded),
                                title: Text('نسخ الرابط'),
                              ),
                            ),
                            const PopupMenuItem(
                              value: _MenuAction.info,
                              child: ListTile(
                                leading: Icon(Icons.info_outline_rounded),
                                title: Text('معلومات'),
                              ),
                            ),
                            const PopupMenuItem(
                              value: _MenuAction.save,
                              child: ListTile(
                                leading: Icon(Icons.download_rounded),
                                title: Text('حفظ الصورة'),
                              ),
                            ),
                          ];
                          if (widget.onOpenExternal != null) {
                            items.add(const PopupMenuItem(
                              value: _MenuAction.openExternal,
                              child: ListTile(
                                leading: Icon(Icons.open_in_new_rounded),
                                title: Text('فتح خارج التطبيق'),
                              ),
                            ));
                          }
                          if (widget.onDeleteCurrent != null) {
                            items.add(const PopupMenuDivider());
                            items.add(PopupMenuItem(
                              value: _MenuAction.delete,
                              child: ListTile(
                                leading: const Icon(Icons.delete_rounded,
                                    color: Colors.red),
                                title: const Text('حذف',
                                    style: TextStyle(color: Colors.red)),
                              ),
                            ));
                          }
                          return items;
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // الشريط السفلي (تسمية/مؤشر)
            AnimatedPositioned(
              duration: const Duration(milliseconds: 160),
              left: 0,
              right: 0,
              bottom: _chromeVisible ? 0 : -80,
              child: SafeArea(
                top: false,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  color: Colors.black38,
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          widget.items[_index].displayName ??
                              widget.items[_index].path?.split('/').last ??
                              'صورة',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.white12,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          '${_index + 1}/$total',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------- تنزيل إلى Downloads (Windows / Android) ----------------

  Future<void> _downloadToDownloads(String url, {String? suggestedName}) async {
    // حوار تحميل بسيط
    _showProgress();
    try {
      final bytes = await _httpGetBytes(url);
      final dirPath = await _resolveDownloadsDir();
      if (dirPath == null) {
        throw 'تعذر تحديد مجلد التنزيلات على هذا النظام.';
      }
      final filePath = _uniquePath(
        dirPath,
        suggestedName ??
            _fileNameFromUrl(url) ??
            'image_${DateTime.now().millisecondsSinceEpoch}.jpg',
      );
      final f = File(filePath);
      await f.create(recursive: true);
      await f.writeAsBytes(bytes);
      if (!mounted) return;
      Navigator.of(context).pop(); // أغلق حوار التقدم
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تم الحفظ في: ${f.path}')),
      );
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).maybePop();
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('تعذّر الحفظ: $e')));
    }
  }

  Future<Uint8List> _httpGetBytes(String url) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url));
      final res = await req.close();
      if (res.statusCode != 200) {
        throw 'HTTP ${res.statusCode}';
      }
      final bytes = await consolidateHttpClientResponseBytes(res);
      return Uint8List.fromList(bytes);
    } finally {
      client.close(force: true);
    }
  }

  Future<String?> _resolveDownloadsDir() async {
    try {
      if (Platform.isWindows) {
        final user = Platform.environment['USERPROFILE'] ?? '';
        if (user.isNotEmpty) {
          final p = '$user\\Downloads';
          if (Directory(p).existsSync()) return p;
        }
        // محاولة بديلة
        final homeDrive = Platform.environment['HOMEDRIVE'] ?? '';
        final homePath = Platform.environment['HOMEPATH'] ?? '';
        if (homeDrive.isNotEmpty && homePath.isNotEmpty) {
          final p = '$homeDrive$homePath\\Downloads';
          if (Directory(p).existsSync()) return p;
        }
        return null;
      } else if (Platform.isAndroid) {
        // الأكثر شيوعًا في أندرويد
        const candidates = [
          '/storage/emulated/0/Download',
          '/sdcard/Download',
        ];
        for (final p in candidates) {
          final d = Directory(p);
          if (d.existsSync()) return p;
        }
        // إن لم يوجد، نحاول إنشاء المسار الأول
        final d = Directory(candidates.first);
        if (!d.existsSync()) {
          try {
            d.createSync(recursive: true);
          } catch (_) {}
        }
        return d.existsSync() ? d.path : null;
      } else {
        // أنظمة أخرى غير مطلوبة في الطلب
        return null;
      }
    } catch (_) {
      return null;
    }
  }

  String _uniquePath(String dir, String baseName) {
    final sanitized = baseName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    String path = _join(dir, sanitized);
    if (!File(path).existsSync()) return path;
    final dot = sanitized.lastIndexOf('.');
    final name = dot > 0 ? sanitized.substring(0, dot) : sanitized;
    final ext = dot > 0 ? sanitized.substring(dot) : '';
    int i = 1;
    while (File(path).existsSync()) {
      path = _join(dir, '$name ($i)$ext');
      i++;
    }
    return path;
  }

  String _join(String a, String b) {
    final sep = Platform.isWindows ? '\\' : '/';
    if (a.endsWith(sep)) return '$a$b';
    return '$a$sep$b';
  }

  String? _fileNameFromUrl(String url) {
    try {
      final u = Uri.parse(url);
      final last = u.pathSegments.isNotEmpty ? u.pathSegments.last : null;
      if (last == null || last.trim().isEmpty) return null;
      return last.split('?').first;
    } catch (_) {
      return null;
    }
  }

  String _suggestFileName(_ImageItem it, String url) {
    return it.displayName ??
        it.path?.split('/').last ??
        _fileNameFromUrl(url) ??
        'image_${DateTime.now().millisecondsSinceEpoch}.jpg';
  }

  void _showProgress() {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => WillPopScope(
        onWillPop: () async => false,
        child: const Center(
          child: CircularProgressIndicator(color: kPrimaryColor),
        ),
      ),
    );
  }
}

enum _MenuAction { copyLink, info, save, openExternal, delete }

/// صفحة صورة مع تكبير/تصغير ونقر مزدوج
class _ImagePage extends StatefulWidget {
  final Future<String> futureUrl;
  final String heroTag;
  final VoidCallback onTap;

  const _ImagePage({
    required this.futureUrl,
    required this.heroTag,
    required this.onTap,
  });

  @override
  State<_ImagePage> createState() => _ImagePageState();
}

class _ImagePageState extends State<_ImagePage>
    with SingleTickerProviderStateMixin {
  final TransformationController _transform = TransformationController();
  TapDownDetails? _doubleTapDetails;

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  void _handleDoubleTap() {
    final current = _transform.value;
    // toggle بين 1x و 2.5x حول نقطة النقر
    if (current != Matrix4.identity()) {
      _animateReset();
    } else {
      final pos = _doubleTapDetails?.localPosition;
      if (pos == null) return;
      const zoom = 2.5;
      final x = -pos.dx * (zoom - 1);
      final y = -pos.dy * (zoom - 1);
      final m = Matrix4.identity()
        ..translate(x, y)
        ..scale(zoom);
      _animateTo(m);
    }
  }

  void _animateTo(Matrix4 to) {
    final controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    );
    final animation = Matrix4Tween(begin: _transform.value, end: to).animate(
      CurvedAnimation(parent: controller, curve: Curves.easeOutCubic),
    );
    animation.addListener(() {
      _transform.value = animation.value;
    });
    controller.addStatusListener((s) {
      if (s == AnimationStatus.completed || s == AnimationStatus.dismissed) {
        controller.dispose();
      }
    });
    controller.forward();
  }

  void _animateReset() => _animateTo(Matrix4.identity());

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: widget.futureUrl,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return Center(
            child: CircularProgressIndicator(color: kPrimaryColor),
          );
        }
        if (!snapshot.hasData || snapshot.data!.isEmpty) {
          return _ErrorPane(onTap: widget.onTap);
        }

        final url = snapshot.data!;
        return GestureDetector(
          onTap: widget.onTap,
          onDoubleTapDown: (d) => _doubleTapDetails = d,
          onDoubleTap: _handleDoubleTap,
          child: Center(
            child: Hero(
              tag: widget.heroTag,
              // استخدام InteractiveViewer + TransformationController للتكبير
              child: InteractiveViewer(
                transformationController: _transform,
                minScale: 1.0,
                maxScale: 5.0,
                panEnabled: true,
                scaleEnabled: true,
                child: Image.network(
                  url,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => _ErrorPane(onTap: widget.onTap),
                  loadingBuilder: (c, child, evt) {
                    if (evt == null) return child;
                    final expected = evt.expectedTotalBytes ?? 0;
                    final loaded = evt.cumulativeBytesLoaded;
                    final p = expected > 0
                        ? (loaded / expected).clamp(0.0, 1.0)
                        : null;
                    return Stack(
                      alignment: Alignment.center,
                      children: [
                        child,
                        Container(color: Colors.black38),
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircularProgressIndicator(color: kPrimaryColor),
                            if (p != null) ...[
                              const SizedBox(height: 10),
                              Text(
                                '${(p * 100).toStringAsFixed(0)}%',
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ErrorPane extends StatelessWidget {
  final VoidCallback onTap;
  const _ErrorPane({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: const Center(
        child:
            Icon(Icons.broken_image_outlined, size: 64, color: Colors.white38),
      ),
    );
  }
}
