// lib/widgets/chat/attachment_chip.dart
//
// مكوّن يعرض شريحة مرفق (صورة فقط) مع معاينة مصغّرة وحالة الرفع.
// - يدعم مصادر الصورة: File / Uint8List / Network URL / ImageProvider مخصّص.
// - حالات الرفع: queued / uploading / uploaded / failed + progress [0..1].
// - زر إزالة + onTap/onLongPress لمعاينة/إجراءات المرفق (مع fallback للمعاينة).
// - تصميم TBIAN (NeuCard) مع RTL + تحسينات وصول ورِبِّل.
//
// المتطلبات:
//   - core/theme.dart       (kPrimaryColor)
//   - core/neumorphism.dart (NeuCard)

import 'dart:io' show File;
import 'dart:typed_data';
import 'dart:ui' as ui show TextDirection;

import 'package:flutter/material.dart';
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';

enum AttachmentUploadStatus { queued, uploading, uploaded, failed }

class AttachmentChip extends StatelessWidget {
  /// اسم المرفق لعرضه على الواجهة (اختياري لكنه مستحسن).
  final String? name;

  /// حجم الملف بالبايت (اختياري؛ لعرضه فقط).
  final int? sizeBytes;

  /// حالة الرفع.
  final AttachmentUploadStatus status;

  /// تقدّم الرفع [0..1] عند status=uploading (اختياري).
  final double? progress;

  /// مصدر الصورة (أولوية حسب الترتيب):
  /// 1) thumbnail
  /// 2) file
  /// 3) bytes
  /// 4) networkUrl
  final ImageProvider? thumbnail;
  final File? file;
  final Uint8List? bytes;
  final String? networkUrl;

  /// استدعاءات
  final VoidCallback? onRemove;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// تعطيل زر الإزالة
  final bool removeEnabled;

  /// عرض مضغوط قليلاً (ارتفاع أقل).
  final bool compact;

  /// حافة خارجية
  final EdgeInsetsGeometry? margin;

  const AttachmentChip({
    super.key,
    this.name,
    this.sizeBytes,
    required this.status,
    this.progress,
    this.thumbnail,
    this.file,
    this.bytes,
    this.networkUrl,
    this.onRemove,
    this.onTap,
    this.onLongPress,
    this.removeEnabled = true,
    this.compact = false,
    this.margin,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    final imgProvider = _resolveImageProvider();
    final height = compact ? 62.0 : 74.0;
    final thumbSize = compact ? 48.0 : 56.0;
    final textMaxW = compact ? 220.0 : 280.0;

    final title =
        (name?.trim().isNotEmpty == true) ? name!.trim() : 'صورة مرفقة';
    final subtitle = _subtitleForStatus(
      sizeBytes: sizeBytes,
      status: status,
      progress: progress,
    );

    String tooltip;
    switch (status) {
      case AttachmentUploadStatus.queued:
        tooltip = 'بانتظار الإرسال';
        break;
      case AttachmentUploadStatus.uploading:
        tooltip = 'جارٍ الرفع';
        break;
      case AttachmentUploadStatus.uploaded:
        tooltip = 'تم الإرسال';
        break;
      case AttachmentUploadStatus.failed:
        tooltip = 'فشل الرفع';
        break;
    }

    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Padding(
        padding:
            margin ?? const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
        child: Semantics(
          label: 'مرفق: $title',
          hint: tooltip,
          button: true,
          child: NeuCard(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            // نضمن ظهور الـ ripple داخل البطاقة
            child: Material(
              color: Colors.transparent,
              clipBehavior: Clip.antiAlias,
              borderRadius: BorderRadius.circular(14),
              child: InkWell(
                onTap: onTap ??
                    (imgProvider != null
                        ? () => _defaultPreview(context, imgProvider)
                        : null),
                onLongPress: onLongPress,
                borderRadius: BorderRadius.circular(14),
                child: SizedBox(
                  height: height,
                  // ⚠️ مهم: نجعل الـRow يتقلّص على العرض لأن الأب يعطي عرضاً غير محدود
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // المصغّر
                      _ThumbnailBox(
                        image: imgProvider,
                        size: thumbSize,
                        status: status,
                        progress: progress ?? 0.0,
                      ),
                      const SizedBox(width: 10),

                      // نصوص (بدون Expanded لتجنّب unbounded width)
                      ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: textMaxW),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Tooltip(
                              message: title,
                              child: Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: scheme.onSurface,
                                  fontWeight: FontWeight.w900,
                                  fontSize: 14.5,
                                ),
                              ),
                            ),
                            const SizedBox(height: 4),
                            AnimatedSwitcher(
                              duration: const Duration(milliseconds: 180),
                              child: Text(
                                subtitle,
                                key: ValueKey(subtitle),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: scheme.onSurface.withValues(alpha: .7),
                                  fontWeight: FontWeight.w700,
                                  fontSize: 12.5,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(width: 8),

                      // زر إزالة
                      Tooltip(
                        message: 'إزالة',
                        child: IconButton(
                          onPressed: removeEnabled ? onRemove : null,
                          icon: const Icon(Icons.close_rounded),
                          iconSize: 20,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints.tightFor(
                              width: 36, height: 36),
                          style: IconButton.styleFrom(
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            visualDensity: const VisualDensity(
                                horizontal: -4, vertical: -4),
                            foregroundColor:
                                scheme.onSurface.withValues(alpha: .75),
                            disabledForegroundColor:
                                scheme.onSurface.withValues(alpha: .35),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  ImageProvider? _resolveImageProvider() {
    if (thumbnail != null) return thumbnail;
    if (file != null) return FileImage(file!);
    if (bytes != null) return MemoryImage(bytes!);
    if (networkUrl != null && networkUrl!.isNotEmpty)
      return NetworkImage(networkUrl!);
    return null;
  }

  String _subtitleForStatus({
    required int? sizeBytes,
    required AttachmentUploadStatus status,
    required double? progress,
  }) {
    final sizeText = sizeBytes != null ? _fmtBytes(sizeBytes) : null;
    switch (status) {
      case AttachmentUploadStatus.queued:
        return sizeText == null
            ? 'بانتظار الإرسال'
            : 'بانتظار الإرسال • $sizeText';
      case AttachmentUploadStatus.uploading:
        final pct =
            ((progress ?? 0.0).clamp(0.0, 1.0) * 100).toStringAsFixed(0);
        return sizeText == null
            ? 'جارٍ الرفع $pct%'
            : 'جارٍ الرفع $pct% • $sizeText';
      case AttachmentUploadStatus.uploaded:
        return sizeText == null ? 'تم الإرسال' : 'تم الإرسال • $sizeText';
      case AttachmentUploadStatus.failed:
        return 'فشل الرفع — حاول مجددًا';
    }
  }

  String _fmtBytes(int b) {
    const units = ['B', 'KB', 'MB', 'GB'];
    double s = b.toDouble();
    int i = 0;
    while (s >= 1024 && i < units.length - 1) {
      s /= 1024;
      i++;
    }
    return '${s.toStringAsFixed(s >= 100 || i == 0 ? 0 : (s >= 10 ? 1 : 2))} ${units[i]}';
    // مثال: 850 B / 12.4 KB / 3.1 MB
  }

  /// معاينة افتراضية إن لم يمرَّر onTap وكانت لدينا ImageProvider
  void _defaultPreview(BuildContext context, ImageProvider img) {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: .85),
      builder: (_) {
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => Navigator.of(context).maybePop(),
          child: Center(
            child: InteractiveViewer(
              minScale: 1,
              maxScale: 5,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Image(image: img, fit: BoxFit.contain),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ThumbnailBox extends StatelessWidget {
  final ImageProvider? image;
  final double size;
  final AttachmentUploadStatus status;
  final double progress;

  const _ThumbnailBox({
    required this.image,
    required this.size,
    required this.status,
    required this.progress,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    Color borderColor;
    switch (status) {
      case AttachmentUploadStatus.failed:
        borderColor = scheme.error.withValues(alpha: .65);
        break;
      case AttachmentUploadStatus.uploaded:
        borderColor = kPrimaryColor.withValues(alpha: .55);
        break;
      case AttachmentUploadStatus.uploading:
        borderColor = kPrimaryColor.withValues(alpha: .35);
        break;
      case AttachmentUploadStatus.queued:
        borderColor = scheme.outline.withValues(alpha: .35);
        break;
    }

    return Stack(
      alignment: Alignment.center,
      children: [
        // الخلفية + الصورة + قص الزوايا
        AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: size,
          height: size,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: borderColor, width: 1),
            color: scheme.surfaceContainerHighest,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: .06),
                blurRadius: 8,
                offset: const Offset(0, 3),
              )
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: (image != null)
              ? Image(
                  image: image!,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) {
                    return Icon(
                      Icons.broken_image_rounded,
                      color: scheme.onSurface.withValues(alpha: .45),
                      size: size * .55,
                    );
                  },
                )
              : Icon(
                  Icons.image_outlined,
                  color: scheme.onSurface.withValues(alpha: .45),
                  size: size * .55,
                ),
        ),

        // طبقة حالة الرفع أو الأيقونة (بانتقالي ناعم)
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 150),
          child: _buildStatusOverlay(context),
        ),
      ],
    );
  }

  Widget _buildStatusOverlay(BuildContext context) {
    switch (status) {
      case AttachmentUploadStatus.uploading:
        return _ProgressOverlay(size: size, progress: progress);
      case AttachmentUploadStatus.failed:
        return _StatusBadge(
          size: size,
          icon: Icons.error_outline_rounded,
          color: Theme.of(context).colorScheme.error,
        );
      case AttachmentUploadStatus.uploaded:
        return _StatusBadge(
          size: size,
          icon: Icons.check_circle_rounded,
          color: kPrimaryColor,
        );
      case AttachmentUploadStatus.queued:
        return const SizedBox.shrink();
    }
  }
}

class _ProgressOverlay extends StatelessWidget {
  final double size;
  final double progress; // 0..1
  const _ProgressOverlay({required this.size, required this.progress});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    // احرص على أن يكون ضمن 0..1 ودائمًا double
    final double p = progress.clamp(0.0, 1.0);

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Colors.black26,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox(
            width: size * .72,
            height: size * .72,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              value: p == 0.0 ? null : p,
              color: kPrimaryColor,
              backgroundColor: Colors.white24,
              semanticsLabel: 'تقدّم الرفع',
              semanticsValue: '${(p * 100).toStringAsFixed(0)}%',
            ),
          ),
          Text(
            '${(p * 100).clamp(0.0, 100.0).toStringAsFixed(0)}%',
            style: TextStyle(
              color: scheme.onSurface,
              fontWeight: FontWeight.w900,
              fontSize: size * .22,
              shadows: const [Shadow(color: Colors.black38, blurRadius: 4)],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final double size;
  final IconData icon;
  final Color color;

  const _StatusBadge({
    required this.size,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: 4,
      bottom: 4,
      child: Container(
        width: size * .34,
        height: size * .34,
        decoration: const BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
          boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 4)],
        ),
        alignment: Alignment.center,
        child: Icon(icon, size: size * .24, color: color),
      ),
    );
  }
}
