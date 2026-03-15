import 'package:flutter/material.dart';
import 'package:aelmamclinic/utils/l10n_extensions.dart';
import 'package:aelmamclinic/widgets/localized_text.dart';
import 'neumorphism.dart';
import 'theme.dart';

class TSearchField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final void Function(String)? onChanged;
  final VoidCallback? onClear;

  const TSearchField({
    super.key,
    required this.controller,
    this.hint = 'ابحث...',
    this.onChanged,
    this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return NeuCard(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        decoration: InputDecoration(
          hintText: context.trRaw(hint),
          prefixIcon:
              Icon(Icons.search, color: scheme.onSurface.withValues(alpha: .7)),
          suffixIcon: controller.text.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: onClear,
                ),
          border: InputBorder.none,
        ),
      ),
    );
  }
}

class TDateButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const TDateButton(
      {super.key,
      required this.icon,
      required this.label,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    return NeuCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          Container(
            decoration: BoxDecoration(
              color: kPrimaryColor.withValues(alpha: .10),
              borderRadius: BorderRadius.circular(14),
            ),
            padding: const EdgeInsets.all(8),
            child: Icon(icon, color: kPrimaryColor, size: 18),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              context.trRaw(label),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  const TextStyle(fontWeight: FontWeight.w800, fontSize: 14.5),
            ),
          ),
        ],
      ),
    );
  }
}

class TPrimaryButton extends StatelessWidget {
  final IconData? icon;
  final String label;
  final VoidCallback? onPressed;
  const TPrimaryButton(
      {super.key, this.icon, required this.label, required this.onPressed});

  IconData? _resolveDirectionalIcon(BuildContext context, IconData? source) {
    if (source == null) return null;
    if (source == Icons.arrow_back_ios_new_rounded) {
      return context.isRtl
          ? Icons.arrow_back_ios_new_rounded
          : Icons.arrow_forward_ios_rounded;
    }
    if (source == Icons.arrow_back_rounded) {
      return context.isRtl
          ? Icons.arrow_back_rounded
          : Icons.arrow_forward_rounded;
    }
    if (source == Icons.chevron_left_rounded) {
      return context.isRtl
          ? Icons.chevron_left_rounded
          : Icons.chevron_right_rounded;
    }
    if (source == Icons.chevron_right_rounded) {
      return context.isRtl
          ? Icons.chevron_left_rounded
          : Icons.chevron_right_rounded;
    }
    return source;
  }

  @override
  Widget build(BuildContext context) {
    return NeuButton.flat(
      icon: _resolveDirectionalIcon(context, icon),
      label: label,
      onPressed: onPressed,
    );
  }
}

class TOutlinedButton extends StatelessWidget {
  final IconData? icon;
  final String label;
  final VoidCallback? onPressed;
  const TOutlinedButton(
      {super.key, this.icon, required this.label, required this.onPressed});

  IconData? _resolveDirectionalIcon(BuildContext context, IconData? source) {
    if (source == null) return null;
    if (source == Icons.arrow_back_ios_new_rounded) {
      return context.isRtl
          ? Icons.arrow_back_ios_new_rounded
          : Icons.arrow_forward_ios_rounded;
    }
    if (source == Icons.arrow_back_rounded) {
      return context.isRtl
          ? Icons.arrow_back_rounded
          : Icons.arrow_forward_rounded;
    }
    if (source == Icons.chevron_left_rounded) {
      return context.isRtl
          ? Icons.chevron_left_rounded
          : Icons.chevron_right_rounded;
    }
    if (source == Icons.chevron_right_rounded) {
      return context.isRtl
          ? Icons.chevron_left_rounded
          : Icons.chevron_right_rounded;
    }
    return source;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(
        _resolveDirectionalIcon(context, icon),
        color: scheme.onSurface.withValues(alpha: .85),
      ),
      label: Text(context.trRaw(label)),
      style: OutlinedButton.styleFrom(
        foregroundColor: scheme.onSurface,
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: .4)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
    );
  }
}

class TSectionHeader extends StatelessWidget {
  final String title;
  const TSectionHeader(this.title, {super.key});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: LocalizedText(
        title,
        style: TextStyle(
          color: scheme.onSurface,
          fontSize: 18,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class TInfoCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final int maxLines;
  const TInfoCard({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    this.maxLines = 1,
  });
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return NeuCard(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(icon, color: kPrimaryColor),
        title: LocalizedText(
          label,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: LocalizedText(
          value,
          maxLines: maxLines,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: scheme.onSurface.withValues(alpha: .85)),
        ),
      ),
    );
  }
}
