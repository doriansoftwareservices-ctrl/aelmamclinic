// lib/screens/settings/tower_commission_settings_screen.dart
import 'dart:ui' as ui show TextDirection;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/*── تصميم TBIAN ─*/
import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/tbian_ui.dart';

class TowerCommissionSettingsScreen extends StatefulWidget {
  const TowerCommissionSettingsScreen({super.key});

  @override
  State<TowerCommissionSettingsScreen> createState() =>
      _TowerCommissionSettingsScreenState();
}

class _TowerCommissionSettingsScreenState
    extends State<TowerCommissionSettingsScreen> {
  final TextEditingController _radiologyController = TextEditingController();
  final TextEditingController _labController = TextEditingController();
  final TextEditingController _doctorGeneralController =
      TextEditingController();

  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  @override
  void dispose() {
    _radiologyController.dispose();
    _labController.dispose();
    _doctorGeneralController.dispose();
    super.dispose();
  }

  /*────────────────── تحميل الإعدادات ──────────────────*/
  Future<void> _loadSettings() async {
    setState(() => _busy = true);
    final prefs = await SharedPreferences.getInstance();

    final r = prefs.getDouble('tower_commission_radiology') ?? 0.0;
    final l = prefs.getDouble('tower_commission_lab') ?? 0.0;
    final d = prefs.getDouble('tower_commission_doctorGeneral') ?? 0.0;

    _radiologyController.text = _fmt(r);
    _labController.text = _fmt(l);
    _doctorGeneralController.text = _fmt(d);

    if (mounted) setState(() => _busy = false);
  }

  /*────────────────── حفظ الإعدادات ──────────────────*/
  Future<void> _saveSettings() async {
    final r = _parsePercent(_radiologyController.text);
    final l = _parsePercent(_labController.text);
    final d = _parsePercent(_doctorGeneralController.text);

    String? err;
    if (r == null || l == null || d == null) {
      err = 'الرجاء إدخال قيم رقمية صحيحة بكل الحقول (0–100).';
    } else if (!_inRange(r) || !_inRange(l) || !_inRange(d)) {
      err = 'القيم يجب أن تكون بين 0 و 100.';
    }

    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
      return;
    }

    setState(() => _busy = true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('tower_commission_radiology', r!);
    await prefs.setDouble('tower_commission_lab', l!);
    await prefs.setDouble('tower_commission_doctorGeneral', d!);
    if (!mounted) return;

    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('تم حفظ إعدادات نسبة المركز الطبي بنجاح')),
    );
  }

  /*────────────────── أدوات ──────────────────*/
  double? _parsePercent(String s) {
    final v = double.tryParse(s.replaceAll(',', '.').trim());
    return v;
  }

  bool _inRange(double v) => v >= 0 && v <= 100;

  String _fmt(double v) => v.toStringAsFixed(
        v == v.truncateToDouble() ? 0 : (v * 10 % 1 == 0 ? 1 : 2),
      );

  void _applyPreset(TextEditingController c, double v) {
    setState(() => c.text = _fmt(v));
  }

  Widget _presetChips(TextEditingController c) {
    final presets = <double>[0, 5, 10, 15, 20, 25, 30, 40, 50];
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: presets
          .map((p) => OutlinedButton(
                onPressed: () => _applyPreset(c, p),
                style: OutlinedButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  side: BorderSide(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                ),
                child: Text('${_fmt(p)}%'),
              ))
          .toList(),
    );
  }

  @override
  Widget build(BuildContext context) {
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
          child: Stack(
            children: [
              ListView(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 120),
                children: [
                  const TSectionHeader('إعدادات نسبة المركز الطبي'),
                  NeuCard(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _FieldWithSuffix(
                          label: 'نسبة المركز الطبي للأشعة (%)',
                          controller: _radiologyController,
                        ),
                        const SizedBox(height: 8),
                        _presetChips(_radiologyController),
                        const SizedBox(height: 16),
                        _FieldWithSuffix(
                          label: 'نسبة المركز الطبي للمختبر (%)',
                          controller: _labController,
                        ),
                        const SizedBox(height: 8),
                        _presetChips(_labController),
                        const SizedBox(height: 16),
                        _FieldWithSuffix(
                          label: 'نسبة المركز الطبي للخدمات العامة للطبيب (%)',
                          controller: _doctorGeneralController,
                        ),
                        const SizedBox(height: 8),
                        _presetChips(_doctorGeneralController),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  const TSectionHeader('لمحة سريعة'),
                  Wrap(
                    spacing: 16,
                    runSpacing: 18,
                    children: [
                      TInfoCard(
                        icon: Icons.biotech_outlined,
                        label: 'أشعة',
                        value:
                            '${_radiologyController.text.isEmpty ? '0' : _radiologyController.text}%',
                      ),
                      TInfoCard(
                        icon: Icons.science_outlined,
                        label: 'مختبر',
                        value:
                            '${_labController.text.isEmpty ? '0' : _labController.text}%',
                      ),
                      TInfoCard(
                        icon: Icons.local_hospital_outlined,
                        label: 'طبيب (عام)',
                        value:
                            '${_doctorGeneralController.text.isEmpty ? '0' : _doctorGeneralController.text}%',
                      ),
                    ],
                  ),
                ],
              ),

              // حجاب انشغال خفيف عند التحميل/الحفظ
              if (_busy)
                Positioned.fill(
                  child: Container(
                    color: scheme.scrim.withValues(alpha: .08),
                    child: const Center(child: CircularProgressIndicator()),
                  ),
                ),

              // شريط سفلي ثابت للإجراءات
              Align(
                alignment: Alignment.bottomCenter,
                child: NeuCard(
                  margin: EdgeInsets.zero,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: SafeArea(
                    top: false,
                    child: Row(
                      children: [
                        Expanded(
                          child: TOutlinedButton(
                            icon: Icons.refresh_rounded,
                            label: 'إعادة الضبط',
                            onPressed: _busy
                                ? null
                                : () {
                                    setState(() {
                                      _radiologyController.text = '0';
                                      _labController.text = '0';
                                      _doctorGeneralController.text = '0';
                                    });
                                  },
                          ),
                        ),
                        const SizedBox(width: 10),
                        NeuButton.primary(
                          label: _busy ? 'جارٍ…' : 'حفظ الإعدادات',
                          icon: Icons.save_rounded,
                          onPressed: _busy ? null : _saveSettings,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/*──────────────────── ويدجت: حقل نسبة مع لاحقة % بنمط TBIAN ────────────────────*/
class _FieldWithSuffix extends StatelessWidget {
  final String label;
  final TextEditingController controller;

  const _FieldWithSuffix({
    required this.label,
    required this.controller,
  });

  @override
  Widget build(BuildContext context) {
    final onSurface =
        Theme.of(context).colorScheme.onSurface.withValues(alpha: .65);
    return NeuField(
      controller: controller,
      labelText: label,
      keyboardType:
          const TextInputType.numberWithOptions(decimal: true, signed: false),
      suffix: Padding(
        padding: const EdgeInsetsDirectional.only(end: 8),
        child: Text('%',
            style: TextStyle(fontWeight: FontWeight.w800, color: onSurface)),
      ),
    );
  }
}
