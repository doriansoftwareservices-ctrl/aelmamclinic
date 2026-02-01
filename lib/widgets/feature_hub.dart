import 'package:flutter/material.dart';

import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/tbian_ui.dart';

class FeatureHubItem {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final String? badgeText;
  final bool disabled;

  const FeatureHubItem({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
    this.badgeText,
    this.disabled = false,
  });
}

class FeatureHubBody extends StatelessWidget {
  final String title;
  final List<FeatureHubItem> items;

  const FeatureHubBody({
    super.key,
    required this.title,
    required this.items,
  });

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final crossAxis = width >= 1200
        ? 4
        : width >= 900
            ? 3
            : width >= 600
                ? 2
                : 1;
    final aspect = width >= 1200
        ? 1.25
        : width >= 900
            ? 1.15
            : 1.05;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        NeuCard(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: SizedBox(
                  width: 46,
                  height: 46,
                  child: Image.asset(
                    'assets/images/logo.png',
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) =>
                        const Icon(Icons.apartment_rounded),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Expanded(
          child: GridView.count(
            crossAxisCount: crossAxis,
            mainAxisSpacing: 16,
            crossAxisSpacing: 16,
            childAspectRatio: aspect,
            children: items.map(_FeatureHubTile.new).toList(),
          ),
        ),
      ],
    );
  }
}

class _FeatureHubTile extends StatelessWidget {
  final FeatureHubItem item;

  const _FeatureHubTile(this.item);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final disabled = item.disabled || item.onTap == null;

    final tile = NeuCard(
      onTap: disabled ? null : item.onTap,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: Container(
              decoration: BoxDecoration(
                color: kPrimaryColor.withValues(alpha: .10),
                borderRadius: BorderRadius.circular(14),
              ),
              padding: const EdgeInsets.all(10),
              child: Icon(
                item.icon,
                color: disabled ? scheme.outline : kPrimaryColor,
                size: 26,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            item.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: scheme.onSurface,
              fontSize: 18,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: Text(
              item.subtitle,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: scheme.onSurface.withValues(alpha: .65),
                fontSize: 13.2,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (item.badgeText != null && item.badgeText!.trim().isNotEmpty)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: Container(
                margin: const EdgeInsets.only(top: 8),
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: scheme.error.withValues(alpha: .1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: scheme.error.withValues(alpha: .35),
                  ),
                ),
                child: Text(
                  item.badgeText!,
                  style: TextStyle(
                    color: scheme.error,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ),
            ),
          const SizedBox(height: 10),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: TPrimaryButton(
              icon: Icons.arrow_back_ios_new_rounded,
              label: 'فتح',
              onPressed: disabled ? null : item.onTap,
            ),
          ),
        ],
      ),
    );

    if (!disabled) return tile;
    return Opacity(opacity: 0.7, child: tile);
  }
}
