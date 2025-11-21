// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aelmamclinic/providers/theme_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('ThemeProvider toggles between light and dark modes',
      (WidgetTester tester) async {
    final prefs = await SharedPreferences.getInstance();
    final provider = ThemeProvider(prefs: prefs);
    await provider.ready;

    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeProvider>.value(
        value: provider,
        child: Builder(
          builder: (BuildContext context) {
            final theme = context.watch<ThemeProvider>();
            return MaterialApp(
              themeMode: theme.themeMode,
              theme: ThemeData.light(),
              darkTheme: ThemeData.dark(),
              home: Scaffold(
                body: Text(theme.themeMode.name),
                floatingActionButton: FloatingActionButton(
                  onPressed: theme.toggleTheme,
                ),
              ),
            );
          },
        ),
      ),
    );

    await tester.pumpAndSettle();
    expect(find.text('light'), findsOneWidget);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    expect(find.text('dark'), findsOneWidget);
  });
}
