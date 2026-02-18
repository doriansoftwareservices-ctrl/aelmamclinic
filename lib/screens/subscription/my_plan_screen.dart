import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/models/payment_method.dart';
import 'package:aelmamclinic/models/subscription_plan.dart';
import 'package:aelmamclinic/providers/auth_provider.dart';
import 'package:aelmamclinic/services/billing_service.dart';
import 'package:aelmamclinic/screens/subscription/payment_request_screen.dart';

class MyPlanScreen extends StatefulWidget {
  const MyPlanScreen({super.key});

  @override
  State<MyPlanScreen> createState() => _MyPlanScreenState();
}

class _MyPlanScreenState extends State<MyPlanScreen> {
  final BillingService _billing = BillingService();

  bool _loading = true;
  List<SubscriptionPlan> _plans = const [];
  String _currentPlan = 'free';
  DateTime? _planEndAt;
  String? _error;

  final _currency = NumberFormat.currency(symbol: '\$', decimalDigits: 0);

  // ✅ نفس مزايا الشهري والسنوي — الفرق فقط مدة الاشتراك.
  static const List<String> _paidFeatures = [
    'لوحة التحكم',
    'إضافة المرضى',
    'قائمة المرضى',
    'استخراج تقارير للمرضى',
    'ادارة المخزن',
    'المرتجعات',
    'اضافة طبيب وخدماته',
    'الموظفون',
    'المدفوعات',
    'المختبر/الأشعة (تحت التطوير)',
    'الرسوم البيانية',
    'المستودع/المخزون',
    'الوصفات الطبية',
    'النسخ الاحتياطي',
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

  static const List<String> _employeesPolicy = [
    'الحد الأساسي: حتى 5 موظفين للعيادة.',
    'كل موظف إضافي على العدد الأساسي: 50$.',
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      setState(() {
        _loading = true;
        _error = null;
      });

      final plans = await _billing.fetchPlans();
      final details = await _billing.fetchMyPlanDetails();

      final planCode = details['plan_code']?.toString().toLowerCase() ?? 'free';
      final planEndRaw = details['plan_end_at']?.toString();
      final planEndAt = planEndRaw == null ? null : DateTime.tryParse(planEndRaw);

      if (!mounted) return;
      setState(() {
        _plans = plans.where((p) => p.isActive).toList();
        _currentPlan = planCode;
        _planEndAt = planEndAt;
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

  Future<void> _startUpgrade(SubscriptionPlan plan) async {
    final methods = await _billing.fetchPaymentMethods();
    if (!mounted) return;

    if (methods.isEmpty) {
      _snack('لا توجد وسائل دفع متاحة حاليًا.');
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

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  String _currentPlanName() {
    for (final p in _plans) {
      if (p.code.toLowerCase() == _currentPlan.toLowerCase()) return p.name;
    }
    return _currentPlan.toUpperCase();
  }

  bool _isAnnualByCode(String code) {
    final c = code.toLowerCase();
    return c.contains('year') || c.contains('annual') || c.contains('yearly');
  }

  String _cycleLabelByCode(String code) {
    final c = code.toLowerCase();
    if (c.contains('month') || c.contains('monthly')) return 'شهري';
    if (_isAnnualByCode(c)) return 'سنوي';
    return 'اشتراك';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final auth = context.watch<AuthProvider>();

    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Scaffold(
        backgroundColor: scheme.surface,
        appBar: AppBar(
          title: const Text('خطتي'),
          centerTitle: false,
        ),
        body: Stack(
          children: [
            _AnimatedBubbleBackdrop(scheme: scheme),
            SafeArea(
              child: Padding(
                padding: kScreenPadding,
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _error != null
                        ? Center(
                            child: _ErrorState(
                              message: _error!,
                              onRetry: _load,
                            ),
                          )
                        : LayoutBuilder(
                            builder: (context, constraints) {
                              final w = constraints.maxWidth;

                              // ✅ عرض كروت كـ "أعمدة" في الشاشات الواسعة، وعمودي (واحد تحت واحد) على الجوال.
                              final columns = w >= 1100
                                  ? 3
                                  : w >= 760
                                      ? 2
                                      : 1;

                              final spacing = 14.0;
                              final cardWidth = (w - (spacing * (columns - 1))) / columns;

                              return SingleChildScrollView(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    _PlanHeaderModern(
                                      currentPlanName: _currentPlanName(),
                                      currentPlanCode: _currentPlan,
                                      planEndAt: _planEndAt,
                                    ),
                                    const SizedBox(height: 14),

                                    _SectionTitle(
                                      title: 'الخطط المتاحة',
                                      subtitle: 'اختر الخطة المناسبة—المزايا موضّحة داخل كل كرت.',
                                    ),
                                    const SizedBox(height: 12),

                                    Wrap(
                                      spacing: spacing,
                                      runSpacing: spacing,
                                      children: _plans.map((plan) {
                                        final isCurrent = plan.code.toLowerCase() == _currentPlan.toLowerCase();
                                        final isFree = plan.code.toLowerCase() == 'free';
                                        final canUpgrade = auth.isLoggedIn && !isCurrent && !isFree;

                                        final isAnnual = _isAnnualByCode(plan.code);
                                        final priceMain = isFree ? 'مجانية' : _currency.format(plan.priceUsd);
                                        final priceSuffix = '';

                                        return SizedBox(
                                          width: cardWidth,
                                          child: _PlanPricingCard(
                                            planName: plan.name,
                                            planCode: plan.code,
                                            isCurrent: isCurrent,
                                            isFree: isFree,
                                            isAnnual: isAnnual,
                                            priceMain: priceMain,
                                            priceSuffix: priceSuffix,
                                            features: isFree ? _freeFeatures : _paidFeatures,
                                            employeesPolicy: isFree ? const [] : _employeesPolicy,
                                            canUpgrade: canUpgrade,
                                            onUpgrade: () => _startUpgrade(plan),
                                            // إذا غير مسجل دخول: زر بشكل أنيق لكن غير مفعل
                                            onNeedLogin: () => _snack('سجّل الدخول أولاً لطلب الترقية.'),
                                          ),
                                        );
                                      }).toList(),
                                    ),

                                    const SizedBox(height: 18),

                                    if (!auth.isLoggedIn)
                                      _InfoBanner(
                                        icon: Icons.lock_rounded,
                                        title: 'ملاحظة',
                                        body: 'لا يمكنك طلب ترقية قبل تسجيل الدخول.',
                                      ),

                                    const SizedBox(height: 24),

                                    Divider(color: scheme.outlineVariant.withValues(alpha: 0.5)),
                                    const SizedBox(height: 10),

                                    _InfoBanner(
                                      icon: Icons.groups_rounded,
                                      title: 'سياسة الموظفين',
                                      body: _employeesPolicy.join('\n'),
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
  late final List<_BubbleParticle> _bubbles;
  Size _size = Size.zero;
  Duration? _lastTick;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 10),
    )..repeat();
    _bubbles = _createBubbles(widget.scheme);
    _controller.addListener(_tick);
  }

  @override
  void didUpdateWidget(covariant _AnimatedBubbleBackdrop oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scheme != widget.scheme) {
      _bubbles.clear();
      _bubbles.addAll(_createBubbles(widget.scheme));
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  List<_BubbleParticle> _createBubbles(ColorScheme scheme) {
    final rng = math.Random(42);
    return List.generate(28, (i) {
      final radius = 11 + rng.nextDouble() * 14;
      final x = rng.nextDouble();
      final y = rng.nextDouble();
      final speed = 8 + rng.nextDouble() * 14;
      final angle = rng.nextDouble() * math.pi * 2;
      final vx = math.cos(angle) * speed;
      final vy = math.sin(angle) * speed;
      final color = (i % 3 == 0
              ? scheme.primary
              : (i % 3 == 1 ? scheme.secondary : scheme.tertiary))
          .withValues(alpha: 0.18);
      return _BubbleParticle(
        pos: Offset(x, y),
        vel: Offset(vx, vy),
        radius: radius,
        color: color,
      );
    });
  }

  void _ensureSize(Size size) {
    if (_size == size || size.isEmpty) return;
    _size = size;
    for (final b in _bubbles) {
      if (!b.initialized) {
        b.pos = Offset(b.pos.dx * _size.width, b.pos.dy * _size.height);
        b.initialized = true;
      }
    }
  }

  void _tick() {
    if (!mounted || _size.isEmpty) return;
    final elapsed = _controller.lastElapsedDuration;
    if (elapsed == null) return;
    final last = _lastTick ?? elapsed;
    final dt = (elapsed - last).inMicroseconds / 1e6;
    _lastTick = elapsed;
    if (dt <= 0) return;
    _step(dt.clamp(0.0, 0.05));
  }

  void _step(double dt) {
    for (final b in _bubbles) {
      b.pos = Offset(b.pos.dx + b.vel.dx * dt, b.pos.dy + b.vel.dy * dt);

      if (b.pos.dx - b.radius < 0) {
        b.pos = Offset(b.radius, b.pos.dy);
        b.vel = Offset(-b.vel.dx, b.vel.dy);
      } else if (b.pos.dx + b.radius > _size.width) {
        b.pos = Offset(_size.width - b.radius, b.pos.dy);
        b.vel = Offset(-b.vel.dx, b.vel.dy);
      }
      if (b.pos.dy - b.radius < 0) {
        b.pos = Offset(b.pos.dx, b.radius);
        b.vel = Offset(b.vel.dx, -b.vel.dy);
      } else if (b.pos.dy + b.radius > _size.height) {
        b.pos = Offset(b.pos.dx, _size.height - b.radius);
        b.vel = Offset(b.vel.dx, -b.vel.dy);
      }
    }

    for (var i = 0; i < _bubbles.length; i++) {
      for (var j = i + 1; j < _bubbles.length; j++) {
        final a = _bubbles[i];
        final b = _bubbles[j];
        final dx = b.pos.dx - a.pos.dx;
        final dy = b.pos.dy - a.pos.dy;
        final dist = math.sqrt(dx * dx + dy * dy);
        final minDist = a.radius + b.radius;
        if (dist == 0 || dist >= minDist) continue;

        final nx = dx / dist;
        final ny = dy / dist;
        final rvx = b.vel.dx - a.vel.dx;
        final rvy = b.vel.dy - a.vel.dy;
        final velAlongNormal = rvx * nx + rvy * ny;

        if (velAlongNormal < 0) {
          final impulse = -velAlongNormal;
          a.vel = Offset(a.vel.dx - impulse * nx, a.vel.dy - impulse * ny);
          b.vel = Offset(b.vel.dx + impulse * nx, b.vel.dy + impulse * ny);
        }

        final overlap = minDist - dist;
        if (overlap > 0) {
          final correction = overlap / 2;
          a.pos = Offset(a.pos.dx - nx * correction, a.pos.dy - ny * correction);
          b.pos = Offset(b.pos.dx + nx * correction, b.pos.dy + ny * correction);
        }
      }
    }

    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: LayoutBuilder(
        builder: (context, constraints) {
          _ensureSize(constraints.biggest);
          return CustomPaint(
            painter: _BubblePainter(
              bubbles: _bubbles,
              scheme: widget.scheme,
            ),
          );
        },
      ),
    );
  }
}

class _BubbleParticle {
  _BubbleParticle({
    required this.pos,
    required this.vel,
    required this.radius,
    required this.color,
  });

  Offset pos;
  Offset vel;
  final double radius;
  final Color color;
  bool initialized = false;
}

class _BubblePainter extends CustomPainter {
  _BubblePainter({
    required this.bubbles,
    required this.scheme,
  });

  final List<_BubbleParticle> bubbles;
  final ColorScheme scheme;

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

    for (final bubble in bubbles) {
      final paint = Paint()..color = bubble.color;
      canvas.drawCircle(bubble.pos, bubble.radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _BubblePainter oldDelegate) {
    return oldDelegate.bubbles != bubbles || oldDelegate.scheme != scheme;
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
            fontSize: 18,
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
            color: scheme.onSurface.withValues(alpha: 0.65),
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _PlanHeaderModern extends StatelessWidget {
  const _PlanHeaderModern({
    required this.currentPlanName,
    required this.currentPlanCode,
    required this.planEndAt,
  });

  final String currentPlanName;
  final String currentPlanCode;
  final DateTime? planEndAt;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isFree = currentPlanCode.toLowerCase() == 'free';

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
            child: Icon(
              Icons.workspace_premium_rounded,
              color: scheme.primary,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'الخطة الحالية',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                    color: scheme.onSurface.withValues(alpha: 0.65),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  currentPlanName,
                  style: TextStyle(
                    fontSize: 16.5,
                    fontWeight: FontWeight.w900,
                    color: scheme.onSurface,
                  ),
                ),
                if (!isFree && planEndAt != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    'تنتهي: ${DateFormat('yyyy-MM-dd').format(planEndAt!)}',
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
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              color: isFree
                  ? scheme.secondary.withValues(alpha: 0.14)
                  : scheme.primary.withValues(alpha: 0.14),
              border: Border.all(
                color: isFree
                    ? scheme.secondary.withValues(alpha: 0.25)
                    : scheme.primary.withValues(alpha: 0.25),
              ),
            ),
            child: Text(
              isFree ? 'مجانية' : 'مدفوعة',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w900,
                color: isFree ? scheme.secondary : scheme.primary,
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

  IconData get _planIcon {
    if (isFree) return Icons.rocket_launch_rounded;
    if (isAnnual) return Icons.auto_awesome_rounded;
    return Icons.stars_rounded;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    final accent = isCurrent
        ? scheme.primary
        : (isFree ? scheme.secondary : scheme.tertiary);

    const surface = Colors.transparent;

    final badgeText = isCurrent
        ? 'الخطة الحالية'
        : (isAnnual && !isFree ? 'أفضل قيمة' : null);

    final subtitle = isFree
        ? 'ابدأ مجانًا واستكشف الأساسيات.'
        : (isAnnual
            ? 'اشتراك سنوي بوفرة وتوفير أكبر لجميع المزايا لمدة 12 شهر.'
            : 'اشتراك شهري مرن مع كل المزايا وتجديد شهري.');

    final buttonLabel = isCurrent
        ? 'الخطة الحالية'
        : (isFree ? 'الخطة المجانية' : 'طلب ترقية');

    final isButtonEnabled = !isCurrent && !isFree && canUpgrade;

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.25),
          width: 0.7,
        ),
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
                          border: Border.all(color: accent.withValues(alpha: 0.22)),
                        ),
                        child: Icon(_planIcon, color: accent),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              planName,
                              style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w900,
                                color: scheme.onSurface,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              subtitle,
                              style: TextStyle(
                                fontSize: 12.5,
                                height: 1.25,
                                fontWeight: FontWeight.w600,
                                color: scheme.onSurface.withValues(alpha: 0.62),
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (badgeText != null) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(999),
                            color: accent.withValues(alpha: 0.14),
                            border: Border.all(color: accent.withValues(alpha: 0.22)),
                          ),
                          child: Text(
                            badgeText,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w900,
                              color: accent,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),

                  const SizedBox(height: 14),

                  // Price
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(18),
                      gradient: LinearGradient(
                        colors: [
                          accent.withValues(alpha: 0.14),
                          scheme.surfaceContainerHighest.withValues(alpha: 0.40),
                        ],
                        begin: Alignment.topRight,
                        end: Alignment.bottomLeft,
                      ),
                      border: Border.all(color: accent.withValues(alpha: 0.18)),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.payments_rounded, color: scheme.onSurface.withValues(alpha: 0.7), size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: RichText(
                            text: TextSpan(
                              children: [
                                TextSpan(
                                  text: priceMain,
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
                                      color: scheme.onSurface.withValues(alpha: 0.65),
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
                  ...features.map((f) => _FeatureRow(text: f, accent: accent)),

                  if (employeesPolicy.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Divider(color: scheme.outlineVariant.withValues(alpha: 0.5)),
                    const SizedBox(height: 10),
                    _CardSectionLabel(
                      icon: Icons.groups_rounded,
                      title: 'سياسة الموظفين',
                      accent: accent,
                    ),
                    const SizedBox(height: 10),
                    ...employeesPolicy.map((p) => _FeatureRow(
                          text: p,
                          accent: accent,
                          icon: Icons.info_rounded,
                        )),
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
                      child: Text(
                        buttonLabel,
                        style: const TextStyle(fontWeight: FontWeight.w900),
                      ),
                    ),
                  ),

                  // Small note for non-current paid plan when user not logged in
                  if (!isFree && !isCurrent && !canUpgrade) ...[
                    const SizedBox(height: 10),
                    Text(
                      'سجّل الدخول لإرسال طلب الترقية.',
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
        Text(
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

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            icon,
            size: 18,
            color: accent.withValues(alpha: 0.9),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12.8,
                height: 1.25,
                fontWeight: FontWeight.w700,
                color: scheme.onSurface.withValues(alpha: 0.80),
              ),
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
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.55)),
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
              border: Border.all(color: scheme.secondary.withValues(alpha: 0.20)),
            ),
            child: Icon(icon, size: 18, color: scheme.secondary),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w900,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
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
        Text(
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
          label: const Text('إعادة المحاولة'),
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
            Text(
              'اختر وسيلة الدفع',
              style: TextStyle(
                fontSize: 16.5,
                fontWeight: FontWeight.w900,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: 6),
            Text(
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
                            color: scheme.outlineVariant.withValues(alpha: 0.55),
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(14),
                                color: scheme.surfaceContainerHighest.withValues(alpha: 0.7),
                                border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.45)),
                              ),
                              child: (m.logoUrl == null || m.logoUrl!.isEmpty)
                                  ? Icon(Icons.account_balance_rounded, color: scheme.primary)
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
                                  Text(
                                    'الحساب: ${m.bankAccount}',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w700,
                                      color: scheme.onSurface.withValues(alpha: 0.65),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Icon(Icons.chevron_left_rounded, color: scheme.onSurface.withValues(alpha: 0.6)),
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
