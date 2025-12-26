import 'package:flutter/material.dart';

/// Minimal app shell that informs the operator that all backend connectivity
/// has been disabled for this build.
class OfflineModeApp extends StatelessWidget {
  const OfflineModeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Elmam Clinic (Offline)',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueGrey),
        useMaterial3: true,
      ),
      home: const OfflineModeScreen(),
    );
  }
}

class OfflineModeScreen extends StatelessWidget {
  const OfflineModeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: colorScheme.surface,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Card(
            margin: const EdgeInsets.all(24),
            elevation: 4,
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.cloud_off,
                    size: 48,
                    color: colorScheme.primary,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'الوضع غير المتصل',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          color: colorScheme.onSurface,
                        ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'تم تعطيل جميع الاتصالات بالخوادم وفقًا لمتطلبات العمل. '
                    'لن يحاول التطبيق الاتصال بأي خدمة خارجية في هذا الإصدار.',
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'فعّل الوصول إلى الخوادم فقط عندما تتم إعادة تفعيل البنية '
                    'التحتية الخلفية أو كنت بحاجة لاختبارات التكامل.',
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
