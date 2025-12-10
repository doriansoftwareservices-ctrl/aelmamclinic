// lib/screens/settings/theme_settings_screen.dart
import 'dart:ui' as ui show TextDirection;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/*── تصميم TBIAN ─*/
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/tbian_ui.dart';

import 'package:aelmamclinic/providers/theme_provider.dart';

class ThemeSettingsScreen extends StatelessWidget {
  const ThemeSettingsScreen({super.key});

  String _hex(Color c) =>
      '#${c.value.toRadixString(16).padLeft(8, '0').toUpperCase().substring(2)}';

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final isDarkMode = themeProvider.themeMode == ThemeMode.dark;
    final scheme = Theme.of(context).colorScheme;

    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Scaffold(
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
              const Text('ELMAM CLINIC'),
            ],
          ),
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
            children: [
              const TSectionHeader('إعدادات المظهر'),

              // بطاقة تبديل الوضع الداكن بأسلوب نيومورفيزم
              NeuCard(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 6),
                  leading: Container(
                    decoration: BoxDecoration(
                      color: kPrimaryColor.withValues(alpha: .10),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    padding: const EdgeInsets.all(8),
                    child: Icon(
                      isDarkMode
                          ? Icons.dark_mode_rounded
                          : Icons.light_mode_rounded,
                      color: kPrimaryColor,
                      size: 22,
                    ),
                  ),
                  title: const Text(
                    'الوضع الداكن',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                  ),
                  subtitle: Text(
                    'فعِّل لاستخدام الثيم الداكن • التعـديـل فـوري',
                    style: TextStyle(
                        color: scheme.onSurface.withValues(alpha: .75)),
                  ),
                  trailing: Switch.adaptive(
                    value: isDarkMode,
                    onChanged: (_) => themeProvider.toggleTheme(),
                  ),
                  onTap: () => themeProvider.toggleTheme(),
                ),
              ),

              const SizedBox(height: 16),

              // لمحة عن الألوان الحالية
              Wrap(
                spacing: 16,
                runSpacing: 18,
                children: [
                  _ColorBadge(
                    icon: Icons.palette_outlined,
                    label: 'اللون الأساسي',
                    value: _hex(scheme.primary),
                    sample: scheme.primary,
                  ),
                  _ColorBadge(
                    icon: Icons.layers_outlined,
                    label: 'خلفية السطح',
                    value: _hex(scheme.surface),
                    sample: scheme.surface,
                  ),
                  _ColorBadge(
                    icon: Icons.text_fields_rounded,
                    label: 'لون النص',
                    value: _hex(scheme.onSurface),
                    sample: scheme.onSurface,
                    isText: true,
                  ),
                ],
              ),

              const SizedBox(height: 18),
              const TSectionHeader('معاينة الواجهة'),

              // منطقة معاينة حيّة لعناصر TBIAN
              const _PreviewArea(),
            ],
          ),
        ),
      ),
    );
  }
}

/*──────────────────── ويدجت: شارة لون مع عينة ────────────────────*/
class _ColorBadge extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color sample;
  final bool isText;

  const _ColorBadge({
    required this.icon,
    required this.label,
    required this.value,
    required this.sample,
    this.isText = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return NeuCard(
      padding: const EdgeInsets.all(14),
      child: SizedBox(
        width: 240,
        child: Row(
          children: [
            Container(
              decoration: BoxDecoration(
                color: kPrimaryColor.withValues(alpha: .10),
                borderRadius: BorderRadius.circular(14),
              ),
              padding: const EdgeInsets.all(10),
              child: Icon(icon, color: kPrimaryColor, size: 22),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: scheme.onSurface.withValues(alpha: .85),
                        fontWeight: FontWeight.w800,
                        fontSize: 14.5,
                      )),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Container(
                        width: 18,
                        height: 18,
                        margin: const EdgeInsetsDirectional.only(end: 8),
                        decoration: BoxDecoration(
                          color: isText ? scheme.surface : sample,
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(
                            color: scheme.outlineVariant,
                          ),
                        ),
                        child: isText
                            ? Center(
                                child:
                                    Icon(Icons.circle, size: 10, color: sample),
                              )
                            : null,
                      ),
                      Expanded(
                        child: Text(
                          value,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: scheme.onSurface,
                            fontWeight: FontWeight.w900,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/*──────────────────── ويدجت: منطقة المعاينة ────────────────────*/
class _PreviewArea extends StatefulWidget {
  const _PreviewArea();

  @override
  State<_PreviewArea> createState() => _PreviewAreaState();
}

class _PreviewAreaState extends State<_PreviewArea> {
  final _textCtrl = TextEditingController(text: 'قيمة تجريبية');
  bool _busy = false;

  @override
  void dispose() {
    _textCtrl.dispose();
    super.dispose();
  }

  Future<void> _fakeAction() async {
    setState(() => _busy = true);
    await Future.delayed(const Duration(milliseconds: 600));
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('تم تنفيذ العملية التجريبية.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return NeuCard(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      child: Column(
        children: [
          NeuField(
            controller: _textCtrl,
            labelText: 'حقل إدخال (معاينة)',
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TOutlinedButton(
                  icon: Icons.refresh_rounded,
                  label: 'إجراء تجريبي',
                  onPressed: _busy ? null : _fakeAction,
                ),
              ),
              const SizedBox(width: 10),
              NeuButton.primary(
                label: _busy ? 'جارٍ…' : 'زر أساسي',
                icon: Icons.check_rounded,
                onPressed: _busy ? null : _fakeAction,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
