import 'dart:io';
import 'dart:ui' as ui show TextDirection;

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import 'package:aelmamclinic/core/features.dart';
import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/models/clinic_profile.dart';
import 'package:aelmamclinic/providers/auth_provider.dart';
import 'package:aelmamclinic/services/clinic_profile_service.dart';
import 'package:aelmamclinic/services/db_service.dart';
import 'package:aelmamclinic/widgets/localized_text.dart';
import 'package:aelmamclinic/utils/l10n_extensions.dart';

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
  final _phone2Ctrl = TextEditingController();

  String? _logoPath;
  bool _logoBusy = false;
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
    _phone2Ctrl.dispose();
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
    final profileData = profile;
    _nameArCtrl.text = profileData?.nameAr ?? '';
    _cityArCtrl.text = profileData?.cityAr ?? '';
    _streetArCtrl.text = profileData?.streetAr ?? '';
    _nearArCtrl.text = profileData?.nearAr ?? '';
    _nameEnCtrl.text = profileData?.nameEn ?? '';
    _cityEnCtrl.text = profileData?.cityEn ?? '';
    _streetEnCtrl.text = profileData?.streetEn ?? '';
    _nearEnCtrl.text = profileData?.nearEn ?? '';
    _phoneCtrl.text = profileData?.phone ?? '';
    _phone2Ctrl.text = profileData?.phone2 ?? '';
    final logo = profileData?.logoPath?.trim() ?? '';
    _logoPath = (logo.isNotEmpty && File(logo).existsSync()) ? logo : null;
  }

  String? _req(String? v) =>
      v == null || v.trim().isEmpty ? context.trRaw('هذا الحقل مطلوب') : null;

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
        phone2: _phone2Ctrl.text.trim(),
      );
      await auth.updateClinicProfile(profile);
      await auth.refreshAndValidateCurrentUser();
      final cached = await ClinicProfileService.isProfileComplete();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: LocalizedText(
            cached ? 'تم حفظ بيانات المرفق الصحي.' : 'تم الحفظ، تحقق من البيانات.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: LocalizedText('تعذّر الحفظ: $e')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _pickLogo(AuthProvider auth) async {
    if (_logoBusy) return;
    final accountId = auth.accountId?.trim() ?? '';
    if (accountId.isEmpty) return;
    setState(() => _logoBusy = true);
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: false,
        type: FileType.image,
      );
      final path = result?.files.single.path;
      if (path == null || path.trim().isEmpty) return;
      final ext = p.extension(path).trim();
      final dir = await getApplicationDocumentsDirectory();
      final target = p.join(
        dir.path,
        ext.isEmpty ? 'clinic_logo.png' : 'clinic_logo$ext',
      );
      final copied = await File(path).copy(target);
      await DBService.instance.updateClinicLogoPath(accountId, copied.path);
      if (!mounted) return;
      setState(() => _logoPath = copied.path);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: LocalizedText('تعذّر حفظ الشعار: $e')));
    } finally {
      if (mounted) setState(() => _logoBusy = false);
    }
  }

  Future<void> _clearLogo(AuthProvider auth) async {
    if (_logoBusy) return;
    final accountId = auth.accountId?.trim() ?? '';
    if (accountId.isEmpty) return;
    setState(() => _logoBusy = true);
    try {
      await DBService.instance.updateClinicLogoPath(accountId, null);
      if (!mounted) return;
      setState(() => _logoPath = null);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: LocalizedText('تعذّر حذف الشعار: $e')));
    } finally {
      if (mounted) setState(() => _logoBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final canAccess =
        auth.isSuperAdmin || auth.featureAllowed(FeatureKeys.clinicProfile);
    if (!canAccess) {
      return Scaffold(
        appBar: AppBar(
          centerTitle: true,
          title: const LocalizedText('بيانات المرفق الصحي'),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: NeuCard(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.block_rounded,
                    color: Theme.of(context).colorScheme.error,
                    size: 34,
                  ),
                  const SizedBox(height: 10),
                  const LocalizedText(
                    'ليست لديك صلاحية لعرض بيانات المرفق الصحي',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    final canEdit = auth.isSuperAdmin ? false : auth.isOwnerOrAdmin;
    final isPaid = auth.isPro;
    return Scaffold(
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
              const LocalizedText('بيانات المرفق الصحي'),
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
                          child: const LocalizedText('حدّث بيانات المرفق الصحي لتظهر في كل تقارير PDF.',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        const SizedBox(height: 12),
                        NeuCard(
                          padding: const EdgeInsets.all(14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const LocalizedText('شعار المرفق الصحي',
                                style: TextStyle(fontWeight: FontWeight.w800),
                              ),
                              const SizedBox(height: 8),
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  Container(
                                    width: 84,
                                    height: 84,
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .outline
                                            .withValues(alpha: .4),
                                      ),
                                    ),
                                    child: _logoPath == null
                                        ? const Icon(Icons.image_outlined)
                                        : ClipRRect(
                                            borderRadius:
                                                BorderRadius.circular(10),
                                            child: Image.file(
                                              File(_logoPath!),
                                              fit: BoxFit.contain,
                                              errorBuilder: (_, __, ___) =>
                                                  const Icon(
                                                      Icons.broken_image),
                                            ),
                                          ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        if (_logoPath == null)
                                          const LocalizedText(
                                            'لا يوجد شعار مخصص بعد.',
                                            style: TextStyle(
                                              fontWeight: FontWeight.w700,
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          )
                                        else
                                          Text(
                                            p.basename(_logoPath!),
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w700,
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        const SizedBox(height: 6),
                                        LocalizedText(
                                          isPaid
                                              ? 'يظهر هذا الشعار في جميع تقارير PDF.'
                                              : 'يظهر الشعار فقط للخطط المدفوعة.',
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: Theme.of(context)
                                                .colorScheme
                                                .onSurface
                                                .withValues(alpha: .7),
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        Row(
                                          children: [
                                            FilledButton.tonal(
                                              onPressed: canEdit && !_logoBusy
                                                  ? () => _pickLogo(auth)
                                                  : null,
                                              child: _logoBusy
                                                  ? const SizedBox(
                                                      width: 16,
                                                      height: 16,
                                                      child:
                                                          CircularProgressIndicator(
                                                        strokeWidth: 2,
                                                      ),
                                                    )
                                                  : const LocalizedText('اختيار شعار'),
                                            ),
                                            const SizedBox(width: 8),
                                            TextButton(
                                              onPressed: canEdit &&
                                                      _logoPath != null &&
                                                      !_logoBusy
                                                  ? () => _clearLogo(auth)
                                                  : null,
                                              child: const LocalizedText('إزالة'),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        _sectionTitle('البيانات العربية'),
                        const SizedBox(height: 8),
                        NeuField(
                          controller: _nameArCtrl,
                          labelText: context.trRaw('اسم المرفق الصحي'),
                          validator: _req,
                          enabled: canEdit,
                        ),
                        const SizedBox(height: 8),
                        NeuField(
                          controller: _cityArCtrl,
                          labelText: context.trRaw('المدينة'),
                          validator: _req,
                          enabled: canEdit,
                        ),
                        const SizedBox(height: 8),
                        NeuField(
                          controller: _streetArCtrl,
                          labelText: context.trRaw('الشارع'),
                          validator: _req,
                          enabled: canEdit,
                        ),
                        const SizedBox(height: 8),
                        NeuField(
                          controller: _nearArCtrl,
                          labelText: context.trRaw('بجوار'),
                          validator: _req,
                          enabled: canEdit,
                        ),
                        const SizedBox(height: 16),
                        _sectionTitle('التفاصيل الإنجليزية'),
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
                          labelText: context.trRaw('رقم الهاتف'),
                          validator: _req,
                          keyboardType: TextInputType.phone,
                          textDirection: ui.TextDirection.ltr,
                          enabled: canEdit,
                        ),
                        const SizedBox(height: 8),
                        NeuField(
                          controller: _phone2Ctrl,
                          labelText: context.trRaw('رقم هاتف إضافي (اختياري)'),
                          keyboardType: TextInputType.phone,
                          textDirection: ui.TextDirection.ltr,
                          enabled: canEdit,
                        ),
                        const SizedBox(height: 16),
                        if (!canEdit)
                          const LocalizedText('التعديل متاح للمالك أو المدير فقط.',
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
    );
  }

  Widget _sectionTitle(String title) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: LocalizedText(
          title,
          style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 14.5),
        ),
      );
}
