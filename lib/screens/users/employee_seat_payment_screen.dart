import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/models/payment_method.dart';
import 'package:aelmamclinic/services/billing_service.dart';
import 'package:aelmamclinic/services/employee_seat_service.dart';
import 'package:aelmamclinic/services/nhost_storage_service.dart';

class EmployeeSeatPaymentScreen extends StatefulWidget {
  const EmployeeSeatPaymentScreen({
    super.key,
    required this.requestId,
    required this.employeeEmail,
  });

  final String requestId;
  final String employeeEmail;

  @override
  State<EmployeeSeatPaymentScreen> createState() =>
      _EmployeeSeatPaymentScreenState();
}

class _EmployeeSeatPaymentScreenState extends State<EmployeeSeatPaymentScreen> {
  final BillingService _billing = BillingService();
  final EmployeeSeatService _seatService = EmployeeSeatService();
  final NhostStorageService _storage = NhostStorageService();

  List<PaymentMethod> _methods = const [];
  PaymentMethod? _selected;
  File? _proofFile;
  bool _loading = true;
  bool _submitting = false;
  String? _error;

  static const int _priceUsd = 25;

  @override
  void initState() {
    super.initState();
    _loadMethods();
  }

  @override
  void dispose() {
    _storage.dispose();
    _seatService.dispose();
    super.dispose();
  }

  Future<void> _loadMethods() async {
    setState(() => _loading = true);
    try {
      final methods = await _billing.fetchPaymentMethods();
      if (!mounted) return;
      setState(() {
        _methods = methods;
        _selected = _methods.isNotEmpty ? _methods.first : null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'تعذّر تحميل وسائل الدفع: $e');
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
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
          'employee_seat_proof_${DateTime.now().millisecondsSinceEpoch}_$filename',
      bucketId: 'subscription-proofs',
    );
    final fileId = res['id']?.toString() ?? '';
    if (fileId.isEmpty) return null;
    return fileId;
  }

  Future<void> _submit() async {
    if (_submitting) return;
    if (_selected == null) {
      setState(() => _error = 'يرجى اختيار وسيلة دفع.');
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
      await _seatService.submitSeatPayment(
        requestId: widget.requestId,
        paymentMethodId: _selected!.id,
        receiptFileId: proofId,
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

  Widget _buildMethodTile(PaymentMethod method, ColorScheme scheme) {
    final selected = _selected?.id == method.id;
    return NeuCard(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => setState(() => _selected = method),
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
            Icon(
              selected ? Icons.check_circle : Icons.radio_button_off,
              color: selected ? scheme.primary : scheme.outline,
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('دفع رسوم المقعد الإضافي')),
      body: SafeArea(
        child: Padding(
          padding: kScreenPadding,
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  children: [
                    NeuCard(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'تفاصيل الطلب',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 6),
                          Text('الموظف: ${widget.employeeEmail}'),
                          const SizedBox(height: 6),
                          Text(
                            'المبلغ المطلوب: \$$_priceUsd',
                            style: TextStyle(
                              color: scheme.primary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (_methods.isEmpty)
                      NeuCard(
                        padding: const EdgeInsets.all(14),
                        child: Text(
                          'لا توجد وسائل دفع متاحة حاليًا.',
                          style: TextStyle(
                              color: scheme.onSurface.withValues(alpha: 0.7)),
                        ),
                      )
                    else
                      ..._methods.map((m) => Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: _buildMethodTile(m, scheme),
                          )),
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
