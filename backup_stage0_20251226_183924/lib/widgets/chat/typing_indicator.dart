// lib/widgets/chat/typing_indicator.dart
//
// مؤشّر الكتابة (…يكتب) مع نقاط متحركة بنمط TBIAN.
//
// الميزات:
// - عرض أسماء/إيميلات المشاركين مع تصريف عربي بسيط (يكتب/يكتبان/يكتبون).
// - نمطان: فقاعة كاملة (bubble) أو مصغّر (compact) يظهر نقاط فقط.
// - محاذاة ديناميكية حسب alignAsMine (افتراضي: رسائل واردة).
// - دعم RTL بالكامل + عرض الإيميلات باتجاه LTR لتكون مقروءة.
// - رسوم نقاط خفيفة باستخدام AnimationController واحد.
// - توافق خلفي: يقبل كلا الاسمين items أو participants.
// - تحسينات: textOverride, maxNamesToShow, dotSize, glass, AnimatedSwitcher.
//
// الاعتمادات:
//   - core/theme.dart       (kPrimaryColor)
//   - core/neumorphism.dart (NeuCard)

import 'dart:ui' as ui show TextDirection;
import 'package:flutter/material.dart';
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';

class TypingIndicator extends StatefulWidget {
  /// القائمة الموحدة للأسماء/الإيميلات.
  /// ملاحظة: لقبول استدعاءات قديمة، المكوّن يقبل أيضًا `participants` ويحوّلها إلى هذا الحقل.
  final List<String> items;

  /// إظهار/إخفاء المكوّن (يتم التحريك بسلاسة).
  final bool visible;

  /// إن كان true يعرض نقاط فقط بدون فقاعة نصية.
  final bool compact;

  /// محاذاة كمُرسِل (يمين في RTL) أو كرسالة واردة (يسار في RTL).
  /// افتراضي: واردة (false).
  final bool alignAsMine;

  /// هامش خارجي.
  final EdgeInsetsGeometry? margin;

  /// نص مخصّص بدل التوليد الآلي (اختياري).
  final String? textOverride;

  /// أقصى عدد أسماء تُعرض قبل “وآخرون” (افتراضي 2).
  final int maxNamesToShow;

  /// حجم النقاط (افتراضي 6 في الفقاعة و7 في النمط المصغّر).
  final double? dotSize;

  /// تبديل نمط الحاوية بين زجاج/نيومورفك (NeuCard) أو حاوية Material بسيطة.
  final bool glass;

  /// نمط الخط للنص.
  final TextStyle? textStyle;

  /// يقبل كلا الاسمين: `items` أو `participants` (توافق خلفي).
  const TypingIndicator({
    super.key,
    List<String>? items,
    List<String>? participants, // backward-compatible alias
    this.visible = true,
    this.compact = false,
    this.alignAsMine = false,
    this.margin,
    this.textOverride,
    this.maxNamesToShow = 2,
    this.dotSize,
    this.glass = true,
    this.textStyle,
  }) : items = items ?? participants ?? const [];

  @override
  State<TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<TypingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _a1;
  late final Animation<double> _a2;
  late final Animation<double> _a3;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();

    // 3 نقاط بمرحلة مختلفة عبر Intervals
    _a1 = CurvedAnimation(
        parent: _ctrl,
        curve: const Interval(0.00, 0.66, curve: Curves.easeInOut));
    _a2 = CurvedAnimation(
        parent: _ctrl,
        curve: const Interval(0.15, 0.81, curve: Curves.easeInOut));
    _a3 = CurvedAnimation(
        parent: _ctrl,
        curve: const Interval(0.30, 0.96, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // نستخدم AnimatedSwitcher + SizeTransition لظهور/اختفاء ناعم
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      transitionBuilder: (child, anim) => SizeTransition(
          sizeFactor: anim,
          axisAlignment: -1,
          child: FadeTransition(opacity: anim, child: child)),
      child: (!widget.visible || widget.items.isEmpty)
          ? const SizedBox.shrink(key: ValueKey('hidden'))
          : _buildVisible(context),
    );
  }

  Widget _buildVisible(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    final alignment = widget.alignAsMine
        ? AlignmentDirectional.centerStart // start=يمين في RTL
        : AlignmentDirectional.centerEnd; // end=يسار في RTL

    // النص المتولد أو المخصّص
    final typingText =
        (widget.textOverride != null && widget.textOverride!.trim().isNotEmpty)
            ? widget.textOverride!.trim()
            : _composeTypingText(widget.items, widget.maxNamesToShow);

    final dotSize = widget.dotSize ?? (widget.compact ? 7.0 : 6.0);

    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Align(
        alignment: alignment,
        child: Padding(
          padding: widget.margin ??
              const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
          child: widget.compact
              // في النمط المدمج: نقاط فقط + Semantics ليُنطق النص
              ? Semantics(
                  label: typingText,
                  child: _DotsRow(a1: _a1, a2: _a2, a3: _a3, size: dotSize),
                )
              // في النمط الكامل: فقاعة + نص (NeuCard أو حاوية بسيطة)
              : (widget.glass
                  ? NeuCard(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      child: _RowContent(
                        a1: _a1,
                        a2: _a2,
                        a3: _a3,
                        size: dotSize,
                        text: typingText,
                        textStyle: widget.textStyle ??
                            TextStyle(
                              color: scheme.onSurface.withValues(alpha: .80),
                              fontWeight: FontWeight.w800,
                              fontSize: 13.5,
                            ),
                      ),
                    )
                  : Container(
                      decoration: BoxDecoration(
                        color: scheme.surface.withValues(alpha: .6),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: scheme.outlineVariant),
                      ),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      child: _RowContent(
                        a1: _a1,
                        a2: _a2,
                        a3: _a3,
                        size: dotSize,
                        text: typingText,
                        textStyle: widget.textStyle ??
                            TextStyle(
                              color: scheme.onSurface.withValues(alpha: .80),
                              fontWeight: FontWeight.w800,
                              fontSize: 13.5,
                            ),
                      ),
                    )),
        ),
      ),
    );
  }

  /// إنشاء نص عربي: "فلان يكتب…" / "فلان وفلان يكتبان…" / "فلان وآخرون يكتبون…"
  String _composeTypingText(List<String> ps, int maxNamesToShow) {
    // تنظيف وتفريد الأسماء (مع الحفاظ على ترتيب الظهور)
    final seen = <String>{};
    final cleaned = <String>[];
    for (final s in ps) {
      final t = s.trim();
      if (t.isEmpty) continue;
      final key = t.toLowerCase();
      if (seen.add(key)) cleaned.add(t);
    }
    if (cleaned.isEmpty) return 'يكتب…';

    String nice(String s) {
      final t = s.trim();
      if (!t.contains('@')) return t;
      final pre = t.split('@').first;
      return pre.length >= 2 ? pre : t;
    }

    // نحافظ على اتجاه LTR للأسماء/الإيميلات اللاتينية داخل النص العربي
    final names = cleaned.map((s) => _ltrName(nice(s))).toList();

    if (names.length == 1) {
      return '${names[0]} يكتب…';
    }

    if (names.length == 2) {
      return '${names[0]} و ${names[1]} يكتبان…';
    }

    // عرض حتى maxNamesToShow ثم “وآخرون”
    final shown = names.take(maxNamesToShow).join('، ');
    return '$shown وآخرون يكتبون…';
  }

  /// نعرض الاسم/الإيميل باتجاه LTR داخل النص العربي بإحاطته بعلامة LRM
  /// لتحسين القراءة ومنع انقلاب الترتيب مع RTL.
  String _ltrName(String s) {
    const lrm = '\u200E'; // Left-to-Right Mark
    final hasLatin = RegExp(r'[A-Za-z]').hasMatch(s);
    final looksEmail = s.contains('@');
    if (hasLatin || looksEmail) return '$lrm$s$lrm';
    return s;
  }
}

class _RowContent extends StatelessWidget {
  const _RowContent({
    required this.a1,
    required this.a2,
    required this.a3,
    required this.size,
    required this.text,
    required this.textStyle,
  });

  final Animation<double> a1, a2, a3;
  final double size;
  final String text;
  final TextStyle textStyle;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _DotsRow(a1: a1, a2: a2, a3: a3, size: size),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: textStyle,
          ),
        ),
      ],
    );
  }
}

class _DotsRow extends StatelessWidget {
  final Animation<double> a1, a2, a3;
  final double size;
  const _DotsRow(
      {required this.a1, required this.a2, required this.a3, this.size = 6});

  @override
  Widget build(BuildContext context) {
    final base = kPrimaryColor; // لون العلامة المميزة للتطبيق

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _Dot(anim: a1, size: size, color: base.withValues(alpha: .85)),
        SizedBox(width: size * .6),
        _Dot(anim: a2, size: size, color: base.withValues(alpha: .7)),
        SizedBox(width: size * .6),
        _Dot(anim: a3, size: size, color: base.withValues(alpha: .55)),
      ],
    );
  }
}

class _Dot extends StatelessWidget {
  final Animation<double> anim;
  final double size;
  final Color color;
  const _Dot({required this.anim, required this.size, required this.color});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: anim,
      builder: (_, __) {
        // نبض خفيف: تغيير الحجم والشفافية بشكل متعاكس
        final scale = 0.85 + 0.25 * anim.value;
        final opacity = 0.35 + 0.65 * anim.value;

        return Opacity(
          opacity: opacity.clamp(0.0, 1.0),
          child: Transform.scale(
            scale: scale,
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: color.withValues(alpha: .35),
                    blurRadius: 4 * anim.value,
                    spreadRadius: .2,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
