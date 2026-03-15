import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:aelmamclinic/providers/auth_provider.dart';
import 'package:aelmamclinic/widgets/localized_text.dart';

class FinanceAccessGuard extends StatelessWidget {
  const FinanceAccessGuard({
    super.key,
    required this.child,
  });

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final canAccess = auth.isSuperAdmin || auth.isOwnerOrAdmin;
    if (canAccess) return child;

    final scheme = Theme.of(context).colorScheme;
    return Directionality(
      textDirection: Directionality.of(context),
      child: Scaffold(
        appBar: AppBar(
          centerTitle: true,
          title: const LocalizedText('المالية للموظفين'),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: LocalizedText('هذه الشاشة مخصّصة للمالك أو المدير فقط.',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.error),
            ),
          ),
        ),
      ),
    );
  }
}
