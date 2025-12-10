// lib/core/neumorphism.dart
import 'package:flutter/material.dart';
import 'theme.dart';

/// أدوات نيومورفيزم: ظلّان (فاتح/داكن) + حواف ناعمة.
BoxShadow _lightShadow(BuildContext context, double depth) {
  // ظلّ فاتح (أعلى-يسار)
  return BoxShadow(
    color: Colors.white.withValues(alpha: .95),
    offset: Offset(-depth, -depth),
    blurRadius: depth * 2.2,
    spreadRadius: depth * .2,
  );
}

BoxShadow _darkShadow(BuildContext context, double depth) {
  // ظلّ داكن (أسفل-يمين)
  final c = Theme.of(context).brightness == Brightness.dark
      ? Colors.black.withValues(alpha: .45)
      : const Color(0xFFCFD8DC).withValues(alpha: .75);
  return BoxShadow(
    color: c,
    offset: Offset(depth, depth),
    blurRadius: depth * 2.6,
    spreadRadius: depth * .2,
  );
}

/// بطاقة نيومورفيزم عامة (تتقلّص عرضياً لتجنّب مشاكل القيود غير المحدودة)
class NeuCard extends StatelessWidget {
  final Widget? child;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double radius;
  final double depth;
  final Color? color;
  final bool convex; // true: بارزة، false: غائرة (تقليد بسيط)
  final GestureTapCallback? onTap;

  const NeuCard({
    super.key,
    this.child,
    this.padding,
    this.margin,
    this.radius = kRadius,
    this.depth = 6,
    this.color,
    this.convex = true,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final bg = color ?? Theme.of(context).colorScheme.surface;
    final normalShadows = [
      _lightShadow(context, depth),
      _darkShadow(context, depth),
    ];

    // عندما لا نحتاج onTap: حاوية متحرّكة بسيطة.
    if (onTap == null) {
      return Padding(
        padding: margin ?? EdgeInsets.zero,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          // ⚠️ نجعلها تتقلّص عرضياً حتى لو كان الأب بعرض غير محدود
          constraints: const BoxConstraints(),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(radius),
            boxShadow: convex ? normalShadows : null,
          ),
          padding: padding,
          child: child,
        ),
      );
    }

    // عند وجود onTap: نستخدم مُتابِع ضغط لتغيير الظلال مع المحافظة على الحواف والحجم.
    return Padding(
      padding: margin ?? EdgeInsets.zero,
      child: _NeuPressable(
        radius: radius,
        depth: depth,
        builder: (pressed) {
          final pressedShadows = [
            _lightShadow(context, pressed ? depth * .5 : depth),
            _darkShadow(context, pressed ? depth * .5 : depth),
          ];

          return AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            // تقلّص عرضي أيضاً
            constraints: const BoxConstraints(),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(radius),
              boxShadow: convex ? pressedShadows : null,
            ),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(radius),
                onTap: onTap,
                child: Padding(
                  padding: padding ?? EdgeInsets.zero,
                  child: child,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// زر نيومورفيزم
class NeuButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool filled;
  final double radius;
  final double depth;
  final EdgeInsetsGeometry padding;

  const NeuButton.primary({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.radius = kRadius,
    this.depth = 6,
    this.padding = const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
  }) : filled = true;

  const NeuButton.flat({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.radius = kRadius,
    this.depth = 6,
    this.padding = const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
  }) : filled = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = filled ? kPrimaryColor : scheme.surface;
    final txt = filled ? Colors.white : scheme.onSurface;

    return _NeuPressable(
      radius: radius,
      depth: depth,
      builder: (pressed) {
        final shadows = filled
            ? [
                _lightShadow(context, pressed ? depth * .4 : depth * .8),
                _darkShadow(context, pressed ? depth * .4 : depth * .8),
              ]
            : [
                _lightShadow(context, pressed ? depth * .4 : depth),
                _darkShadow(context, pressed ? depth * .4 : depth),
              ];

        return AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          constraints: const BoxConstraints(), // تقلّص عرضياً
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(radius),
            boxShadow: shadows,
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(radius),
              onTap: onPressed,
              child: Padding(
                padding: padding,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  textDirection: TextDirection.ltr,
                  children: [
                    if (icon != null) ...[
                      Icon(icon, color: txt, size: 20),
                      const SizedBox(width: 10),
                    ],
                    Text(
                      label,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: txt,
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// حقل إدخال نيومورفيزم
class NeuField extends StatefulWidget {
  final TextEditingController? controller;
  final String? hintText;
  final String? labelText;
  final TextInputType? keyboardType;
  final TextDirection textDirection;
  final TextAlign textAlign;
  final bool obscureText;
  final Widget? prefix;
  final Widget? suffix;
  final int? maxLines;
  final String? Function(String?)? validator;
  final void Function(String)? onChanged;
  final EdgeInsetsGeometry contentPadding;
  final double radius;
  final double depth;
  final bool enabled;

  // دعم إجراءات لوحة المفاتيح والإرسال والتركيز
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;
  final FocusNode? focusNode;

  const NeuField({
    super.key,
    this.controller,
    this.hintText,
    this.labelText,
    this.keyboardType,
    this.textDirection = TextDirection.rtl,
    this.textAlign = TextAlign.right,
    this.obscureText = false,
    this.prefix,
    this.suffix,
    this.maxLines = 1,
    this.validator,
    this.onChanged,
    this.contentPadding =
        const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    this.radius = kRadius,
    this.depth = 6,
    this.enabled = true,
    this.textInputAction,
    this.onSubmitted,
    this.focusNode,
  });

  @override
  State<NeuField> createState() => _NeuFieldState();
}

class _NeuFieldState extends State<NeuField> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = scheme.surfaceContainerHigh;

    final shadows = [
      _lightShadow(context, _focused ? widget.depth * .5 : widget.depth),
      _darkShadow(context, _focused ? widget.depth * .5 : widget.depth),
    ];

    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      constraints: const BoxConstraints(), // تقلّص عرضياً
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(widget.radius),
        boxShadow: shadows,
        border: Border.all(
          color: _focused
              ? kPrimaryColor.withValues(alpha: .5)
              : scheme.outlineVariant,
          width: _focused ? 1.4 : 1.0,
        ),
      ),
      child: Focus(
        onFocusChange: (v) => setState(() => _focused = v),
        child: Padding(
          padding: widget.contentPadding,
          child: Directionality(
            textDirection: widget.textDirection,
            child: TextFormField(
              enabled: widget.enabled,
              controller: widget.controller,
              focusNode: widget.focusNode,
              keyboardType: widget.keyboardType,
              obscureText: widget.obscureText,
              maxLines: widget.maxLines,
              validator: widget.validator,
              onChanged: widget.onChanged,
              textAlign: widget.textAlign,
              textInputAction: widget.textInputAction,
              onFieldSubmitted: widget.onSubmitted,
              style: TextStyle(
                color: scheme.onSurface,
                fontWeight: FontWeight.w600,
                fontSize: 14.5,
              ),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: widget.hintText,
                labelText: widget.labelText,
                labelStyle: TextStyle(
                  color: scheme.onSurface.withValues(alpha: .7),
                  fontWeight: FontWeight.w600,
                ),
                hintStyle:
                    TextStyle(color: scheme.onSurface.withValues(alpha: .45)),
                prefixIcon: widget.prefix,
                suffixIcon: widget.suffix,
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// عنصر داخلي لمتابعة حالة الضغط لإبراز تأثير نيومورفيزم
class _NeuPressable extends StatefulWidget {
  final Widget Function(bool pressed) builder;
  final double radius;
  final double depth;
  const _NeuPressable({
    required this.builder,
    required this.radius,
    required this.depth,
  });

  @override
  State<_NeuPressable> createState() => _NeuPressableState();
}

class _NeuPressableState extends State<_NeuPressable> {
  bool _pressed = false;

  void _set(bool v) {
    if (_pressed != v) setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => _set(true),
      onPointerUp: (_) => _set(false),
      onPointerCancel: (_) => _set(false),
      child: widget.builder(_pressed),
    );
  }
}
