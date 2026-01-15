import 'dart:ui' as ui show TextDirection;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/models/clinic_profile.dart';
import 'package:aelmamclinic/providers/auth_provider.dart';
import 'package:aelmamclinic/services/clinic_profile_service.dart';
import 'package:aelmamclinic/services/db_service.dart';

class ClinicProfileScreen extends StatefulWidget {
  const ClinicProfileScreen({super.key});

  @override
  State<ClinicProfileScreen> createState() => _ClinicProfileScreenState();
}

class _ClinicProfileScreenState extends State<ClinicProfileScreen> {
  final _formKey = GlobalKey<FormState>();

  final _nameArCtrl = TextEditingController();
  final _cityArCtrl = TextEditingController();
  final _streetArCtrl = TextEditingController();
  final _nearArCtrl = TextEditingController();
  final _nameEnCtrl = TextEditingController();
  final _cityEnCtrl = TextEditingController();
  final _streetEnCtrl = TextEditingController();
  final _nearEnCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();

  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  @override
  void dispose() {
    _nameArCtrl.dispose();
    _cityArCtrl.dispose();
    _streetArCtrl.dispose();
    _nearArCtrl.dispose();
    _nameEnCtrl.dispose();
    _cityEnCtrl.dispose();
    _streetEnCtrl.dispose();
    _nearEnCtrl.dispose();
    _phoneCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadProfile() async {
    final auth = context.read<AuthProvider>();
    final accountId = auth.accountId;
    if (accountId == null || accountId.trim().isEmpty) {
      _applyProfile(null);
      setState(() => _loading = false);
      return;
    }
    try {
      final profile = await DBService.instance.getClinicProfile(accountId);
      _applyProfile(profile);
    } catch (_) {
      _applyProfile(null);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _applyProfile(ClinicProfile? profile) {
    final p = profile;
    _nameArCtrl.text = p?.nameAr ?? '';
    _cityArCtrl.text = p?.cityAr ?? '';
    _streetArCtrl.text = p?.streetAr ?? '';
    _nearArCtrl.text = p?.nearAr ?? '';
    _nameEnCtrl.text = p?.nameEn ?? '';
    _cityEnCtrl.text = p?.cityEn ?? '';
    _streetEnCtrl.text = p?.streetEn ?? '';
    _nearEnCtrl.text = p?.nearEn ?? '';
    _phoneCtrl.text = p?.phone ?? '';
  }

  String? _req(String? v) =>
      v == null || v.trim().isEmpty ? 'هذا الحقل مطلوب' : null;

  Future<void> _save(AuthProvider auth) async {
    if (_saving) return;
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final profile = ClinicProfileInput(
        nameAr: _nameArCtrl.text.trim(),
        cityAr: _cityArCtrl.text.trim(),
        streetAr: _streetArCtrl.text.trim(),
        nearAr: _nearArCtrl.text.trim(),
        nameEn: _nameEnCtrl.text.trim(),
        cityEn: _cityEnCtrl.text.trim(),
        streetEn: _streetEnCtrl.text.trim(),
        nearEn: _nearEnCtrl.text.trim(),
        phone: _phoneCtrl.text.trim(),
      );
      await auth.updateClinicProfile(profile);
      await auth.refreshAndValidateCurrentUser();
      final cached = await ClinicProfileService.isProfileComplete();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            cached ? 'تم حفظ بيانات المرفق الصحي.' : 'تم الحفظ، تحقق من البيانات.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذّر الحفظ: $e')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final canEdit = auth.isSuperAdmin ? false : auth.isOwnerOrAdmin;
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
              const Text('بيانات المرفق الصحي'),
            ],
          ),
        ),
        body: SafeArea(
          child: Padding(
            padding: kScreenPadding,
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : Form(
                    key: _formKey,
                    child: ListView(
                      children: [
                        NeuCard(
                          padding: const EdgeInsets.all(14),
                          child: const Text(
                            'حدّث بيانات المرفق الصحي لتظهر في كل تقارير PDF.',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        const SizedBox(height: 12),
                        _sectionTitle('البيانات العربية'),
                        const SizedBox(height: 8),
                        NeuField(
                          controller: _nameArCtrl,
                          labelText: 'اسم المرفق الصحي',
                          validator: _req,
                          enabled: canEdit,
                        ),
                        const SizedBox(height: 8),
                        NeuField(
                          controller: _cityArCtrl,
                          labelText: 'المدينة',
                          validator: _req,
                          enabled: canEdit,
                        ),
                        const SizedBox(height: 8),
                        NeuField(
                          controller: _streetArCtrl,
                          labelText: 'الشارع',
                          validator: _req,
                          enabled: canEdit,
                        ),
                        const SizedBox(height: 8),
                        NeuField(
                          controller: _nearArCtrl,
                          labelText: 'بجوار',
                          validator: _req,
                          enabled: canEdit,
                        ),
                        const SizedBox(height: 16),
                        _sectionTitle('English Details'),
                        const SizedBox(height: 8),
                        NeuField(
                          controller: _nameEnCtrl,
                          labelText: 'Clinic name',
                          validator: _req,
                          textDirection: ui.TextDirection.ltr,
                          enabled: canEdit,
                        ),
                        const SizedBox(height: 8),
                        NeuField(
                          controller: _cityEnCtrl,
                          labelText: 'City',
                          validator: _req,
                          textDirection: ui.TextDirection.ltr,
                          enabled: canEdit,
                        ),
                        const SizedBox(height: 8),
                        NeuField(
                          controller: _streetEnCtrl,
                          labelText: 'Street',
                          validator: _req,
                          textDirection: ui.TextDirection.ltr,
                          enabled: canEdit,
                        ),
                        const SizedBox(height: 8),
                        NeuField(
                          controller: _nearEnCtrl,
                          labelText: 'Near',
                          validator: _req,
                          textDirection: ui.TextDirection.ltr,
                          enabled: canEdit,
                        ),
                        const SizedBox(height: 16),
                        _sectionTitle('الهاتف'),
                        const SizedBox(height: 8),
                        NeuField(
                          controller: _phoneCtrl,
                          labelText: 'رقم الهاتف',
                          validator: _req,
                          keyboardType: TextInputType.phone,
                          enabled: canEdit,
                        ),
                        const SizedBox(height: 16),
                        if (!canEdit)
                          const Text(
                            'التعديل متاح للمالك أو المدير فقط.',
                            style: TextStyle(color: Colors.redAccent),
                          ),
                        const SizedBox(height: 8),
                        NeuButton.primary(
                          label: _saving ? 'جارٍ الحفظ...' : 'حفظ التعديلات',
                          onPressed: canEdit && !_saving
                              ? () => _save(auth)
                              : null,
                          icon: Icons.save_rounded,
                        ),
                      ],
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  Widget _sectionTitle(String title) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 14.5),
        ),
      );
}
