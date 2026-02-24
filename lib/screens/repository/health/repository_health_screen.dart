import 'dart:ui' as ui show TextDirection;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:aelmamclinic/models/inventory_health_report.dart';
import 'package:aelmamclinic/providers/repository_provider.dart';

const Color accentColor = Color(0xFF004A61);
const Color lightAccentColor = Color(0xFF9ED9E6);
const Color veryLightBg = Color(0xFFF7F9F9);

class RepositoryHealthScreen extends StatefulWidget {
  const RepositoryHealthScreen({super.key});

  static const routeName = '/repository/health';

  @override
  State<RepositoryHealthScreen> createState() =>
      _RepositoryHealthScreenState();
}

class _RepositoryHealthScreenState extends State<RepositoryHealthScreen> {
  late Future<InventoryHealthReport> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<InventoryHealthReport> _load() async {
    return context.read<RepositoryProvider>().fetchHealthReport();
  }

  Future<void> _repair() async {
    await context.read<RepositoryProvider>().repairInventoryIntegrity(backup: true);
    setState(() => _future = _load());
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          centerTitle: true,
          title: const Text('تشخيص صحة المستودع',
              style: TextStyle(fontWeight: FontWeight.bold)),
          flexibleSpace: const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [lightAccentColor, accentColor],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
          ),
        ),
        body: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [veryLightBg, Colors.white, veryLightBg],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
          child: FutureBuilder<InventoryHealthReport>(
            future: _future,
            builder: (ctx, snap) {
              if (!snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final report = snap.data!;
              return ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _InfoCard(
                    title: 'الأنواع',
                    value: report.itemTypes,
                    icon: Icons.category_outlined,
                  ),
                  _InfoCard(
                    title: 'الأصناف',
                    value: report.items,
                    icon: Icons.inventory_2_outlined,
                  ),
                  _InfoCard(
                    title: 'أصناف بدون نوع',
                    value: report.orphanItems,
                    icon: Icons.report_gmailerrorred,
                    warning: report.orphanItems > 0,
                  ),
                  _InfoCard(
                    title: 'مشتريات بلا صنف',
                    value: report.orphanPurchases,
                    icon: Icons.shopping_cart_outlined,
                    warning: report.orphanPurchases > 0,
                  ),
                  _InfoCard(
                    title: 'استهلاكات بلا صنف',
                    value: report.orphanConsumptions,
                    icon: Icons.local_fire_department_outlined,
                    warning: report.orphanConsumptions > 0,
                  ),
                  _InfoCard(
                    title: 'سجلات بلا حساب',
                    value: report.missingAccountRows,
                    icon: Icons.warning_amber_rounded,
                    warning: report.missingAccountRows > 0,
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton.icon(
                    onPressed: _repair,
                    icon: const Icon(Icons.build_circle_outlined),
                    label: const Text('إصلاح تلقائي'),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  final String title;
  final int value;
  final IconData icon;
  final bool warning;

  const _InfoCard({
    required this.title,
    required this.value,
    required this.icon,
    this.warning = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = warning ? Colors.deepOrange : accentColor;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ListTile(
        leading: Icon(icon, color: color),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        trailing: Text(
          '$value',
          style: TextStyle(
            fontWeight: FontWeight.w900,
            color: color,
            fontSize: 16,
          ),
        ),
      ),
    );
  }
}
