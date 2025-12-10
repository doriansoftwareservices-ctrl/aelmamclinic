// lib/screens/chat/image_viewer_screen.dart
//
// عارض صور بنمط واتساب/تيليجرام مع:
// - تكبير/تصغير باللمس + Double-tap حول موضع اللمس.
// - سحب رأسي لإغلاق مع تعتيم تدريجي للخلفية.
// - تمرير أفقي بين الصور + Hero.
// - شريط علوي/سفلي قابل للإخفاء باللمس.
// - BottomSheet للإجراءات (نسخ الرابط/مشاركة/حفظ/حذف) عبر callbacks اختيارية.
// - ✅ دعم عرض المسار المحلي مباشرة (File) أو رابط HTTP(S).
// - ✅ حفظ الصورة إلى مجلد Downloads على Windows/Android:
//      * إن كانت الصورة محلية: نسخ الملف.
//      * إن كانت الصورة عبر الشبكة: تنزيل الملف.
// - بدون حزم خارجية، وداعم RTL.
//
// ملاحظات:
// * عند مقياس 1x نعطّل pan في InteractiveViewer حتى لا يتعارض مع سحب الإغلاق.
// * نستبق تحميل الصورة التالية/السابقة (precache) لتجربة أسرع (FileImage/NetworkImage حسب المصدر).

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui show TextDirection;

import 'package:flutter/foundation.dart'
    show consolidateHttpClientResponseBytes;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class ImageViewerItem {
  /// يمكن أن يكون رابط HTTP(S) أو مسار ملف محلي أو file://URI
  final String url;
  final String? caption;
  final String? heroTag;

  const ImageViewerItem({
    required this.url,
    this.caption,
    this.heroTag,
  });

  static List<ImageViewerItem> fromUrls(List<String> urls) =>
      urls.map((u) => ImageViewerItem(url: u)).toList();
}

class ImageViewerScreen extends StatefulWidget {
  /// الوضع المفضّل: قائمة عناصر
  final List<ImageViewerItem> items;
  final int initialIndex;

  /// توافق خلفي مع استدعاءات قديمة: صورة واحدة (قد تكون محلية أو HTTP)
  final String? imageUrl;
  final String? caption;
  final String? heroTag;

  /// callbacks اختيارية
  final void Function(int index, ImageViewerItem item)? onDelete;
  final void Function(int index, ImageViewerItem item)? onShare;
  final void Function(int index, ImageViewerItem item)? onSave;

  const ImageViewerScreen({
    super.key,
    required this.items,
    this.initialIndex = 0,
    this.onDelete,
    this.onShare,
    this.onSave,

    // توافق خلفي
    this.imageUrl,
    this.caption,
    this.heroTag,
  }) : assert(items.length > 0 || imageUrl != null,
            'مرّر items غير فارغة أو imageUrl واحدة على الأقل');

  /// مساعد فتح الشاشة (قائمة)
  static Future<void> push(
    BuildContext context, {
    required List<ImageViewerItem> items,
    int initialIndex = 0,
    void Function(int, ImageViewerItem)? onDelete,
    void Function(int, ImageViewerItem)? onShare,
    void Function(int, ImageViewerItem)? onSave,
  }) {
    return Navigator.of(context).push(
      PageRouteBuilder(
        opaque: true,
        barrierColor: Colors.black,
        pageBuilder: (_, __, ___) => ImageViewerScreen(
          items: items,
          initialIndex: initialIndex,
          onDelete: onDelete,
          onShare: onShare,
          onSave: onSave,
        ),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
      ),
    );
  }

  /// مساعد فتح الشاشة (صورة واحدة — توافقًا خلفيًا)
  static Future<void> pushSingle(
    BuildContext context, {
    required String imageUrl,
    String? caption,
    String? heroTag,
    void Function(int, ImageViewerItem)? onDelete,
    void Function(int, ImageViewerItem)? onShare,
    void Function(int, ImageViewerItem)? onSave,
  }) {
    return Navigator.of(context).push(
      PageRouteBuilder(
        opaque: true,
        barrierColor: Colors.black,
        pageBuilder: (_, __, ___) => ImageViewerScreen(
          items: const [],
          imageUrl: imageUrl,
          caption: caption,
          heroTag: heroTag,
          onDelete: onDelete,
          onShare: onShare,
          onSave: onSave,
        ),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
      ),
    );
  }

  @override
  State<ImageViewerScreen> createState() => _ImageViewerScreenState();
}

class _ImageViewerScreenState extends State<ImageViewerScreen>
    with SingleTickerProviderStateMixin {
  late final PageController _pageController;
  late List<ImageViewerItem> _items;
  late int _index;

  // تحكم بالتكبير لكل صفحة
  late final List<TransformationController> _controllers;

  // سحب لإغلاق
  double _dragOffsetY = 0.0;
  bool _isDismissing = false;
  late final AnimationController _springCtrl;
  late Animation<double> _springAnim;

  // Chrome (الأشرطة)
  bool _chromeVisible = true;

  @override
  void initState() {
    super.initState();

    // توافق خلفي: لو items فارغة ونُقلت imageUrl قديمة، حوّلها إلى عنصر واحد
    _items = widget.items.isNotEmpty
        ? widget.items
        : [
            ImageViewerItem(
              url: widget.imageUrl!,
              caption: widget.caption,
              heroTag: widget.heroTag ?? widget.imageUrl,
            )
          ];

    _index = widget.initialIndex.clamp(0, _items.length - 1);
    _pageController = PageController(initialPage: _index);
    _controllers =
        List.generate(_items.length, (_) => TransformationController());

    _springCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 220));
    _springAnim =
        CurvedAnimation(parent: _springCtrl, curve: Curves.easeOutCubic);

    _enterImmersive();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _precacheAround(_index);
    });
  }

  void _enterImmersive() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
        systemNavigationBarColor: Colors.black,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
    );
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    _springCtrl.dispose();
    _pageController.dispose();
    super.dispose();
  }

  void _toggleChrome() => setState(() => _chromeVisible = !_chromeVisible);

  void _resetZoom(int i) {
    _controllers[i].value = Matrix4.identity();
    setState(() {});
  }

  bool _isZoomed(int i) {
    final m = _controllers[i].value;
    // أي مقياس أكبر من 1 يدل على تكبير
    return m.storage[0] > 1.001 || m.storage[5] > 1.001;
    // storage[0] = scaleX, storage[5] = scaleY
  }

  void _onDoubleTapDown(TapDownDetails d) {
    final i = _index;
    final controller = _controllers[i];
    final zoomed = _isZoomed(i);

    if (zoomed) {
      controller.value = Matrix4.identity();
    } else {
      // كِبّر إلى 2.5x حول موضع اللمس
      final position = d.localPosition;
      const scale = 2.5;
      final m = Matrix4.identity()
        ..translate(-position.dx, -position.dy)
        ..scale(scale)
        ..translate(position.dx, position.dy);
      controller.value = m;
    }
    setState(() {});
  }

  // -------- سحب لإغلاق (vertical drag) --------
  void _onVerticalDragStart(DragStartDetails d) {
    if (_isZoomed(_index)) return; // لا تفعّل إن كان مكبّرًا
    _springCtrl.stop();
    _isDismissing = true;
  }

  void _onVerticalDragUpdate(DragUpdateDetails d) {
    if (!_isDismissing) return;
    setState(() {
      _dragOffsetY += d.delta.dy;
    });
  }

  void _onVerticalDragEnd(DragEndDetails d) {
    if (!_isDismissing) return;
    _isDismissing = false;

    final shouldClose = _dragShouldClose(_dragOffsetY, d.primaryVelocity ?? 0);
    if (shouldClose) {
      Navigator.of(context).maybePop();
      return;
    }

    // ارجع للصفر بسلاسة
    final start = _dragOffsetY;
    _springCtrl.reset();
    _springAnim =
        CurvedAnimation(parent: _springCtrl, curve: Curves.easeOutCubic)
          ..addListener(() {
            setState(() {
              _dragOffsetY = start * (1 - _springAnim.value);
            });
          });
    _springCtrl.forward();
  }

  bool _dragShouldClose(double dy, double velocity) {
    final v = velocity.abs();
    final dist = dy.abs();
    return dist > 160 || v > 900;
  }

  double get _bgOpacity {
    final k = (1 - (_dragOffsetY.abs() / 320)).clamp(0.0, 1.0);
    return k;
  }

  void _precacheAround(int i) {
    if (!mounted) return;
    final prev = i - 1;
    final next = i + 1;
    if (prev >= 0) _precacheItem(_items[prev]);
    if (next < _items.length) _precacheItem(_items[next]);
  }

  void _precacheItem(ImageViewerItem item) {
    final src = item.url;
    if (_isLocal(src)) {
      final path = _normalizeLocalPath(src);
      if (path != null && File(path).existsSync()) {
        precacheImage(FileImage(File(path)), context);
      }
    } else {
      precacheImage(NetworkImage(src), context);
    }
  }

  bool _isLocal(String s) {
    if (s.startsWith('file://')) return true;
    try {
      return File(s).existsSync();
    } catch (_) {
      return false;
    }
  }

  String? _normalizeLocalPath(String s) {
    try {
      if (s.startsWith('file://')) {
        return File.fromUri(Uri.parse(s)).path;
      }
      if (File(s).isAbsolute) return s;
      // مسارات نسبية نادراً ما تُمرَّر هنا، لكن نعالجها بافتراضها نسبية لمجلد العمل.
      return File(s).absolute.path;
    } catch (_) {
      return null;
    }
  }

  bool _isRemoteHttp(String s) {
    return s.startsWith('http://') || s.startsWith('https://');
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;

    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Scaffold(
        backgroundColor: Colors.black.withValues(alpha: _bgOpacity),
        body: Stack(
          children: [
            PageView.builder(
              controller: _pageController,
              onPageChanged: (i) {
                setState(() => _index = i);
                _precacheAround(i);
              },
              itemCount: items.length,
              itemBuilder: (context, i) {
                final it = items[i];
                final heroTag = it.heroTag ?? it.url;
                final isCurrent = i == _index;
                final isLocal = _isLocal(it.url);
                final localPath = isLocal ? _normalizeLocalPath(it.url) : null;

                final image = isLocal && localPath != null
                    ? Image.file(
                        File(localPath),
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                        errorBuilder: (_, __, ___) => const Icon(
                          Icons.broken_image_rounded,
                          color: Colors.white54,
                          size: 64,
                        ),
                      )
                    : Image.network(
                        it.url,
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                        // مؤشر تحميل مع نسبة مئوية إن أمكن
                        loadingBuilder: (_, child, progress) {
                          if (progress == null) return child;
                          final total = progress.expectedTotalBytes ?? 0;
                          final loaded = progress.cumulativeBytesLoaded;
                          final v = total > 0 ? loaded / total : null;
                          return Stack(
                            alignment: Alignment.center,
                            children: [
                              const SizedBox(
                                width: 56,
                                height: 56,
                                child: CircularProgressIndicator(),
                              ),
                              if (v != null)
                                Positioned(
                                  bottom: 40,
                                  child: Text(
                                    '${(v * 100).clamp(0, 100).toStringAsFixed(0)}%',
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                            ],
                          );
                        },
                        errorBuilder: (_, __, ___) => const Icon(
                          Icons.broken_image_rounded,
                          color: Colors.white54,
                          size: 64,
                        ),
                      );

                final viewer = InteractiveViewer(
                  transformationController: _controllers[i],
                  minScale: 1.0,
                  maxScale: 5.0,
                  scaleEnabled: true,
                  // اسمح بالسحب داخل الصورة فقط عندما يكون مكبّرًا حتى لا يتعارض مع سحب الإغلاق
                  panEnabled: _isZoomed(i),
                  child: image,
                );

                final content = GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _toggleChrome,
                  onLongPress: () => _showActionsSheet(context),
                  onDoubleTapDown: _onDoubleTapDown,
                  onDoubleTap: () {}, // الفعل يتم في onDoubleTapDown
                  onVerticalDragStart: isCurrent ? _onVerticalDragStart : null,
                  onVerticalDragUpdate:
                      isCurrent ? _onVerticalDragUpdate : null,
                  onVerticalDragEnd: isCurrent ? _onVerticalDragEnd : null,
                  child: Center(
                    child: Hero(
                      tag: heroTag,
                      // flightShuttleBuilder أبقيناه الافتراضي لمواءمة التلاشي
                      child: viewer,
                    ),
                  ),
                );

                // حرك الصورة الحالية فقط مع السحب
                final y = isCurrent ? _dragOffsetY : 0.0;
                return Transform.translate(
                  offset: Offset(0, y),
                  child: content,
                );
              },
            ),

            // شريط علوي
            AnimatedPositioned(
              duration: const Duration(milliseconds: 180),
              top: _chromeVisible ? 0 : -80,
              left: 0,
              right: 0,
              child: SafeArea(
                bottom: false,
                child: _TopBar(
                  index: _index,
                  total: items.length,
                  isZoomed: _isZoomed(_index),
                  onBack: () => Navigator.of(context).maybePop(),
                  onResetZoom: () => _resetZoom(_index),
                  onMenu: () => _showActionsSheet(context),
                ),
              ),
            ),

            // شريط سفلي (Caption)
            AnimatedPositioned(
              duration: const Duration(milliseconds: 180),
              bottom: _chromeVisible ? 0 : -140,
              left: 0,
              right: 0,
              child: SafeArea(
                top: false,
                child: _CaptionBar(
                  text: items[_index].caption ?? '',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showActionsSheet(BuildContext context) {
    final item = _items[_index];
    final isRemote = _isRemoteHttp(item.url);

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF121212),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) {
        return Directionality(
          textDirection: ui.TextDirection.rtl,
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isRemote)
                  _SheetAction(
                    icon: Icons.copy_rounded,
                    label: 'نسخ الرابط',
                    onTap: () async {
                      await Clipboard.setData(ClipboardData(text: item.url));
                      if (mounted) Navigator.pop(context);
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('تم نسخ الرابط.')),
                        );
                      }
                    },
                  ),
                if (widget.onShare != null)
                  _SheetAction(
                    icon: Icons.share_rounded,
                    label: 'مشاركة',
                    onTap: () {
                      Navigator.pop(context);
                      widget.onShare!.call(_index, item);
                    },
                  ),

                // حفظ: إن وُجد onSave نستخدمه، وإلا:
                // - ملف محلي: نسخ إلى Downloads
                // - رابط HTTP: تنزيل إلى Downloads
                _SheetAction(
                  icon: Icons.download_rounded,
                  label: 'حفظ',
                  onTap: () async {
                    Navigator.pop(context);
                    if (widget.onSave != null) {
                      widget.onSave!.call(_index, item);
                      return;
                    }
                    if (_isLocal(item.url)) {
                      final p = _normalizeLocalPath(item.url);
                      if (p == null || !File(p).existsSync()) {
                        if (!mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                              content: Text('تعذر الوصول للملف المحلي.')),
                        );
                        return;
                      }
                      await _copyLocalToDownloads(
                        p,
                        suggestedName: _fileNameFromAny(item.url) ??
                            'image_${DateTime.now().millisecondsSinceEpoch}.jpg',
                      );
                    } else {
                      await _downloadToDownloads(
                        item.url,
                        suggestedName: _fileNameFromAny(item.url) ??
                            'image_${DateTime.now().millisecondsSinceEpoch}.jpg',
                      );
                    }
                  },
                ),

                if (widget.onDelete != null)
                  _SheetAction(
                    icon: Icons.delete_outline_rounded,
                    label: 'حذف',
                    isDestructive: true,
                    onTap: () {
                      Navigator.pop(context);
                      widget.onDelete!.call(_index, item);
                    },
                  ),
                const SizedBox(height: 6),
              ],
            ),
          ),
        );
      },
    );
  }

  // ---------------- تنزيل/نسخ إلى Downloads (Windows / Android) ----------------

  Future<void> _downloadToDownloads(String url, {String? suggestedName}) async {
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
            _fileNameFromAny(url) ??
            'image_${DateTime.now().millisecondsSinceEpoch}.jpg',
      );
      final f = File(filePath);
      await f.create(recursive: true);
      await f.writeAsBytes(bytes);
      if (!mounted) return;
      Navigator.of(context).pop(); // إغلاق حوار التقدم
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

  Future<void> _copyLocalToDownloads(String srcPath,
      {String? suggestedName}) async {
    _showProgress();
    try {
      final dirPath = await _resolveDownloadsDir();
      if (dirPath == null) {
        throw 'تعذر تحديد مجلد التنزيلات على هذا النظام.';
      }
      final filePath = _uniquePath(
        dirPath,
        suggestedName ??
            _fileNameFromAny(srcPath) ??
            'image_${DateTime.now().millisecondsSinceEpoch}.jpg',
      );
      await File(srcPath).copy(filePath);
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تم الحفظ في: $filePath')),
      );
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).maybePop();
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('تعذّر النسخ: $e')));
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
        final homeDrive = Platform.environment['HOMEDRIVE'] ?? '';
        final homePath = Platform.environment['HOMEPATH'] ?? '';
        if (homeDrive.isNotEmpty && homePath.isNotEmpty) {
          final p = '$homeDrive$homePath\\Downloads';
          if (Directory(p).existsSync()) return p;
        }
        return null;
      } else if (Platform.isAndroid) {
        const candidates = [
          '/storage/emulated/0/Download',
          '/sdcard/Download',
        ];
        for (final p in candidates) {
          final d = Directory(p);
          if (d.existsSync()) return p;
        }
        final d = Directory(candidates.first);
        if (!d.existsSync()) {
          try {
            d.createSync(recursive: true);
          } catch (_) {}
        }
        return d.existsSync() ? d.path : null;
      } else {
        return null; // منصات أخرى غير مطلوبة حاليًا
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

  /// يستخرج اسم ملف سواء من رابط HTTP أو من مسار محلي أو file://
  String? _fileNameFromAny(String input) {
    try {
      if (_isRemoteHttp(input)) {
        final u = Uri.parse(input);
        final last = u.pathSegments.isNotEmpty ? u.pathSegments.last : null;
        if (last == null || last.trim().isEmpty) return null;
        return last.split('?').first;
      }
      // محلي
      final path = _normalizeLocalPath(input);
      if (path == null) return null;
      final fileName = path.split(Platform.pathSeparator).last;
      return (fileName.trim().isEmpty) ? null : fileName;
    } catch (_) {
      return null;
    }
  }

  void _showProgress() {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => WillPopScope(
        onWillPop: () async => false,
        child: const Center(child: CircularProgressIndicator()),
      ),
    );
  }
}

/*──────────────────────── UI parts ───────────────────────*/

class _TopBar extends StatelessWidget {
  final int index;
  final int total;
  final bool isZoomed;
  final VoidCallback onBack;
  final VoidCallback onResetZoom;
  final VoidCallback onMenu;

  const _TopBar({
    required this.index,
    required this.total,
    required this.isZoomed,
    required this.onBack,
    required this.onResetZoom,
    required this.onMenu,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 56,
      margin: const EdgeInsets.all(8),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .35),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
          ),
          const SizedBox(width: 8),
          Text(
            '${index + 1} / $total',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              fontSize: 16,
            ),
          ),
          const Spacer(),
          if (isZoomed)
            IconButton(
              onPressed: onResetZoom,
              tooltip: 'إعادة الضبط',
              icon: const Icon(Icons.center_focus_strong_rounded,
                  color: Colors.white),
            ),
          IconButton(
            onPressed: onMenu,
            tooltip: 'خيارات',
            icon: const Icon(Icons.more_vert_rounded, color: Colors.white),
          ),
        ],
      ),
    );
  }
}

class _CaptionBar extends StatelessWidget {
  final String text;
  const _CaptionBar({required this.text});

  @override
  Widget build(BuildContext context) {
    if (text.trim().isEmpty) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.all(8),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .35),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Text(
        text,
        textDirection:
            _looksLtr(text) ? ui.TextDirection.ltr : ui.TextDirection.rtl,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w700,
          height: 1.35,
        ),
      ),
    );
  }

  bool _looksLtr(String s) {
    final hasEmail = s.contains('@') && s.contains('.');
    final hasLatin = RegExp(r'[A-Za-z]').hasMatch(s);
    return hasEmail || hasLatin;
  }
}

class _SheetAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool isDestructive;

  const _SheetAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.isDestructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = isDestructive ? Colors.redAccent : Colors.white;
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(
        label,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w800,
        ),
      ),
      onTap: onTap,
    );
  }
}
