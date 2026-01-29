import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import 'package:aelmamclinic/core/neumorphism.dart';
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
      final planEndAt =
          planEndRaw == null ? null : DateTime.tryParse(planEndRaw);
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
      showDragHandle: true,
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final auth = context.watch<AuthProvider>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('خطتي'),
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              scheme.surface,
              scheme.surfaceContainerHighest.withValues(alpha: 0.6),
              scheme.surface,
            ],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: kScreenPadding,
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(child: Text(_error!))
                    : ListView(
                        children: [
                          _PlanHeader(
                            currentPlan: _currentPlan,
                            planEndAt: _planEndAt,
                          ),
                          const SizedBox(height: 16),
                          ..._plans.map((plan) {
                            final isCurrent = plan.code == _currentPlan;
                            final isFree = plan.code == 'free';
                            return _PlanTile3D(
                              plan: plan,
                              isCurrent: isCurrent,
                              isFree: isFree,
                              canUpgrade:
                                  auth.isLoggedIn && !isCurrent && !isFree,
                              priceLabel: isFree
                                  ? 'مجانية'
                                  : _currency.format(plan.priceUsd),
                              onUpgrade: () => _startUpgrade(plan),
                            );
                          }),
                          const SizedBox(height: 24),
                        ],
                      ),
          ),
        ),
      ),
    );
  }
}

class _PlanHeader extends StatelessWidget {
  const _PlanHeader({
    required this.currentPlan,
    required this.planEndAt,
  });

  final String currentPlan;
  final DateTime? planEndAt;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'خطتي الحالية',
          style: TextStyle(
            color: scheme.primary,
            fontWeight: FontWeight.w800,
            fontSize: 18,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: scheme.primary.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: scheme.primary.withValues(alpha: 0.2),
            ),
          ),
          child: Row(
            children: [
              Icon(Icons.stars_rounded, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  currentPlan.toUpperCase(),
                  style: TextStyle(
                    color: scheme.primary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              if (planEndAt != null && currentPlan != 'free')
                Text(
                  'تنتهي: ${DateFormat('yyyy-MM-dd').format(planEndAt!)}',
                  style: TextStyle(
                    color: scheme.onSurface.withValues(alpha: 0.6),
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PlanTile3D extends StatelessWidget {
  const _PlanTile3D({
    required this.plan,
    required this.isCurrent,
    required this.isFree,
    required this.canUpgrade,
    required this.priceLabel,
    required this.onUpgrade,
  });

  final SubscriptionPlan plan;
  final bool isCurrent;
  final bool isFree;
  final bool canUpgrade;
  final String priceLabel;
  final VoidCallback onUpgrade;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final titleColor = isCurrent ? scheme.primary : scheme.onSurface;
    final glow = isCurrent ? scheme.primary : scheme.secondary;
    final gradient = isFree
        ? [scheme.surface, scheme.surfaceContainerHighest]
        : [scheme.surface, glow.withValues(alpha: 0.08)];

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          gradient: LinearGradient(
            colors: gradient,
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.08),
              offset: const Offset(0, 12),
              blurRadius: 22,
            ),
            BoxShadow(
              color: glow.withValues(alpha: 0.18),
              offset: const Offset(-4, -4),
              blurRadius: 12,
            ),
          ],
          border: Border.all(
            color: scheme.outlineVariant.withValues(alpha: 0.4),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      plan.name,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: titleColor,
                      ),
                    ),
                  ),
                  if (isCurrent)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: scheme.primary.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        'الخطة الحالية',
                        style: TextStyle(
                          color: scheme.primary,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Icon(
                    Icons.payments_rounded,
                    size: 18,
                    color: scheme.onSurface.withValues(alpha: 0.7),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    priceLabel,
                    style: TextStyle(
                      color: scheme.onSurface.withValues(alpha: 0.7),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (canUpgrade)
                Align(
                  alignment: Alignment.centerLeft,
                  child: NeuButton.primary(
                    label: 'طلب ترقية',
                    onPressed: onUpgrade,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PaymentMethodPicker extends StatelessWidget {
  const _PaymentMethodPicker({required this.methods});

  final List<PaymentMethod> methods;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'اختر وسيلة الدفع',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: scheme.primary,
            ),
          ),
          const SizedBox(height: 12),
          ...methods.map(
            (m) => NeuCard(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              margin: const EdgeInsets.symmetric(vertical: 6),
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: m.logoUrl == null || m.logoUrl!.isEmpty
                    ? const Icon(Icons.account_balance_rounded)
                    : Image.network(
                        m.logoUrl!,
                        width: 40,
                        height: 40,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) =>
                            const Icon(Icons.account_balance_rounded),
                      ),
                title: Text(m.name),
                subtitle: Text('الحساب: ${m.bankAccount}'),
                onTap: () => Navigator.of(context).pop(m),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
