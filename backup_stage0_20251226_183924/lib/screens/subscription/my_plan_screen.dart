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
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final auth = context.watch<AuthProvider>();

    return Scaffold(
      appBar: AppBar(title: const Text('خطتي')),
      body: SafeArea(
        child: Padding(
          padding: kScreenPadding,
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Center(child: Text(_error!))
                  : ListView(
                      children: [
                        Text(
                          'الخطة الحالية: ${_currentPlan.toUpperCase()}',
                          style: TextStyle(
                            color: scheme.primary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (_planEndAt != null &&
                            _currentPlan != 'free') ...[
                          const SizedBox(height: 6),
                          Text(
                            'تنتهي في: ${DateFormat('yyyy-MM-dd').format(_planEndAt!)}',
                            style: TextStyle(
                              color: scheme.onSurface.withValues(alpha: 0.7),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                        const SizedBox(height: 12),
                        ..._plans.map((plan) {
                          final isCurrent = plan.code == _currentPlan;
                          final isFree = plan.code == 'free';
                          return _PlanCard(
                            plan: plan,
                            isCurrent: isCurrent,
                            isFree: isFree,
                            canUpgrade: auth.isLoggedIn && !isCurrent && !isFree,
                            onUpgrade: () => _startUpgrade(plan),
                          );
                        }),
                      ],
                    ),
        ),
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.plan,
    required this.isCurrent,
    required this.isFree,
    required this.canUpgrade,
    required this.onUpgrade,
  });

  final SubscriptionPlan plan;
  final bool isCurrent;
  final bool isFree;
  final bool canUpgrade;
  final VoidCallback onUpgrade;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final badgeColor =
        isCurrent ? scheme.primary : scheme.onSurface.withValues(alpha: 0.4);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: NeuCard(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  plan.name,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(width: 8),
                if (isCurrent)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: badgeColor.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      'الخطة الحالية',
                      style: TextStyle(
                        color: badgeColor,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              isFree
                  ? 'مجانية مع صلاحيات محدودة'
                  : 'السعر: \$${plan.priceUsd.toStringAsFixed(0)}',
              style: TextStyle(
                color: scheme.onSurface.withValues(alpha: 0.7),
              ),
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
