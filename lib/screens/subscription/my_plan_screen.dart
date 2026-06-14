import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/widgets/data_surface_widgets.dart';
import 'package:aelmamclinic/models/payment_method.dart';
import 'package:aelmamclinic/models/subscription_plan.dart';
import 'package:aelmamclinic/providers/auth_provider.dart';
import 'package:aelmamclinic/services/billing_service.dart';
import 'package:aelmamclinic/screens/subscription/payment_request_screen.dart';
import 'package:aelmamclinic/utils/app_formatters.dart';
import 'package:aelmamclinic/utils/l10n_extensions.dart';
import 'package:aelmamclinic/widgets/localized_text.dart';

class MyPlanScreen extends StatefulWidget {
  const MyPlanScreen({super.key});

  @override
  State<MyPlanScreen> createState() => _MyPlanScreenState();
}

class _MyPlanScreenState extends State<MyPlanScreen> {
  final BillingService _billing = BillingService();
  final ScrollController _annualCtrl = ScrollController();
  double _annualScroll = 0;

  bool _loading = true;
  List<SubscriptionPlan> _plans = const [];
  String _currentPlan = 'free';
  DateTime? _planEndAt;
  TrialPlanStatus _trialStatus = const TrialPlanStatus(
    hasPending: false,
    hasUsed: false,
    hasBlockingPending: false,
  );
  String? _error;
  String? _statusNotice;
  DateTime? _referenceNow;
  bool? _lastOfflineState;

  NumberFormat get _currency =>
      AppFormatters.currency(symbol: '\$', decimalDigits: 0);

  // ✅ مزايا الخطط المدفوعة (بدون الأشعة/المختبرات)
  static const List<String> _paidBaseFeatures = [
    'لوحة التحكم',
    'إضافة المرضى',
    'قائمة المرضى',
    'استخراج تقارير للمرضى',
    'ادارة المخزن',
    'المرتجعات',
    'اضافة طبيب وخدماته',
    'الموظفون',
    'المدفوعات',
    'الرسوم البيانية',
    'المستودع/المخزون',
    'الوصفات الطبية',
    'استخراج البيانات محليا',
    'إدارة الحسابات داخل العيادة',
    'الدردشة',
    'سجل التدقيق',
    'صلاحيات التدقيق',
  ];

  static const List<String> _freeFeatures = [
    'لوحة التحكم',
    'إضافة المرضى',
    'قائمة المرضى',
    'اضافة طبيب وخدماته',
    'استخراج تقارير للمرضى',
  ];

  static const List<String> _proExtraFeatures = [
    'الأشعة والمختبرات (تحت التطوير)',
  ];

  List<String> _featuresForPlan(String planCode) {
    final code = planCode.toLowerCase();
    if (code == 'free') return _freeFeatures;
    final base = List<String>.from(_paidBaseFeatures);
    if (code == 'month_pro' || code == 'year_pro') {
      base.addAll(_proExtraFeatures);
    }
    return base;
  }

  List<String> _employeesPolicyForPlan(String planCode) {
    final code = planCode.toLowerCase();
    final limit = _employeeLimitForPlan(code);
    if (code == 'free') return const [];
    final lines = <String>['الحد الأساسي: حتى $limit موظف للعيادة.'];
    if (code == 'month_pro' || code == 'year_pro') {
      lines.add('يمكن طلب مقاعد إضافية بعد الوصول للسقف.');
    } else {
      lines.add('لا يمكن تجاوز السقف إلا بالترقية لخطة أعلى.');
    }
    return lines;
  }

  int _employeeLimitForPlan(String code) {
    switch (code.toLowerCase()) {
      case 'month_plus':
      case 'year_plus':
        return 10;
      case 'month_pro':
      case 'year_pro':
        return 20;
      case 'trial_month':
      case 'month':
      case 'year':
      default:
        return 5;
    }
  }

  String _planDisplayName(String code, String fallback) {
    final c = code.toLowerCase();
    switch (c) {
      case 'free':
        return 'المجانية';
      case 'trial_month':
        return 'التجريبية الشهرية';
      case 'month':
        return 'الشهرية القديمة';
      case 'month_plus':
        return 'الشهرية بلس القديمة';
      case 'month_pro':
        return 'الشهرية برو القديمة';
      case 'year':
        return 'YEAR';
      case 'year_plus':
        return 'YEAR PLUS';
      case 'year_pro':
        return 'YEAR PRO';
      default:
        return fallback;
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
    _annualCtrl.addListener(() {
      if (!mounted || !_annualCtrl.hasClients) return;
      final max = _annualCtrl.position.maxScrollExtent;
      final next = max <= 0 ? 0.0 : (_annualCtrl.offset / max).clamp(0.0, 1.0);
      if (next != _annualScroll) setState(() => _annualScroll = next);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final auth = Provider.of<AuthProvider>(context);
    final offline = auth.isOffline;
    if (_lastOfflineState == true && !offline) {
      unawaited(_load(silent: true));
    }
    _lastOfflineState = offline;
  }

  Future<void> _load({bool silent = false}) async {
    final auth = context.read<AuthProvider>();
    try {
      if (!silent) {
        setState(() {
          _loading = true;
          _error = null;
          _statusNotice = null;
        });
      }

      var notice = auth.isOffline
          ? 'تعمل هذه الصفحة حاليًا على آخر البيانات المحفوظة. ستُحدَّث الخطط ووسائل الدفع تلقائيًا عند عودة الاتصال.'
          : null;
      var plans = _plans;
      var trialStatus = _trialStatus;
      var planCode = auth.planCode.toLowerCase();
      var planEndAt = auth.planEndAt;
      DateTime? referenceNow;

      try {
        referenceNow = await auth.resolveReferenceNow();
      } catch (_) {
        referenceNow = auth.currentReferenceNow();
      }

      try {
        plans = await _billing.fetchPlans();
      } catch (_) {
        notice ??= auth.isOffline
            ? 'لا توجد بعد قائمة خطط محفوظة على هذا الجهاز. اتصل بالإنترنت مرة واحدة لتحميل الكتالوج الكامل.'
            : 'تعذّر تحديث قائمة الخطط الآن. تم الاحتفاظ بآخر بيانات متاحة.';
      }

      try {
        final details = await _billing.fetchMyPlanDetails();
        planCode =
            details['plan_code']?.toString().toLowerCase() ?? auth.planCode;
        final planEndRaw = details['plan_end_at']?.toString();
        planEndAt =
            planEndRaw == null ? auth.planEndAt : DateTime.tryParse(planEndRaw);
      } catch (_) {
        notice ??= auth.isOffline
            ? 'تم الاحتفاظ بحالة الاشتراك من آخر مزامنة موثوقة على هذا الجهاز.'
            : 'تعذّر تحديث تفاصيل الخطة الحالية الآن. تم عرض آخر حالة محفوظة.';
      }

      try {
        trialStatus = await _billing.fetchTrialPlanStatus();
      } catch (_) {
        notice ??= auth.isOffline
            ? 'حالة الطلبات التجريبية المعروضة أدناه هي آخر حالة محفوظة محليًا.'
            : 'تعذّر تحديث حالة الطلبات التجريبية الآن. تم عرض آخر حالة محفوظة.';
      }

      if (plans.isEmpty) {
        notice ??= auth.isOffline
            ? 'لا توجد بعد خطط محفوظة محليًا على هذا الجهاز. اتصل بالإنترنت مرة واحدة لتحميلها ثم ستظل متاحة أوفلاين.'
            : 'تعذّر تحميل كتالوج الخطط بالكامل حاليًا. أعد المحاولة بعد قليل.';
      }

      if (!mounted) return;
      setState(() {
        _plans = plans.where((p) => p.isActive).toList();
        _currentPlan = planCode;
        _planEndAt = planEndAt;
        _trialStatus = trialStatus;
        _referenceNow = referenceNow;
        _statusNotice = notice;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'تعذّر تحميل الخطط: $e';
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    _annualCtrl.dispose();
    super.dispose();
  }

  Future<void> _startUpgrade(SubscriptionPlan plan) async {
    final auth = context.read<AuthProvider>();
    List<PaymentMethod> methods;
    try {
      methods = await _billing.fetchPaymentMethods();
    } catch (_) {
      if (!mounted) return;
      _snack(
        auth.isOffline
            ? 'لا توجد وسائل دفع محفوظة على هذا الجهاز بعد. اتصل بالإنترنت مرة واحدة لتحميلها.'
            : 'تعذّر تحميل وسائل الدفع حاليًا.',
      );
      return;
    }
    if (!mounted) return;

    if (methods.isEmpty) {
      _snack(
        auth.isOffline
            ? 'لا توجد وسائل دفع محفوظة محليًا حاليًا.'
            : 'لا توجد وسائل دفع متاحة حاليًا.',
      );
      return;
    }

    final selected = await showModalBottomSheet<PaymentMethod>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (_) => _PaymentMethodPicker(methods: methods),
    );

    if (!mounted) return;
    if (selected == null) return;

    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => PaymentRequestScreen(plan: plan, method: selected),
      ),
    );

    if (!mounted || ok != true) return;
    _snack('تم إرسال طلب الاشتراك بنجاح. سيتم مراجعته قريبًا.');
  }

  Future<void> _startTrialRequest() async {
    if (context.read<AuthProvider>().isOffline) {
      _snack(
        'يتطلب إرسال طلب التفعيل التجريبي اتصالًا بالإنترنت. أعد المحاولة بعد عودة الشبكة.',
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const LocalizedText('طلب تفعيل الخطة التجريبية'),
        content: const LocalizedText(
          'سيتم إرسال طلب تفعيل تجريبي مجاني لمدة شهر واحد. هذه التجربة متاحة مرة واحدة فقط لهذا الحساب.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const LocalizedText('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const LocalizedText('إرسال الطلب'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    try {
      await _billing.createTrialPlanRequest();
      if (!mounted) return;
      _snack('تم إرسال طلب التفعيل التجريبي بنجاح. سيتم مراجعته قريبًا.');
      await _load();
    } catch (e) {
      if (!mounted) return;
      _snack(_mapTrialError(e));
    }
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: LocalizedText(msg)));
  }

  String _mapTrialError(Object error) {
    final msg = error.toString().toLowerCase();
    if (msg.contains('socket') ||
        msg.contains('network') ||
        msg.contains('timeout') ||
        msg.contains('connection')) {
      return 'يتطلب إرسال الطلب اتصالًا بالإنترنت. أعد المحاولة عند عودة الشبكة.';
    }
    if (msg.contains('trial already used')) {
      return 'تم استخدام التجربة الشهرية سابقًا لهذا الحساب.';
    }
    if (msg.contains('trial requires free plan')) {
      return 'التجربة الشهرية متاحة فقط قبل تفعيل أي خطة أخرى.';
    }
    if (msg.contains('pending request exists')) {
      return 'يوجد طلب اشتراك آخر قيد المراجعة لهذا الحساب.';
    }
    if (msg.contains('only owner')) {
      return 'فقط مالك العيادة يمكنه طلب التفعيل التجريبي.';
    }
    return 'تعذّر إرسال طلب التفعيل التجريبي.';
  }

  String _currentPlanName() {
    for (final p in _plans) {
      if (p.code.toLowerCase() == _currentPlan.toLowerCase()) {
        return _planDisplayName(p.code, p.name);
      }
    }
    return _planDisplayName(_currentPlan, _currentPlan.toUpperCase());
  }

  bool _isAnnualByCode(String code) {
    final c = code.toLowerCase();
    return c.contains('year') || c.contains('annual') || c.contains('yearly');
  }

  bool _isOwner(AuthProvider auth) => auth.role?.toLowerCase() == 'owner';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final auth = context.watch<AuthProvider>();
    final isOwner = _isOwner(auth);
    final statusNotice = _statusNotice ??
        (auth.isOffline
            ? 'تعمل هذه الصفحة حاليًا على آخر البيانات المحفوظة محليًا.'
            : null);
    final trialPlan = _plans.firstWhere(
      (p) => p.code.toLowerCase() == 'trial_month',
      orElse: () => const SubscriptionPlan(
        code: 'trial_month',
        name: 'TRIAL_MONTH',
        priceUsd: 0,
        durationMonths: 1,
        isActive: true,
      ),
    );
    final trialPending = _trialStatus.hasPending;
    final trialUsed = _trialStatus.hasUsed;
    final trialEligible = auth.isLoggedIn &&
        isOwner &&
        !auth.isOffline &&
        _currentPlan == 'free' &&
        !trialPending &&
        !_trialStatus.hasBlockingPending &&
        !trialUsed;
    final trialDisabledReason = auth.isOffline
        ? 'إرسال الطلب يتطلب اتصالًا بالإنترنت. ستبقى بيانات الخطة الحالية متاحة أوفلاين.'
        : trialPending
            ? 'يوجد طلب تجريبي قيد المراجعة.'
            : _trialStatus.hasBlockingPending
                ? 'يوجد طلب اشتراك آخر قيد المراجعة لهذا الحساب.'
                : trialUsed
                    ? 'تم استخدام التجربة الشهرية سابقًا لهذا الحساب.'
                    : (_currentPlan != 'free'
                        ? 'التجربة الشهرية متاحة فقط قبل تفعيل أي خطة أخرى.'
                        : (!isOwner
                            ? 'هذه الشاشة متاحة فقط لمالك العيادة.'
                            : 'سجّل الدخول أولاً لإرسال الطلب.'));
    final trialButtonLabel = trialPending
        ? 'الطلب قيد المراجعة'
        : trialUsed
            ? 'استُخدمت سابقًا'
            : 'طلب التفعيل التجريبي';

    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(title: const LocalizedText('خطتي'), centerTitle: false),
      body: Stack(
        children: [
          _AnimatedBubbleBackdrop(scheme: scheme),
          SafeArea(
            child: Padding(
              padding: kScreenPadding,
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : !isOwner
                      ? Center(
                          child: _ErrorState(
                            message: 'هذه الشاشة متاحة فقط لمالك العيادة.',
                            onRetry: _load,
                          ),
                        )
                      : _error != null
                          ? Center(
                              child:
                                  _ErrorState(message: _error!, onRetry: _load),
                            )
                          : LayoutBuilder(
                              builder: (context, constraints) {
                                final w = constraints.maxWidth;
                                final annualPlans = _plans
                                    .where((p) =>
                                        p.code.toLowerCase().contains('year'))
                                    .toList();
                                final cardWidth = w >= 720 ? 340.0 : (w - 12);
                                final annualWidth = annualPlans.isEmpty
                                    ? 0.0
                                    : (annualPlans.length * cardWidth) +
                                        ((annualPlans.length - 1) * 12.0);
                                final freePlan = _plans.firstWhere(
                                  (p) => p.code.toLowerCase() == 'free',
                                  orElse: () => SubscriptionPlan(
                                    code: 'free',
                                    name: 'FREE',
                                    priceUsd: 0,
                                    durationMonths: 0,
                                    isActive: true,
                                  ),
                                );

                                return SingleChildScrollView(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      _PlanHeaderHero(
                                        currentPlanName: _currentPlanName(),
                                        currentPlanCode: _currentPlan,
                                        planEndAt: _planEndAt,
                                        referenceNow: _referenceNow,
                                      ),
                                      const SizedBox(height: 14),
                                      if (statusNotice != null) ...[
                                        _InfoBanner(
                                          icon: auth.isOffline
                                              ? Icons.cloud_off_rounded
                                              : Icons.info_outline_rounded,
                                          title: auth.isOffline
                                              ? 'وضع عدم الاتصال'
                                              : 'ملاحظة',
                                          body: statusNotice,
                                        ),
                                        const SizedBox(height: 14),
                                      ],
                                      _SectionTitle(
                                        title: 'الخطة المجانية',
                                        subtitle:
                                            'أساسيات إدارة العيادة مع مزايا محدودة.',
                                      ),
                                      const SizedBox(height: 10),
                                      SizedBox(
                                        width: cardWidth,
                                        child: _PlanPricingCard(
                                          planName: _planDisplayName(
                                            freePlan.code,
                                            freePlan.name,
                                          ),
                                          planCode: freePlan.code,
                                          isCurrent:
                                              freePlan.code.toLowerCase() ==
                                                  _currentPlan.toLowerCase(),
                                          isFree: true,
                                          isAnnual: false,
                                          priceMain: 'مجانية',
                                          priceSuffix: '',
                                          features:
                                              _featuresForPlan(freePlan.code),
                                          employeesPolicy:
                                              _employeesPolicyForPlan(
                                            freePlan.code,
                                          ),
                                          canUpgrade: false,
                                          onUpgrade: () {},
                                          onNeedLogin: () {},
                                        ),
                                      ),
                                      const SizedBox(height: 18),
                                      _SectionTitle(
                                        title: 'الخطة التجريبية الشهرية',
                                        subtitle:
                                            'تجربة مجانية لمدة شهر واحد بصلاحيات الخطة الشهرية الحالية ولمرة واحدة فقط.',
                                      ),
                                      const SizedBox(height: 10),
                                      SizedBox(
                                        width: cardWidth,
                                        child: _PlanPricingCard(
                                          planName: _planDisplayName(
                                            trialPlan.code,
                                            trialPlan.name,
                                          ),
                                          planCode: trialPlan.code,
                                          isCurrent:
                                              trialPlan.code.toLowerCase() ==
                                                  _currentPlan.toLowerCase(),
                                          isFree: false,
                                          isAnnual: false,
                                          priceMain: 'مجانية',
                                          priceSuffix: '',
                                          features:
                                              _featuresForPlan(trialPlan.code),
                                          employeesPolicy:
                                              _employeesPolicyForPlan(
                                            trialPlan.code,
                                          ),
                                          canUpgrade: trialEligible,
                                          onUpgrade: _startTrialRequest,
                                          onNeedLogin: () =>
                                              _snack(trialDisabledReason),
                                          subtitleOverride:
                                              'فعّل شهراً تجريبياً واحداً مجاناً لتجربة مزايا الخطة الشهرية الحالية.',
                                          buttonLabelOverride: trialButtonLabel,
                                          disabledNote: trialDisabledReason,
                                          badgeTextOverride:
                                              trialPlan.code.toLowerCase() ==
                                                      _currentPlan.toLowerCase()
                                                  ? 'الخطة الحالية'
                                                  : 'مرة واحدة',
                                          popularBadgeOverride: 'تجربة مجانية',
                                        ),
                                      ),
                                      const SizedBox(height: 18),
                                      _SectionTitle(
                                        title: 'الخطط السنوية',
                                        subtitle:
                                            'الاشتراكات السنوية الرسمية بعد انتهاء التجربة أو عند الترقية المباشرة.',
                                      ),
                                      const SizedBox(height: 10),
                                      if (annualPlans.isEmpty)
                                        _InfoBanner(
                                          icon: Icons.sync_problem_rounded,
                                          title: 'الخطط السنوية',
                                          body: auth.isOffline
                                              ? 'لا توجد خطط سنوية محفوظة على هذا الجهاز بعد. اتصل بالإنترنت مرة واحدة لتحميلها.'
                                              : 'تعذّر تحميل الخطط السنوية حاليًا. أعد المحاولة بعد قليل.',
                                        )
                                      else ...[
                                        IntrinsicHeight(
                                          child: SingleChildScrollView(
                                            controller: _annualCtrl,
                                            scrollDirection: Axis.horizontal,
                                            physics:
                                                const BouncingScrollPhysics(),
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 2,
                                            ),
                                            child: SizedBox(
                                              width: math.max<double>(
                                                  w, annualWidth),
                                              child: Row(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                mainAxisAlignment: annualWidth <
                                                        w
                                                    ? MainAxisAlignment.center
                                                    : MainAxisAlignment.start,
                                                children: [
                                                  for (final plan
                                                      in annualPlans) ...[
                                                    SizedBox(
                                                      width: cardWidth,
                                                      child: _PlanPricingCard(
                                                        planName:
                                                            _planDisplayName(
                                                          plan.code,
                                                          plan.name,
                                                        ),
                                                        planCode: plan.code,
                                                        isCurrent: plan.code
                                                                .toLowerCase() ==
                                                            _currentPlan
                                                                .toLowerCase(),
                                                        isFree: plan.code
                                                                .toLowerCase() ==
                                                            'free',
                                                        isAnnual:
                                                            _isAnnualByCode(
                                                          plan.code,
                                                        ),
                                                        priceMain: plan.code
                                                                    .toLowerCase() ==
                                                                'free'
                                                            ? 'مجانية'
                                                            : _currency.format(
                                                                plan.priceUsd,
                                                              ),
                                                        priceSuffix: '',
                                                        features:
                                                            _featuresForPlan(
                                                          plan.code,
                                                        ),
                                                        employeesPolicy:
                                                            _employeesPolicyForPlan(
                                                          plan.code,
                                                        ),
                                                        canUpgrade: auth
                                                                .isLoggedIn &&
                                                            isOwner &&
                                                            !auth.isOffline &&
                                                            plan.code
                                                                    .toLowerCase() !=
                                                                _currentPlan
                                                                    .toLowerCase() &&
                                                            plan.code
                                                                    .toLowerCase() !=
                                                                'free',
                                                        onUpgrade: () =>
                                                            _startUpgrade(plan),
                                                        onNeedLogin: () =>
                                                            _snack(
                                                          auth.isOffline
                                                              ? 'لا يمكن إرسال طلب الترقية دون اتصال. عُد للشبكة ثم أعد المحاولة.'
                                                              : isOwner
                                                                  ? 'سجّل الدخول أولاً لطلب الترقية.'
                                                                  : 'فقط مالك العيادة يمكنه طلب الاشتراك.',
                                                        ),
                                                      ),
                                                    ),
                                                    const SizedBox(width: 12),
                                                  ],
                                                ],
                                              ),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        _ScrollHintBar(progress: _annualScroll),
                                      ],
                                      if (!auth.isLoggedIn)
                                        _InfoBanner(
                                          icon: Icons.lock_rounded,
                                          title: 'ملاحظة',
                                          body:
                                              'لا يمكنك طلب ترقية قبل تسجيل الدخول.',
                                        ),
                                      if (auth.isLoggedIn && !isOwner)
                                        _InfoBanner(
                                          icon: Icons.verified_user_outlined,
                                          title: 'تنبيه',
                                          body:
                                              'إدارة الخطط والاشتراكات متاحة فقط لمالك العيادة.',
                                        ),
                                      const SizedBox(height: 24),
                                      Divider(
                                        color: scheme.outlineVariant.withValues(
                                          alpha: 0.5,
                                        ),
                                      ),
                                      const SizedBox(height: 10),
                                      if (_employeesPolicyForPlan(
                                        _currentPlan,
                                      ).isNotEmpty)
                                        _InfoBanner(
                                          icon: Icons.groups_rounded,
                                          title: 'سياسة الموظفين',
                                          body: _employeesPolicyForPlan(
                                            _currentPlan,
                                          ).join('\n'),
                                        ),
                                      const SizedBox(height: 24),
                                    ],
                                  ),
                                );
                              },
                            ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AnimatedBubbleBackdrop extends StatefulWidget {
  const _AnimatedBubbleBackdrop({required this.scheme});
  final ColorScheme scheme;

  @override
  State<_AnimatedBubbleBackdrop> createState() =>
      _AnimatedBubbleBackdropState();
}

class _AnimatedBubbleBackdropState extends State<_AnimatedBubbleBackdrop>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 12),
    )..repeat();
    _controller.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void didUpdateWidget(covariant _AnimatedBubbleBackdrop oldWidget) {
    super.didUpdateWidget(oldWidget);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: LayoutBuilder(
        builder: (context, constraints) {
          return CustomPaint(
            painter: _AmbientLinesPainter(
              scheme: widget.scheme,
              phase: _controller.value,
            ),
          );
        },
      ),
    );
  }
}

class _AmbientLinesPainter extends CustomPainter {
  _AmbientLinesPainter({required this.scheme, required this.phase});

  final ColorScheme scheme;
  final double phase;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final bgPaint = Paint()
      ..shader = LinearGradient(
        colors: [
          scheme.surface,
          scheme.surfaceContainerHighest.withValues(alpha: 0.55),
          scheme.surface,
        ],
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
      ).createShader(rect);
    canvas.drawRect(rect, bgPaint);

    final paints = [
      Paint()
        ..color = scheme.primary.withValues(alpha: 0.08)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
      Paint()
        ..color = scheme.secondary.withValues(alpha: 0.07)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0,
      Paint()
        ..color = scheme.tertiary.withValues(alpha: 0.06)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.9,
    ];

    final rng = math.Random(7);
    for (int i = 0; i < 18; i++) {
      final p = paints[i % paints.length];
      final x = rng.nextDouble() * size.width;
      final y = rng.nextDouble() * size.height;
      final len = 120 + rng.nextDouble() * 180;
      final angle =
          (rng.nextDouble() * math.pi * 2) + (phase * math.pi * 2 * 0.3);
      final dx = math.cos(angle) * len;
      final dy = math.sin(angle) * len;
      canvas.drawLine(Offset(x, y), Offset(x + dx, y + dy), p);
    }
  }

  @override
  bool shouldRepaint(covariant _AmbientLinesPainter oldDelegate) {
    return oldDelegate.phase != phase || oldDelegate.scheme != scheme;
  }
}

class _ScrollHintBar extends StatelessWidget {
  const _ScrollHintBar({required this.progress});

  final double progress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 6,
      decoration: BoxDecoration(
        color: scheme.outlineVariant.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(999),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final track = constraints.maxWidth;
          final thumb = track * 0.25;
          final left = (track - thumb) * progress.clamp(0.0, 1.0);
          return Stack(
            children: [
              Positioned(
                left: left,
                top: 0,
                bottom: 0,
                child: Container(
                  width: thumb,
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
            ],
          );
        },
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
        LocalizedText(
          title,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w900,
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(height: 4),
        LocalizedText(
          subtitle,
          style: TextStyle(
            fontSize: 12.5,
            height: 1.25,
            color: scheme.onSurface.withValues(alpha: 0.65),
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _PlanHeaderHero extends StatelessWidget {
  const _PlanHeaderHero({
    required this.currentPlanName,
    required this.currentPlanCode,
    required this.planEndAt,
    required this.referenceNow,
  });

  final String currentPlanName;
  final String currentPlanCode;
  final DateTime? planEndAt;
  final DateTime? referenceNow;

  @override
  Widget build(BuildContext context) {
    final code = currentPlanCode.toLowerCase();
    final isFree = code == 'free';
    final isTrial = code == 'trial_month';
    final isPro = code == 'month_pro' || code == 'year_pro';
    final isPlus = code == 'month_plus' || code == 'year_plus';
    final localPlanEndAt = planEndAt?.toLocal();
    final localReferenceNow = (referenceNow ?? DateTime.now()).toLocal();
    final isExpired = !isFree &&
        localPlanEndAt != null &&
        !localPlanEndAt.isAfter(localReferenceNow);
    final daysLeft = localPlanEndAt == null
        ? null
        : localPlanEndAt.difference(localReferenceNow).inDays;
    final statusLabel = isExpired
        ? 'منتهية'
        : isFree
            ? 'مجانية'
            : (isTrial ? 'تجربة مجانية' : 'مدفوعة');
    final endLabel = localPlanEndAt == null
        ? 'غير محدد'
        : DateFormat('yyyy-MM-dd').format(localPlanEndAt);
    final remainingLabel = isFree
        ? 'غير محدود'
        : isExpired
            ? 'منتهية'
            : daysLeft == null
                ? 'غير محدد'
                : (daysLeft <= 0 ? 'تنتهي اليوم' : '$daysLeft يوم');

    return AppDashboardHero(
      title: context.trRaw('حالة الخطة والاشتراك'),
      subtitle: context.trRaw(
        'ملخص سريع للخطة الحالية، تاريخ الانتهاء، وحالة الوصول قبل إرسال طلبات الترقية أو الدفع.',
      ),
      icon: Icons.workspace_premium_rounded,
      tone: isExpired
          ? AppTone.danger
          : isFree || isTrial
              ? AppTone.info
              : AppTone.accent,
      metrics: <AppHeroMetric>[
        AppHeroMetric(
          label: context.trRaw('الخطة'),
          value: currentPlanName,
          icon: Icons.verified_rounded,
          tone: isPro || isPlus ? AppTone.accent : AppTone.primary,
        ),
        AppHeroMetric(
          label: context.trRaw('الحالة'),
          value: statusLabel,
          icon: isExpired ? Icons.cancel_rounded : Icons.check_circle_rounded,
          tone: isExpired ? AppTone.danger : AppTone.success,
        ),
        AppHeroMetric(
          label: context.trRaw('تنتهي'),
          value: endLabel,
          icon: Icons.event_available_rounded,
          tone: AppTone.info,
        ),
        AppHeroMetric(
          label: context.trRaw('المتبقي'),
          value: remainingLabel,
          icon: Icons.timelapse_rounded,
          tone: isExpired ? AppTone.danger : AppTone.warning,
        ),
      ],
    );
  }
}

// Kept as a legacy fallback for subscription-card experiments.
// ignore: unused_element
class _PlanHeaderModern extends StatelessWidget {
  const _PlanHeaderModern({
    required this.currentPlanName,
    required this.currentPlanCode,
    required this.planEndAt,
    required this.referenceNow,
  });

  final String currentPlanName;
  final String currentPlanCode;
  final DateTime? planEndAt;
  final DateTime? referenceNow;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final code = currentPlanCode.toLowerCase();
    final isFree = code == 'free';
    final isTrial = code == 'trial_month';
    final isPro = code == 'month_pro' || code == 'year_pro';
    final isPlus = code == 'month_plus' || code == 'year_plus';
    final localPlanEndAt = planEndAt?.toLocal();
    final localReferenceNow = (referenceNow ?? DateTime.now()).toLocal();
    final isExpired = !isFree &&
        localPlanEndAt != null &&
        !localPlanEndAt.isAfter(localReferenceNow);
    final daysLeft = localPlanEndAt == null
        ? null
        : localPlanEndAt.difference(localReferenceNow).inDays;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.25),
          width: 0.7,
        ),
        color: Colors.transparent,
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              gradient: LinearGradient(
                colors: [
                  scheme.primary.withValues(alpha: 0.18),
                  scheme.secondary.withValues(alpha: 0.12),
                ],
                begin: Alignment.topRight,
                end: Alignment.bottomLeft,
              ),
              border: Border.all(color: scheme.primary.withValues(alpha: 0.25)),
            ),
            child: Icon(Icons.workspace_premium_rounded, color: scheme.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LocalizedText(
                  'الخطة الحالية',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                    color: scheme.onSurface.withValues(alpha: 0.65),
                  ),
                ),
                const SizedBox(height: 4),
                LocalizedText(
                  currentPlanName,
                  style: TextStyle(
                    fontSize: 16.5,
                    fontWeight: FontWeight.w900,
                    color: scheme.onSurface,
                  ),
                ),
                if (!isFree && (isPro || isPlus)) ...[
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: (isPro ? scheme.primary : scheme.tertiary)
                          .withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: (isPro ? scheme.primary : scheme.tertiary)
                            .withValues(alpha: 0.2),
                      ),
                    ),
                    child: LocalizedText(
                      isPro ? 'PRO' : 'PLUS',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w900,
                        color: isPro ? scheme.primary : scheme.tertiary,
                      ),
                    ),
                  ),
                ],
                if (!isFree && localPlanEndAt != null) ...[
                  const SizedBox(height: 6),
                  LocalizedText(
                    isExpired
                        ? 'انتهت: ${DateFormat('yyyy-MM-dd').format(localPlanEndAt)}'
                        : 'تنتهي: ${DateFormat('yyyy-MM-dd').format(localPlanEndAt)}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: isExpired
                          ? scheme.error
                          : scheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                  if (!isExpired && daysLeft != null && daysLeft >= 0) ...[
                    const SizedBox(height: 4),
                    LocalizedText(
                      daysLeft == 0
                          ? 'تنتهي اليوم'
                          : 'المتبقي تقريبًا: $daysLeft يوم',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: daysLeft <= 7
                            ? scheme.tertiary
                            : scheme.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                  ],
                ],
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              color: (isFree || isTrial)
                  ? scheme.secondary.withValues(alpha: 0.14)
                  : scheme.primary.withValues(alpha: 0.14),
              border: Border.all(
                color: (isFree || isTrial)
                    ? scheme.secondary.withValues(alpha: 0.25)
                    : scheme.primary.withValues(alpha: 0.25),
              ),
            ),
            child: LocalizedText(
              isExpired
                  ? 'منتهية'
                  : isFree
                      ? 'مجانية'
                      : (isTrial ? 'تجربة مجانية' : 'مدفوعة'),
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w900,
                color: isExpired
                    ? scheme.error
                    : isFree || isTrial
                        ? scheme.secondary
                        : scheme.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlanPricingCard extends StatelessWidget {
  const _PlanPricingCard({
    required this.planName,
    required this.planCode,
    required this.isCurrent,
    required this.isFree,
    required this.isAnnual,
    required this.priceMain,
    required this.priceSuffix,
    required this.features,
    required this.employeesPolicy,
    required this.canUpgrade,
    required this.onUpgrade,
    required this.onNeedLogin,
    this.subtitleOverride,
    this.buttonLabelOverride,
    this.disabledNote,
    this.badgeTextOverride,
    this.popularBadgeOverride,
  });

  final String planName;
  final String planCode;

  final bool isCurrent;
  final bool isFree;
  final bool isAnnual;

  final String priceMain;
  final String priceSuffix;

  final List<String> features;
  final List<String> employeesPolicy;

  final bool canUpgrade;
  final VoidCallback onUpgrade;
  final VoidCallback onNeedLogin;
  final String? subtitleOverride;
  final String? buttonLabelOverride;
  final String? disabledNote;
  final String? badgeTextOverride;
  final String? popularBadgeOverride;

  IconData get _planIcon {
    if (isFree) return Icons.rocket_launch_rounded;
    if (isAnnual) return Icons.auto_awesome_rounded;
    return Icons.stars_rounded;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final code = planCode.toLowerCase();
    final isTrial = code == 'trial_month';

    final accent = isCurrent
        ? scheme.primary
        : (isFree ? scheme.secondary : scheme.tertiary);

    const surface = Colors.transparent;

    final badgeText = badgeTextOverride ?? (isCurrent ? 'الخطة الحالية' : null);

    final popularBadge = popularBadgeOverride ??
        (() {
          if (code == 'year') return 'الأكثر استخدامًا';
          return null;
        }());

    final headerBadge = () {
      if (code == 'year') return 'أفضل قيمة';
      if (code == 'month_pro' || code == 'year_pro') return 'PRO';
      if (code == 'month_plus' || code == 'year_plus') return 'PLUS';
      return null;
    }();

    final tier = (code == 'month_pro' || code == 'year_pro')
        ? 'برو'
        : (code == 'month_plus' || code == 'year_plus')
            ? 'بلس'
            : '';
    final subtitle = isFree
        ? 'ابدأ مجانًا واستكشف الأساسيات.'
        : (isTrial
            ? 'تفعيل مجاني لمرة واحدة لمدة شهر كامل بصلاحيات الخطة الشهرية الحالية.'
            : (isAnnual
                ? 'اشتراك سنوي${tier.isNotEmpty ? " $tier" : ""} بمزايا كاملة لمدة 12 شهر.'
                : 'اشتراك شهري${tier.isNotEmpty ? " $tier" : ""} مرن مع تجديد شهري.'));

    final buttonLabel = buttonLabelOverride ??
        (isCurrent
            ? 'الخطة الحالية'
            : (isFree ? 'الخطة المجانية' : 'طلب ترقية'));

    final isButtonEnabled = !isCurrent && !isFree && canUpgrade;

    return Transform.translate(
      offset: isCurrent ? const Offset(0, -2) : Offset.zero,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(26),
          border: Border.all(
            color: scheme.outlineVariant.withValues(alpha: 0.25),
            width: 0.7,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.12),
              blurRadius: 24,
              spreadRadius: 2,
              offset: const Offset(0, 10),
            ),
            BoxShadow(
              color: Colors.white.withValues(alpha: 0.8),
              blurRadius: 6,
              spreadRadius: -4,
              offset: const Offset(0, -2),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(26),
          child: Material(
            color: surface,
            child: InkWell(
              onTap: isButtonEnabled ? onUpgrade : null,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Header
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(18),
                            gradient: LinearGradient(
                              colors: [
                                accent.withValues(alpha: 0.20),
                                scheme.secondary.withValues(alpha: 0.10),
                              ],
                              begin: Alignment.topRight,
                              end: Alignment.bottomLeft,
                            ),
                            border: Border.all(
                              color: accent.withValues(alpha: 0.22),
                            ),
                          ),
                          child: Icon(_planIcon, color: accent),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              LocalizedText(
                                planName,
                                style: TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w900,
                                  color: scheme.onSurface,
                                ),
                              ),
                              if (headerBadge != null) ...[
                                const SizedBox(height: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(999),
                                    color: accent.withValues(alpha: 0.14),
                                    border: Border.all(
                                      color: accent.withValues(alpha: 0.22),
                                    ),
                                  ),
                                  child: LocalizedText(
                                    headerBadge,
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w900,
                                      color: accent,
                                    ),
                                  ),
                                ),
                              ],
                              const SizedBox(height: 6),
                              LocalizedText(
                                subtitleOverride ?? subtitle,
                                style: TextStyle(
                                  fontSize: 12.5,
                                  height: 1.25,
                                  fontWeight: FontWeight.w600,
                                  color: scheme.onSurface.withValues(
                                    alpha: 0.62,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (badgeText != null) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(999),
                              color: accent.withValues(alpha: 0.14),
                              border: Border.all(
                                color: accent.withValues(alpha: 0.22),
                              ),
                            ),
                            child: LocalizedText(
                              badgeText,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w900,
                                color: accent,
                              ),
                            ),
                          ),
                        ],
                        if (popularBadge != null) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(999),
                              color: scheme.secondary.withValues(alpha: 0.14),
                              border: Border.all(
                                color: scheme.secondary.withValues(alpha: 0.22),
                              ),
                            ),
                            child: LocalizedText(
                              popularBadge,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w900,
                                color: scheme.secondary,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),

                    const SizedBox(height: 14),

                    // Price
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(18),
                        gradient: LinearGradient(
                          colors: [
                            accent.withValues(alpha: 0.14),
                            scheme.surfaceContainerHighest.withValues(
                              alpha: 0.40,
                            ),
                          ],
                          begin: Alignment.topRight,
                          end: Alignment.bottomLeft,
                        ),
                        border: Border.all(
                          color: accent.withValues(alpha: 0.18),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.payments_rounded,
                            color: scheme.onSurface.withValues(alpha: 0.7),
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: RichText(
                              text: TextSpan(
                                children: [
                                  TextSpan(
                                    text: context.trRaw(priceMain),
                                    style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w900,
                                      color: scheme.onSurface,
                                    ),
                                  ),
                                  if (priceSuffix.isNotEmpty)
                                    TextSpan(
                                      text: priceSuffix,
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w800,
                                        color: scheme.onSurface.withValues(
                                          alpha: 0.65,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 14),

                    // Features (عمودي داخل كل كرت)
                    _CardSectionLabel(
                      icon: Icons.checklist_rounded,
                      title: 'المزايا',
                      accent: accent,
                    ),
                    const SizedBox(height: 10),
                    ...features.map(
                      (f) => _FeatureRow(text: f, accent: accent),
                    ),

                    if (employeesPolicy.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Divider(
                        color: scheme.outlineVariant.withValues(alpha: 0.5),
                      ),
                      const SizedBox(height: 10),
                      _CardSectionLabel(
                        icon: Icons.groups_rounded,
                        title: 'سياسة الموظفين',
                        accent: accent,
                      ),
                      const SizedBox(height: 10),
                      ...employeesPolicy.map(
                        (p) => _FeatureRow(
                          text: p,
                          accent: accent,
                          icon: Icons.info_rounded,
                        ),
                      ),
                    ],

                    const SizedBox(height: 14),

                    // CTA
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: isButtonEnabled
                            ? onUpgrade
                            : (!isFree && !isCurrent && !canUpgrade)
                                ? onNeedLogin
                                : null,
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        child: LocalizedText(
                          buttonLabel,
                          style: const TextStyle(fontWeight: FontWeight.w900),
                        ),
                      ),
                    ),

                    // Small note for non-current paid plan when user not logged in
                    if (!isFree && !isCurrent && !canUpgrade) ...[
                      const SizedBox(height: 10),
                      LocalizedText(
                        disabledNote ?? 'سجّل الدخول لإرسال طلب الترقية.',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurface.withValues(alpha: 0.6),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CardSectionLabel extends StatelessWidget {
  const _CardSectionLabel({
    required this.icon,
    required this.title,
    required this.accent,
  });

  final IconData icon;
  final String title;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Row(
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: accent.withValues(alpha: 0.14),
            border: Border.all(color: accent.withValues(alpha: 0.22)),
          ),
          child: Icon(icon, size: 16, color: accent),
        ),
        const SizedBox(width: 8),
        LocalizedText(
          title,
          style: TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w900,
            color: scheme.onSurface,
          ),
        ),
      ],
    );
  }
}

class _FeatureRow extends StatelessWidget {
  const _FeatureRow({
    required this.text,
    required this.accent,
    this.icon = Icons.check_circle_rounded,
  });

  final String text;
  final Color accent;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasDev = text.contains('تحت التطوير');
    final cleanText = hasDev
        ? text.replaceAll(RegExp(r'\s*\(.*?تحت التطوير.*?\)\s*'), '').trim()
        : text;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: accent.withValues(alpha: 0.9)),
          const SizedBox(width: 8),
          Expanded(
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 6,
              children: [
                LocalizedText(
                  cleanText,
                  style: TextStyle(
                    fontSize: 12.8,
                    height: 1.25,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface.withValues(alpha: 0.80),
                  ),
                ),
                if (hasDev)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.tertiary.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: scheme.tertiary.withValues(alpha: 0.25),
                      ),
                    ),
                    child: LocalizedText(
                      'تحت التطوير',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                        color: scheme.tertiary,
                      ),
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

class _InfoBanner extends StatelessWidget {
  const _InfoBanner({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: scheme.surface.withValues(alpha: 0.82),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.55),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: scheme.secondary.withValues(alpha: 0.12),
              border: Border.all(
                color: scheme.secondary.withValues(alpha: 0.20),
              ),
            ),
            child: Icon(icon, size: 18, color: scheme.secondary),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LocalizedText(
                  title,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w900,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 6),
                LocalizedText(
                  body,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.3,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface.withValues(alpha: 0.72),
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

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.error_outline_rounded, size: 40, color: scheme.error),
        const SizedBox(height: 10),
        LocalizedText(
          message,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: scheme.onSurface.withValues(alpha: 0.75),
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: onRetry,
          icon: const Icon(Icons.refresh_rounded),
          label: const LocalizedText('إعادة المحاولة'),
        ),
      ],
    );
  }
}

class _PaymentMethodPicker extends StatelessWidget {
  const _PaymentMethodPicker({required this.methods});

  final List<PaymentMethod> methods;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LocalizedText(
              'اختر وسيلة الدفع',
              style: TextStyle(
                fontSize: 16.5,
                fontWeight: FontWeight.w900,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: 6),
            LocalizedText(
              'اختر طريقة الدفع المناسبة لإرسال طلب الاشتراك.',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: scheme.onSurface.withValues(alpha: 0.65),
              ),
            ),
            const SizedBox(height: 14),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: methods.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (context, i) {
                  final m = methods[i];
                  return Material(
                    color: scheme.surface,
                    borderRadius: BorderRadius.circular(18),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(18),
                      onTap: () => Navigator.of(context).pop(m),
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(
                            color: scheme.outlineVariant.withValues(
                              alpha: 0.55,
                            ),
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(14),
                                color: scheme.surfaceContainerHighest
                                    .withValues(alpha: 0.7),
                                border: Border.all(
                                  color: scheme.outlineVariant.withValues(
                                    alpha: 0.45,
                                  ),
                                ),
                              ),
                              child: (m.logoUrl == null || m.logoUrl!.isEmpty)
                                  ? Icon(
                                      Icons.account_balance_rounded,
                                      color: scheme.primary,
                                    )
                                  : ClipRRect(
                                      borderRadius: BorderRadius.circular(14),
                                      child: Image.network(
                                        m.logoUrl!,
                                        fit: BoxFit.cover,
                                        errorBuilder: (_, __, ___) => Icon(
                                          Icons.account_balance_rounded,
                                          color: scheme.primary,
                                        ),
                                      ),
                                    ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    m.name,
                                    style: TextStyle(
                                      fontWeight: FontWeight.w900,
                                      color: scheme.onSurface,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  LocalizedText(
                                    'الحساب: ${m.bankAccount}',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w700,
                                      color: scheme.onSurface.withValues(
                                        alpha: 0.65,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Icon(
                              context.isRtl
                                  ? Icons.chevron_left_rounded
                                  : Icons.chevron_right_rounded,
                              color: scheme.onSurface.withValues(alpha: 0.6),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
