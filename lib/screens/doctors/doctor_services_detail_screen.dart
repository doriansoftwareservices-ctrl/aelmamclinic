// lib/screens/doctors/doctor_services_detail_screen.dart
import 'dart:ui' as ui show TextDirection;
import 'package:flutter/material.dart';

import 'package:aelmamclinic/models/doctor.dart';
import 'package:aelmamclinic/services/db_service.dart';

// تصميم TBIAN
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';

class DoctorServicesDetailScreen extends StatefulWidget {
  final Doctor doctor;
  final int? serviceId; // إذا وُجد: تعديل نسب خدمة للطبيب

  const DoctorServicesDetailScreen({
    super.key,
    required this.doctor,
    this.serviceId,
  });

  @override
  State<DoctorServicesDetailScreen> createState() =>
      _DoctorServicesDetailScreenState();
}

class _DoctorServicesDetailScreenState
    extends State<DoctorServicesDetailScreen> {
  final _shareCtrl = TextEditingController();
  final _towerShareCtrl = TextEditingController();

  // بيانات للخدمة المختارة
  int? _shareRecordId; // id من service_doctor_share (إذا تعديل)
  String? _serviceName;
  double? _serviceCost;
  double? _sharePercentage;
  double? _towerSharePercentage;

  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    if (widget.serviceId != null) {
      _loadDoctorServiceShare();
    }
  }

  @override
  void dispose() {
    _shareCtrl.dispose();
    _towerShareCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadDoctorServiceShare() async {
    setState(() => _isLoading = true);
    try {
      final db = await DBService.instance.database;

      // جلب الخدمة
      final serviceRes = await db.query(
        'medical_services',
        where: 'id = ?',
        whereArgs: [widget.serviceId],
        limit: 1,
      );
      if (serviceRes.isNotEmpty) {
        final sr = serviceRes.first;
        _serviceName = sr['name'] as String;
        _serviceCost = (sr['cost'] as num).toDouble();
      }

      // جلب نسب الطبيب للخدمة
      final shareRes = await db.query(
        'service_doctor_share',
        where: 'serviceId = ? AND doctorId = ?',
        whereArgs: [widget.serviceId, widget.doctor.id],
        limit: 1,
      );
      if (shareRes.isNotEmpty) {
        final row = shareRes.first;
        _shareRecordId = row['id'] as int;
        _sharePercentage = (row['sharePercentage'] as num).toDouble();
        _towerSharePercentage =
            (row['towerSharePercentage'] as num?)?.toDouble() ?? 0.0;
      }

      _shareCtrl.text = (_sharePercentage ?? 0.0).toString();
      _towerShareCtrl.text = (_towerSharePercentage ?? 0.0).toString();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذر تحميل البيانات: $e')),
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _saveShare() async {
    var shareVal = double.tryParse(_shareCtrl.text) ?? 0.0;
    var towerVal = double.tryParse(_towerShareCtrl.text) ?? 0.0;

    if (shareVal < 0 || towerVal < 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('النسب يجب أن تكون موجبة')),
      );
      return;
    }
    if (shareVal > 100 || towerVal > 100) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('النسب يجب أن تكون بين 0 و 100')),
      );
      return;
    }
    final bothEmpty = shareVal == 0 && towerVal == 0;
    if (bothEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('يرجى إدخال نسبة الطبيب أو المركز')),
      );
      return;
    }

    if (shareVal == 0 && towerVal > 0) {
      shareVal = 100.0 - towerVal;
    } else if (towerVal == 0 && shareVal > 0) {
      towerVal = 100.0 - shareVal;
    }

    final sum = (shareVal + towerVal);
    if ((sum - 100.0).abs() > 0.01) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('مجموع نسبة الطبيب والمركز يجب أن يساوي 100%')),
      );
      return;
    }

    if (widget.serviceId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('يرجى تحديد الخدمة أولًا')),
      );
      return;
    }

    try {
      setState(() => _isLoading = true);

      if (_shareRecordId == null) {
        // إدراج جديد
        await DBService.instance.insertServiceDoctorShare(
          serviceId: widget.serviceId!,
          doctorId: widget.doctor.id!,
          sharePercentage: shareVal,
          towerSharePercentage: towerVal,
        );
      } else {
        // تحديث
        await DBService.instance.updateServiceDoctorShare(
          id: _shareRecordId!,
          sharePercentage: shareVal,
          towerSharePercentage: towerVal,
        );
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم حفظ النسب بنجاح')),
      );
      Navigator.pop(context);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('خطأ أثناء الحفظ: $e')),
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          centerTitle: true,
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset('assets/images/logo.png',
                  height: 24,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink()),
              const SizedBox(width: 8),
              Text(widget.serviceId == null
                  ? 'إضافة خدمة للطبيب'
                  : 'تعديل نسب الخدمة للطبيب'),
            ],
          ),
        ),
        body: SafeArea(
          child: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : Padding(
                  padding: kScreenPadding,
                  child: ListView(
                    children: [
                      // بطاقة العنوان
                      NeuCard(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          children: [
                            Container(
                              decoration: BoxDecoration(
                                color: kPrimaryColor.withValues(alpha: .1),
                                borderRadius: BorderRadius.circular(14),
                              ),
                              padding: const EdgeInsets.all(10),
                              child: const Icon(Icons.local_hospital_rounded,
                                  color: kPrimaryColor, size: 26),
                            ),
                            const SizedBox(width: 12),
                            const Expanded(
                              child: Text(
                                'أدخل نسب الطبيب ونسبة المركز الطبي لهذه الخدمة',
                                textAlign: TextAlign.right,
                                style: TextStyle(
                                  fontWeight: FontWeight.w900,
                                  fontSize: 18,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),

                      // معلومات الطبيب والخدمة
                      NeuCard(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 12),
                        child: Column(
                          children: [
                            _InfoTile(
                              icon: Icons.person_rounded,
                              label: 'اسم الطبيب',
                              value: widget.doctor.name,
                            ),
                            const SizedBox(height: 8),
                            _InfoTile(
                              icon: Icons.biotech_rounded,
                              label: 'الخدمة',
                              value: _serviceName ?? 'غير محدد',
                            ),
                            if (_serviceCost != null) ...[
                              const SizedBox(height: 8),
                              _InfoTile(
                                icon: Icons.attach_money_rounded,
                                label: 'تكلفة الخدمة',
                                value: _serviceCost!.toStringAsFixed(2),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),

                      // الحقول
                      NeuField(
                        controller: _shareCtrl,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        labelText: 'نسبة الطبيب (%)',
                        prefix: const Icon(Icons.percent_rounded),
                      ),
                      const SizedBox(height: 12),
                      NeuField(
                        controller: _towerShareCtrl,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        labelText: 'نسبة المركز الطبي (%)',
                        prefix: const Icon(Icons.account_balance_rounded),
                      ),

                      const SizedBox(height: 18),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: NeuButton.primary(
                          label: 'حفظ',
                          icon: Icons.save_rounded,
                          onPressed: _saveShare,
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}

class _InfoTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _InfoTile({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return Row(
      children: [
        Container(
          decoration: BoxDecoration(
            color: kPrimaryColor.withValues(alpha: .1),
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.all(8),
          child: Icon(icon, color: kPrimaryColor, size: 20),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(label,
                  style: TextStyle(
                    color: onSurface.withValues(alpha: .7),
                    fontWeight: FontWeight.w700,
                    fontSize: 12.8,
                  )),
              const SizedBox(height: 2),
              Text(
                value,
                style: const TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 14.5,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
