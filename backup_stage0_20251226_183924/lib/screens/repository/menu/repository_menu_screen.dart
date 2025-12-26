// lib/screens/repository/menu/repository_menu_screen.dart
import 'dart:ui' as ui show TextDirection;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/*── تصميم TBIAN ─*/
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';

import 'package:aelmamclinic/providers/repository_provider.dart';

class RepositoryMenuScreen extends StatelessWidget {
  const RepositoryMenuScreen({super.key});

  static const routeName = '/repository/menu';

  @override
  Widget build(BuildContext context) {
    final repoProvider = context.watch<RepositoryProvider>();
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
          leading: IconButton(
            tooltip: 'رجوع',
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.arrow_back_rounded),
          ),
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // رأس القسم
                Text(
                  'قسم المستودع',
                  style: TextStyle(
                    color: scheme.onSurface,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 14),

                // شبكة الأزرار (نيومورفيزم)
                Directionality(
                  textDirection: ui.TextDirection.rtl,
                  child: Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 16,
                    runSpacing: 18,
                    children: [
                      _MenuTile(
                        icon: Icons.add_box_outlined,
                        label: 'إضافة صنف جديد',
                        onTap: () => Navigator.pushNamed(
                            context, '/repository/items/add'),
                      ),
                      _MenuTile(
                        icon: Icons.view_list_outlined,
                        label: 'استعراض الأصناف المضافة',
                        onTap: () => Navigator.pushNamed(
                            context, '/repository/items/view'),
                      ),
                      _MenuTile(
                        icon: Icons.swap_vert_circle_outlined,
                        label: 'مشتريات واستهلاكات المستودع',
                        onTap: () =>
                            Navigator.pushNamed(context, '/repository/pc/menu'),
                      ),
                      _MenuTile(
                        icon: Icons.insights_outlined,
                        label: 'إحصائيات وكشوفات المستودع',
                        onTap: () => Navigator.pushNamed(
                            context, '/repository/statistics'),
                      ),
                      _MenuTile(
                        icon: Icons.notifications_active_outlined,
                        label: 'تنبيه قرب النفاد',
                        showBadge: repoProvider.hasLowStockBadge,
                        onTap: () =>
                            Navigator.pushNamed(context, '/repository/alerts'),
                      ),
                    ],
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

/*──────── عنصر زر بطاقة بنمط TBIAN/Neumorphism ────────*/
class _MenuTile extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool showBadge;

  const _MenuTile({
    required this.label,
    required this.onTap,
    required this.icon,
    this.showBadge = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    final tile = NeuCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      child: SizedBox(
        width: 220, // عرض مريح على Windows و Android
        height: 120,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // أيقونة داخل حاوية بلون أساسي خفيف (مطابق لأسلوب الإحصاءات)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: Container(
                decoration: BoxDecoration(
                  color: kPrimaryColor.withValues(alpha: .10),
                  borderRadius: BorderRadius.circular(14),
                ),
                padding: const EdgeInsets.all(10),
                child: Icon(icon, color: kPrimaryColor, size: 24),
              ),
            ),
            const SizedBox(height: 12),
            // العنوان
            Expanded(
              child: Center(
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: scheme.onSurface,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    // شارة تنبيه حمراء صغيرة (عند وجود أصناف منخفضة)
    return Stack(
      clipBehavior: Clip.none,
      children: [
        tile,
        if (showBadge)
          const Positioned(
            right: 10,
            top: 10,
            child: CircleAvatar(
              radius: 6,
              backgroundColor: Colors.red,
            ),
          ),
      ],
    );
  }
}
