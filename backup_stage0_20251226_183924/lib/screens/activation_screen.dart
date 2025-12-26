// File: lib/screens/activation_screen.dart
import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui show TextDirection;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

/*── تصميم TBIAN ─*/
import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/tbian_ui.dart';

import 'package:aelmamclinic/providers/activation_provider.dart';
import 'statistics/statistics_overview_screen.dart';

class ActivationScreen extends StatefulWidget {
  const ActivationScreen({super.key});

  @override
  State<ActivationScreen> createState() => _ActivationScreenState();
}

class _ActivationScreenState extends State<ActivationScreen> {
  String serialCode = '';
  final TextEditingController codeController = TextEditingController();

  // مفتاح ثابت للمطابقة مع أداة الإدارة
  static const String _secretKey = "Iy0iTR&MCGbF98j";

  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadOrGenerateSerial();
  }

  @override
  void dispose() {
    codeController.dispose();
    super.dispose();
  }

  /*────────────────── توليد/تحميل السيريال ──────────────────*/
  Future<void> _loadOrGenerateSerial() async {
    final prefs = await SharedPreferences.getInstance();
    String? savedSerial = prefs.getString('storedSerialCode');

    if (savedSerial == null || savedSerial.isEmpty) {
      savedSerial = _generateSerialCode();
      await prefs.setString('storedSerialCode', savedSerial);
    }

    if (!mounted) return;
    setState(() => serialCode = savedSerial!);
  }

  String _generateSerialCode() {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789@%!&';
    final rnd = Random.secure();
    return String.fromCharCodes(
      List.generate(15, (_) => chars.codeUnitAt(rnd.nextInt(chars.length))),
    );
  }

  String _generateActivationCode(String serial, int days) {
    final key = utf8.encode(_secretKey);
    final data = '$serial-$days';
    final hmac = Hmac(sha256, key);
    final digest = hmac.convert(utf8.encode(data));

    // استخدام أول 8 بايت كـ seed 64-بت
    final seed =
        digest.bytes.sublist(0, 8).fold<int>(0, (prev, b) => (prev << 8) | b);
    final rnd = Random(seed);

    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789@%!&';
    return String.fromCharCodes(
      List.generate(15, (_) => chars.codeUnitAt(rnd.nextInt(chars.length))),
    );
  }

  /*────────────────── إجراءات السيريال ──────────────────*/
  Future<void> _copyCode() async {
    await Clipboard.setData(ClipboardData(text: serialCode));
    Fluttertoast.showToast(msg: "تم نسخ السيريال بنجاح");
  }

  Future<void> _pasteCode() async {
    final data = await Clipboard.getData('text/plain');
    final txt = (data?.text ?? '').trim();
    if (txt.isEmpty) {
      Fluttertoast.showToast(msg: "لا يوجد نص في الحافظة");
      return;
    }
    setState(() => codeController.text = txt);
    Fluttertoast.showToast(msg: "تم اللصق");
  }

  Future<void> _shareCode() async {
    await SharePlus.instance.share(
      ShareParams(
        text: 'السيريال الخاص بي: $serialCode',
      ),
    );
  }

  Future<void> _refreshSerialCode() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('تحديث السيريال'),
        content: const Text(
            'سيتم إنشاء سيريال جديد، ولن تعمل أكواد التفعيل المرتبطة بالسيريال السابق.\nهل تريد المتابعة؟'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('إلغاء')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('تأكيد')),
        ],
      ),
    );
    if (ok != true) return;

    setState(() => _isLoading = true);

    final prefs = await SharedPreferences.getInstance();
    final newSerial = _generateSerialCode();
    await prefs.setString('storedSerialCode', newSerial);

    if (!mounted) return;
    setState(() {
      serialCode = newSerial;
      _isLoading = false;
    });

    Fluttertoast.showToast(msg: "تم تحديث السيريال");
  }

  /*────────────────── التفعيل ──────────────────*/
  Future<bool> _isCodeUsed(String code) async {
    final prefs = await SharedPreferences.getInstance();
    final usedCodes = prefs.getStringList('used_codes') ?? [];
    return usedCodes.contains(code);
  }

  Future<void> _activateApp() async {
    setState(() => _isLoading = true);
    final entered = codeController.text.trim();

    if (entered.isEmpty) {
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('الرجاء إدخال رمز التفعيل')),
      );
      return;
    }

    if (await _isCodeUsed(entered)) {
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('تم استخدام هذا الرمز مسبقاً'),
          backgroundColor: Colors.red,
          duration: Duration(seconds: 3),
        ),
      );
      return;
    }

    int? matchedDays;
    for (int i = 1; i <= 730; i++) {
      if (entered == _generateActivationCode(serialCode, i)) {
        matchedDays = i;
        break;
      }
    }

    if (matchedDays != null) {
      final prefs = await SharedPreferences.getInstance();
      final usedCodes = prefs.getStringList('used_codes') ?? [];
      usedCodes.add(entered);
      await prefs.setStringList('used_codes', usedCodes);

      await Provider.of<ActivationProvider>(context, listen: false)
          .activate(matchedDays);

      if (!mounted) return;
      setState(() => _isLoading = false);

      // انتقال للوحة الإحصاءات بعد نجاح التفعيل
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const StatisticsOverviewScreen()),
      );
    } else {
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('رمز التفعيل غير صالح'),
          backgroundColor: Colors.red,
          duration: Duration(seconds: 3),
        ),
      );
    }
  }

  /*────────────────── تواصل ──────────────────*/
  Future<void> _makePhoneCall() async {
    final uri = Uri.parse("tel:780696069");
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else {
      Fluttertoast.showToast(msg: "تعذر إجراء المكالمة.");
    }
  }

  Future<void> _launchWhatsApp() async {
    final uri = Uri.parse("https://wa.me/967730696069");
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      Fluttertoast.showToast(msg: "تعذر فتح الواتساب.");
    }
  }

  /*────────────────── الواجهة ──────────────────*/
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
          actions: [
            IconButton(
              tooltip: 'مشاركة السيريال',
              icon: const Icon(Icons.share_rounded),
              onPressed: _shareCode,
            ),
          ],
        ),
        body: SafeArea(
          child: Stack(
            children: [
              ListView(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 120),
                children: [
                  const TSectionHeader('رمز الجهاز (Serial)'),

                  // عرض السيريال
                  NeuCard(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'السيريال الخاص بك',
                          style: TextStyle(
                            color: scheme.onSurface.withValues(alpha: .85),
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Container(
                          decoration: BoxDecoration(
                            color: scheme.surfaceContainerHigh,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: scheme.outlineVariant),
                          ),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 14),
                          child: SelectableText(
                            serialCode,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: TOutlinedButton(
                                icon: Icons.copy_rounded,
                                label: 'نسخ',
                                onPressed: _copyCode,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: NeuButton.flat(
                                icon: Icons.refresh_rounded,
                                label: 'تحديث السيريال',
                                onPressed:
                                    _isLoading ? null : _refreshSerialCode,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 18),
                  const TSectionHeader('تفعيل التطبيق'),

                  // إدخال رمز التفعيل
                  NeuCard(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                    child: Column(
                      children: [
                        NeuField(
                          controller: codeController,
                          labelText: 'أدخل رمز التفعيل',
                          prefix: const Icon(Icons.lock_outline_rounded),
                          textAlign: TextAlign.center,
                          textDirection: TextDirection.ltr,
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: TOutlinedButton(
                                icon: Icons.paste_rounded,
                                label: 'لصق',
                                onPressed: _pasteCode,
                              ),
                            ),
                            const SizedBox(width: 10),
                            NeuButton.primary(
                              icon: _isLoading
                                  ? Icons.hourglass_top_rounded
                                  : Icons.check_circle_rounded,
                              label: _isLoading ? 'جارٍ التفعيل…' : 'تفعيل',
                              onPressed: _isLoading ? null : _activateApp,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 18),
                  const TSectionHeader('معلومات'),

                  NeuCard(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: const [
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.info_outline_rounded),
                          title: Text(
                              'للحصول على الباقة المجانية أو لتجديد باقتك'),
                          subtitle: Text('تواصل معنا وسنسعد بخدمتكم.'),
                        ),
                        SizedBox(height: 8),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.warning_amber_rounded,
                              color: Colors.red),
                          title: Text(
                            'لا يمكن استخدام نفس رمز التفعيل أكثر من مرة',
                            style: TextStyle(fontWeight: FontWeight.w800),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),

              // طبقة انشغال لطيفة أثناء العمليات
              if (_isLoading)
                Positioned.fill(
                  child: Container(
                    color: scheme.scrim.withValues(alpha: .06),
                    child: const Center(child: CircularProgressIndicator()),
                  ),
                ),

              // شريط سفلي ثابت للتواصل السريع
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
                            icon: Icons.phone_rounded,
                            label: 'اتصال',
                            onPressed: _makePhoneCall,
                          ),
                        ),
                        const SizedBox(width: 10),
                        NeuButton.flat(
                          icon: FontAwesomeIcons.whatsapp,
                          label: 'واتساب',
                          onPressed: _launchWhatsApp,
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
