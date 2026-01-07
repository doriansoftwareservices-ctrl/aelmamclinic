import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/models/payment_method.dart';
import 'package:aelmamclinic/models/subscription_plan.dart';
import 'package:aelmamclinic/services/billing_service.dart';
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

  final TextEditingController _referenceCtrl = TextEditingController();
  final TextEditingController _senderCtrl = TextEditingController();

  File? _proofFile;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
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
    setState(() {
      _proofFile = File(path);
    });
  }

  Future<String?> _uploadProof() async {
    if (_proofFile == null) return null;
    final filename = _proofFile!.uri.pathSegments.last;
    final res = await _storage.uploadFile(
      file: _proofFile!,
      name:
          'subscription_proof_${DateTime.now().millisecondsSinceEpoch}_$filename',
      bucketId: 'subscription-proofs',
    );
    final fileId = res['id']?.toString() ?? '';
    if (fileId.isEmpty) return null;
    return fileId;
  }

  Future<void> _submit() async {
    if (_submitting) return;
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
        referenceText: _referenceCtrl.text.trim(),
        senderName: _senderCtrl.text.trim(),
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'تعذّر إرسال الطلب: $e');
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final plan = widget.plan;
    final method = widget.method;

    return Scaffold(
      appBar: AppBar(title: const Text('بيانات الدفع')),
      body: SafeArea(
        child: Padding(
          padding: kScreenPadding,
          child: ListView(
            children: [
              NeuCard(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'الخطة المطلوبة: ${plan.name}',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'المبلغ: \$${plan.priceUsd.toStringAsFixed(0)}',
                      style: TextStyle(
                        color: scheme.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              NeuCard(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    method.logoUrl == null || method.logoUrl!.isEmpty
                        ? const Icon(Icons.account_balance_rounded, size: 36)
                        : Image.network(
                            method.logoUrl!,
                            width: 36,
                            height: 36,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) =>
                                const Icon(Icons.account_balance_rounded),
                          ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            method.name,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'رقم الحساب: ${method.bankAccount}',
                            style: TextStyle(
                              color: scheme.onSurface.withValues(alpha: 0.7),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
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
              const SizedBox(height: 12),
              NeuCard(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _proofFile == null
                            ? 'لم يتم إرفاق إثبات الدفع'
                            : _proofFile!.uri.pathSegments.last,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    NeuButton.flat(
                      label: 'إرفاق',
                      onPressed: _pickProof,
                    ),
                  ],
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: TextStyle(color: scheme.error),
                ),
              ],
              const SizedBox(height: 16),
              NeuButton.primary(
                label: _submitting ? 'جارٍ الإرسال...' : 'إرسال الطلب',
                onPressed: _submitting ? null : _submit,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
