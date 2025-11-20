# AGENTS.md

## Build and test
- Install deps: `flutter pub get`
- Format: `dart format --output=none --set-exit-if-changed .`
- Lint: `flutter analyze`
- Unit tests: `flutter test --coverage`

## Conventions
- Dart >= 3.x, null-safety صارمة
- استخدم `final` و`const` عند الإمكان
- التزِم بهيكلة feature-first مع طبقات domain/data/presentation

## CI hints
- فشل أي من `analyze` أو `test` يعتبر خطأ يجب إصلاحه قبل إنهاء المهمة.

## References
- راجع `docs/backend.md` لعقد Supabase والدوال الحرجة.
- خطوات واختبارات كل دور موثقة في `docs/smoke_tests.md` مع مسار سجلات CI.*** End Patch```} to=functions.apply_patch ***!
