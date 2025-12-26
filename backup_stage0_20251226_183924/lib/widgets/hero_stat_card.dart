import 'package:flutter/material.dart';

/// lib/widgets/hero_stat_card.dart
///
/// البطاقة الإحصائية مع دعم لون مخصص (accent)
class HeroStatCard extends StatelessWidget {
  /// عنوان البطاقة
  final String title;

  /// القيمة المعروضة
  final String value;

  /// أيقونة البطاقة
  final IconData icon;

  /// رد فعل عند النقر (اختياري)
  final VoidCallback? onTap;

  /// اللون المميز للأيقونة والنص. إذا لم يُمرَّر يُستخدم theme.colorScheme.primary
  final Color? accent;

  const HeroStatCard({
    super.key,
    required this.title,
    required this.value,
    required this.icon,
    this.onTap,
    this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = accent ?? theme.colorScheme.primary;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(28),
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minWidth: 160,
          maxWidth: 180,
          minHeight: 140,
        ),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(28),
            boxShadow: const [
              BoxShadow(
                blurRadius: 12,
                spreadRadius: 1,
                offset: Offset(0, 6),
                color: Colors.black12,
              ),
            ],
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 36, color: color),
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium!
                    .copyWith(fontWeight: FontWeight.bold, color: color),
              ),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  value,
                  style: theme.textTheme.titleLarge!
                      .copyWith(fontWeight: FontWeight.w700, color: color),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
