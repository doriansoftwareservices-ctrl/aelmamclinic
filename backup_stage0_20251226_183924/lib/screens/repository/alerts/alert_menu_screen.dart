// lib/screens/repository/alerts/alert_menu_screen.dart
import 'dart:ui' as ui show TextDirection;
import 'package:flutter/material.dart';

/*── تصميم TBIAN ─*/
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/tbian_ui.dart';

/// القائمة الفرعيّة لتنبيهات «قرب النفاد» بتصميم موحّد مع شاشات TBIAN.
class AlertMenuScreen extends StatelessWidget {
  const AlertMenuScreen({super.key});

  static const routeName = '/repository/alerts';

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
                const TSectionHeader('تنبيه قرب النفاد'),
                const SizedBox(height: 8),
                Text(
                  'اضبط تنبيهات انخفاض الكميات، واستعرض التنبيهات الحالية بسرعة.',
                  style: TextStyle(
                    color: scheme.onSurface.withValues(alpha: .75),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 18),

                // أزرار القائمة (Neumorphism)
                Center(
                  child: Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 16,
                    runSpacing: 18,
                    children: const [
                      _MenuTile(
                        icon: Icons.add_alert_outlined,
                        title: 'إنشاء توقيت تنبيه',
                        subtitle: 'ضبط شرط ومستوى الكمية',
                        routeName: '/repository/alerts/create',
                      ),
                      _MenuTile(
                        icon: Icons.notifications_active_outlined,
                        title: 'استعراض التنبيهات',
                        subtitle: 'عرض التنبيهات الحالية وإدارتها',
                        routeName: '/repository/alerts/view',
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

/*──────────────────────── عنصر بطاقة قائمة بنمط TBIAN/Neumorphism ────────────────────────*/

class _MenuTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final String routeName;

  const _MenuTile({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.routeName,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return NeuCard(
      onTap: () => Navigator.pushNamed(context, routeName),
      padding: const EdgeInsets.all(16),
      child: SizedBox(
        width: 260,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // أيقونة داخل حاوية بلون أساسي خفيف (مطابق للنمط في بقية الشاشات)
            Container(
              decoration: BoxDecoration(
                color: kPrimaryColor.withValues(alpha: .10),
                borderRadius: BorderRadius.circular(14),
              ),
              padding: const EdgeInsets.all(10),
              child: Icon(icon, color: kPrimaryColor, size: 24),
            ),
            const SizedBox(width: 12),

            // نصوص العنوان والوصف
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 15.5,
                    ),
                  ),
                  if ((subtitle ?? '').isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      subtitle!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: scheme.onSurface.withValues(alpha: .75),
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),

            // سهم تنقل خفيف
            Icon(
              Icons.chevron_left_rounded,
              color: scheme.onSurface.withValues(alpha: .8),
            ),
          ],
        ),
      ),
    );
  }
}
