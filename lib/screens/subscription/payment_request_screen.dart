import 'dart:io';
import 'dart:ui';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/models/payment_method.dart';
import 'package:aelmamclinic/models/subscription_plan.dart';
import 'package:aelmamclinic/services/billing_service.dart';
import 'package:aelmamclinic/services/clinic_profile_service.dart';
import 'package:aelmamclinic/services/nhost_storage_service.dart';

class PaymentRequestScreen extends StatefulWidget {
  const PaymentRequestScreen({
    super.key,
    required this.plan,
    required this.method,
  });

  final SubscriptionPlan plan;
  final PaymentMethod method;

  @override
  State<PaymentRequestScreen> createState() => _PaymentRequestScreenState();
}

class _PaymentRequestScreenState extends State<PaymentRequestScreen> {
  final BillingService _billing = BillingService();
  final NhostStorageService _storage = NhostStorageService();

  final TextEditingController _clinicNameCtrl = TextEditingController();
  final TextEditingController _referenceCtrl = TextEditingController();
  final TextEditingController _senderCtrl = TextEditingController();

  File? _proofFile;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _prefillClinicName();
  }

  Future<void> _prefillClinicName() async {
    try {
      final profile = await ClinicProfileService.loadActiveOrFallback();
      if (!mounted) return;
      if (_clinicNameCtrl.text.trim().isEmpty && profile.nameAr.trim().isNotEmpty) {
        _clinicNameCtrl.text = profile.nameAr.trim();
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _clinicNameCtrl.dispose();
    _referenceCtrl.dispose();
    _senderCtrl.dispose();
    _storage.dispose();
    super.dispose();
  }

  Future<void> _pickProof() async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: false);
    if (result == null || result.files.isEmpty) return;
    final path = result.files.first.path;
    if (path == null || path.isEmpty) return;
    setState(() => _proofFile = File(path));
  }

  Future<String?> _uploadProof() async {
    if (_proofFile == null) return null;
    final filename = _proofFile!.uri.pathSegments.last;
    final res = await _storage.uploadFile(
      file: _proofFile!,
      name: 'subscription_proof_${DateTime.now().millisecondsSinceEpoch}_$filename',
      bucketId: 'subscription-proofs',
    );
    final fileId = res['id']?.toString() ?? '';
    if (fileId.isEmpty) return null;
    return fileId;
  }

  Future<void> _submit() async {
    if (_submitting) return;

    if (_clinicNameCtrl.text.trim().isEmpty) {
      setState(() => _error = 'يرجى إدخال اسم العيادة أولًا.');
      return;
    }
    if (_proofFile == null) {
      setState(() => _error = 'يرجى إرفاق إثبات الدفع أولًا.');
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });

    try {
      final proofId = await _uploadProof();
      if (proofId == null || proofId.isEmpty) {
        throw Exception('تعذّر رفع الإثبات');
      }

      await _billing.createSubscriptionRequest(
        planCode: widget.plan.code,
        paymentMethodId: widget.method.id,
        proofUrl: proofId,
        clinicName: _clinicNameCtrl.text.trim(),
        referenceText: _referenceCtrl.text.trim(),
        senderName: _senderCtrl.text.trim(),
      );

      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _mapSubmitError(e));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  String _mapSubmitError(Object error) {
    final msg = error.toString().toLowerCase();
    if (msg.contains('forbidden')) return 'لا تملك صلاحية إرسال طلب الترقية.';
    if (msg.contains('plan not found') || msg.contains('invalid plan')) return 'الخطة غير متاحة حالياً.';
    if (msg.contains('payment_method is required')) return 'يرجى اختيار وسيلة الدفع.';
    if (msg.contains('account not found')) return 'تعذّر تحديد حساب المرفق الصحي.';
    if (msg.contains('not authenticated')) return 'يرجى تسجيل الدخول مرة أخرى.';
    return 'تعذّر إرسال الطلب: $error';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final plan = widget.plan;
    final method = widget.method;

    final price = '\$${plan.priceUsd.toStringAsFixed(0)}';
    final proofLabel = _proofFile == null ? 'لم يتم إرفاق إثبات الدفع' : _proofFile!.uri.pathSegments.last;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('بيانات الدفع'),
          centerTitle: false,
        ),
        body: Stack(
          children: [
            _Backdrop(scheme: scheme),
            SafeArea(
              child: Padding(
                padding: kScreenPadding,
                child: ListView(
                  children: [
                    _HeaderCard(
                      planName: plan.name,
                      price: price,
                      scheme: scheme,
                    ),
                    const SizedBox(height: 12),
                    _MethodCard(method: method),
                    const SizedBox(height: 12),

                    _SectionTitle(
                      title: 'معلومات التحويل',
                      subtitle: 'املأ البيانات ثم أرفق إثبات الدفع لإرسال الطلب.',
                    ),
                    const SizedBox(height: 10),

                    NeuField(
                      controller: _clinicNameCtrl,
                      labelText: 'اسم العيادة',
                      prefix: const Icon(Icons.local_hospital_outlined),
                    ),
                    const SizedBox(height: 10),
                    NeuField(
                      controller: _referenceCtrl,
                      labelText: 'رقم العملية / مرجع التحويل',
                      prefix: const Icon(Icons.confirmation_number_outlined),
                    ),
                    const SizedBox(height: 10),
                    NeuField(
                      controller: _senderCtrl,
                      labelText: 'اسم المحوّل (اختياري)',
                      prefix: const Icon(Icons.person_outline),
                    ),

                    const SizedBox(height: 14),

                    _AttachmentCard(
                      label: proofLabel,
                      hasFile: _proofFile != null,
                      onPick: _pickProof,
                      onClear: _proofFile == null
                          ? null
                          : () => setState(() => _proofFile = null),
                    ),

                    if (_error != null) ...[
                      const SizedBox(height: 10),
                      _ErrorBanner(text: _error!),
                    ],

                    const SizedBox(height: 16),

                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _submitting ? null : _submit,
                        icon: _submitting
                            ? SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.4,
                                  color: scheme.onPrimary,
                                ),
                              )
                            : const Icon(Icons.send_rounded),
                        label: Text(
                          _submitting ? 'جارٍ الإرسال...' : 'إرسال الطلب',
                          style: const TextStyle(fontWeight: FontWeight.w900),
                        ),
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(height: 12),

                    Text(
                      'عند إرسال الطلب سيتم مراجعته واعتماده من الإدارة.',
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.25,
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurface.withValues(alpha: 0.62),
                      ),
                    ),

                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Backdrop extends StatelessWidget {
  const _Backdrop({required this.scheme});
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              scheme.surface,
              scheme.surfaceContainerHighest.withValues(alpha: 0.55),
              scheme.surface,
            ],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: Stack(
          children: [
            Positioned(
              top: -90,
              right: -70,
              child: _BlurBlob(
                size: 240,
                color: scheme.primary.withValues(alpha: 0.20),
              ),
            ),
            Positioned(
              bottom: -90,
              left: -70,
              child: _BlurBlob(
                size: 260,
                color: scheme.tertiary.withValues(alpha: 0.16),
              ),
            ),
            Positioned(
              top: 200,
              left: 30,
              child: _BlurBlob(
                size: 170,
                color: scheme.secondary.withValues(alpha: 0.12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BlurBlob extends StatelessWidget {
  const _BlurBlob({required this.size, required this.color});
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ClipOval(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 26, sigmaY: 26),
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
        ),
      ),
    );
  }
}

class _HeaderCard extends StatelessWidget {
  const _HeaderCard({
    required this.planName,
    required this.price,
    required this.scheme,
  });

  final String planName;
  final String price;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        color: scheme.surface.withValues(alpha: 0.86),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.55)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 18,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              gradient: LinearGradient(
                colors: [
                  scheme.primary.withValues(alpha: 0.20),
                  scheme.secondary.withValues(alpha: 0.12),
                ],
                begin: Alignment.topRight,
                end: Alignment.bottomLeft,
              ),
              border: Border.all(color: scheme.primary.withValues(alpha: 0.22)),
            ),
            child: Icon(Icons.workspace_premium_rounded, color: scheme.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'الخطة المطلوبة',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                    color: scheme.onSurface.withValues(alpha: 0.65),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  planName,
                  style: TextStyle(
                    fontSize: 16.5,
                    fontWeight: FontWeight.w900,
                    color: scheme.onSurface,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              color: scheme.primary.withValues(alpha: 0.10),
              border: Border.all(color: scheme.primary.withValues(alpha: 0.18)),
            ),
            child: Text(
              price,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w900,
                color: scheme.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MethodCard extends StatelessWidget {
  const _MethodCard({required this.method});
  final PaymentMethod method;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    final hasLogo = method.logoUrl != null && method.logoUrl!.isNotEmpty;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        color: scheme.surface.withValues(alpha: 0.86),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.55)),
      ),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.75),
              border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.45)),
            ),
            child: hasLogo
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Image.network(
                      method.logoUrl!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Icon(
                        Icons.account_balance_rounded,
                        color: scheme.primary,
                      ),
                    ),
                  )
                : Icon(Icons.account_balance_rounded, color: scheme.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'وسيلة الدفع',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                    color: scheme.onSurface.withValues(alpha: 0.65),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  method.name,
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'رقم الحساب: ${method.bankAccount}',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface.withValues(alpha: 0.70),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, required this.subtitle});
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 16.5,
            fontWeight: FontWeight.w900,
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          subtitle,
          style: TextStyle(
            fontSize: 12.5,
            height: 1.25,
            fontWeight: FontWeight.w700,
            color: scheme.onSurface.withValues(alpha: 0.62),
          ),
        ),
      ],
    );
  }
}

class _AttachmentCard extends StatelessWidget {
  const _AttachmentCard({
    required this.label,
    required this.hasFile,
    required this.onPick,
    required this.onClear,
  });

  final String label;
  final bool hasFile;
  final VoidCallback onPick;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = hasFile ? scheme.primary : scheme.secondary;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        color: scheme.surface.withValues(alpha: 0.86),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.55)),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color: accent.withValues(alpha: 0.12),
              border: Border.all(color: accent.withValues(alpha: 0.20)),
            ),
            child: Icon(
              hasFile ? Icons.verified_rounded : Icons.attach_file_rounded,
              color: accent,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: scheme.onSurface.withValues(alpha: hasFile ? 0.85 : 0.72),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // ✅ أبقينا NeuButton حتى لا نغير منطق/مكتبات، لكن بترتيب حديث داخل الكرت
              NeuButton.flat(
                label: hasFile ? 'تغيير' : 'إرفاق',
                onPressed: onPick,
              ),
              if (onClear != null) ...[
                const SizedBox(width: 8),
                IconButton(
                  onPressed: onClear,
                  tooltip: 'إزالة',
                  icon: Icon(Icons.close_rounded, color: scheme.error),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: scheme.errorContainer.withValues(alpha: 0.55),
        border: Border.all(color: scheme.error.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded, color: scheme.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: scheme.onErrorContainer,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
