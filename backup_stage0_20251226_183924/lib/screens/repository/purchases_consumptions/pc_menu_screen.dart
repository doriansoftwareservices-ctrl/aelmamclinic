// lib/screens/repository/purchases_consumptions/pc_menu_screen.dart

import 'dart:ui' as ui show TextDirection;
import 'package:flutter/material.dart';

/*── تصميم TBIAN ─*/
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';

/// القائمة الفرعية للمشتريات والاستهلاكات ببصمة TBIAN/Neumorphism
class PcMenuScreen extends StatelessWidget {
  const PcMenuScreen({super.key});

  static const routeName = '/repository/pc/menu';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

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
              const Text('ELMAM CLINIC'),
            ],
          ),
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
            children: [
              // بطاقة مقدّمة صغيرة
              NeuCard(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Row(
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        color: kPrimaryColor.withValues(alpha: .10),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      padding: const EdgeInsets.all(10),
                      child: const Icon(Icons.inventory_2_rounded,
                          color: kPrimaryColor, size: 22),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'اختر واحدة من الخيارات لإدارة المشتريات والاستهلاكات.',
                        style: TextStyle(
                          color: scheme.onSurface.withValues(alpha: .85),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // شبكة القوائم (نيومورفيزم)
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 16,
                runSpacing: 16,
                children: [
                  _MenuTile(
                    icon: Icons.add_shopping_cart_outlined,
                    title: 'إنشاء مشتريات جديدة',
                    subtitle: 'إدخال فاتورة شراء وتحديث المخزون',
                    onTap: () =>
                        Navigator.pushNamed(context, '/repository/pc/new'),
                  ),
                  _MenuTile(
                    icon: Icons.receipt_long_outlined,
                    title: 'عرض المشتريات والاستهلاكات',
                    subtitle: 'استعراض/فلترة الفواتير وحركات الصرف',
                    onTap: () =>
                        Navigator.pushNamed(context, '/repository/pc/view'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// بطاقة قائمة رئيسية وفق TBIAN/Neumorphism
class _MenuTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _MenuTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return SizedBox(
      width: 320,
      child: NeuCard(
        onTap: onTap,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Row(
          children: [
            // أيقونة داخل كبسولة ملوّنة خفيفة
            Container(
              decoration: BoxDecoration(
                color: kPrimaryColor.withValues(alpha: .10),
                borderRadius: BorderRadius.circular(16),
              ),
              padding: const EdgeInsets.all(12),
              child: Icon(icon, color: kPrimaryColor, size: 22),
            ),
            const SizedBox(width: 12),
            // نصوص
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontWeight: FontWeight.w900, fontSize: 16)),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: scheme.onSurface.withValues(alpha: .75),
                      fontWeight: FontWeight.w600,
                      fontSize: 13.5,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Icon(Icons.chevron_left_rounded,
                color: scheme.onSurface.withValues(alpha: .6)),
          ],
        ),
      ),
    );
  }
}
