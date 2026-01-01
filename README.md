# aelmamclinic

إدارة متكاملة لعيادة ألمام مبنية على Flutter مع تخزين محلي SQLite ومزامنة Nhost (Postgres + Hasura).

## المتطلبات

- Flutter 3.35 أو أحدث.
- Dart 3.9 أو أحدث.
- Nhost CLI 1.31 أو أحدث (`nhost config pull/apply`).
- حساب Nhost مع مشروع مهيأ (mergrgclboxflnucehgb أو ما يعادله).

## الإعداد السريع

1. **تنزيل الحزم**
   ```bash
   flutter pub get
   ```
2. **سحب إعدادات Nhost وتوفير المفاتيح**
   ```bash
   nhost config pull
   ```
   يُنشئ الملف `nhost/nhost.toml` وملف الأسرار `.secrets` (مضاف تلقائياً إلى
   `.gitignore`). عدل `.secrets` لتضع القيم:

   - `HASURA_GRAPHQL_ADMIN_SECRET`
   - `HASURA_GRAPHQL_JWT_SECRET`
   - `NHOST_WEBHOOK_SECRET`

   يمكن تمرير override إضافي عبر `--dart-define NHOST_GRAPHQL_URL=...` أو عبر
   ملف `config.json` في مجلد البيانات الخاص بالمنصة (مثل
   `C:\aelmam_clinic\config.json`). مثال مبسط (بدون أسرار):

   ```json
   {
     "nhostSubdomain": "mergrgclboxflnucehgb",
     "nhostRegion": "ap-southeast-1",
     "nhostGraphqlUrl": "https://mergrgclboxflnucehgb.graphql.ap-southeast-1.nhost.run/v1",
     "nhostAuthUrl": "https://mergrgclboxflnucehgb.auth.ap-southeast-1.nhost.run/v1",
     "nhostStorageUrl": "https://mergrgclboxflnucehgb.storage.ap-southeast-1.nhost.run/v1",
     "nhostFunctionsUrl": "https://mergrgclboxflnucehgb.functions.ap-southeast-1.nhost.run/v1"
   }
   ```

   تُحمَّل هذه القيم تلقائيًا عند الإقلاع وتتفوق على الإعدادات المضمّنة. تستمر
   آلية البحث عن الملف في نفس المسارات (`C:\aelmam_clinic`, `D:\aelmam_clinic`,
   `%APPDATA%\aelmam_clinic`, إلخ) ويمكن تمرير مسار مخصّص عبر المتغيرات
   `AELMAM_NHOST_CONFIG` أو `AELMAM_CONFIG` / `AELMAM_CLINIC_CONFIG` (للتوافق مع الإصدارات السابقة).
   **مهم:** لا تضع أي أسرار (Admin/JWT/Webhook) داخل هذا الملف لأنه يُقرأ من العميل.

3. **تهيئة Firebase (اختياري)**
   استورد إعدادات `firebase_options.dart` المطابقة لبيئتك.

## الإعداد المتقدم

### ضبط بيئة الدردشة

القيم الافتراضية معرفة في `lib/core/constants.dart`. يمكن تعديلها عبر `--dart-define` أو تحديث الملف نفسه:

| الثابت | الغرض | القيمة الافتراضية |
| --- | --- | --- |
| `chatPreferPublicUrls` | استخدام روابط عامة للمرفقات بدلاً من الروابط الموقعة | `false` |
| `chatMaxAttachmentBytes` | الحد الأقصى لحجم مرفقات الرسالة الواحدة (null لتعطيل) | 20 MB |
| `chatMaxSingleAttachmentBytes` | الحد الأقصى لكل ملف مفرد (null لتعطيل) | 10 MB |

### مفاتيح إضافية

- `storageSignedUrlTTLSeconds` يمكن ضبطه لتغيير عمر الروابط الموقعة.
- مسارات البيانات المحلية قابلة للتهيئة لكل منصة ضمن `AppConstants`.

## تشغيل الاختبارات

### اختبارات الوحدات

```bash
flutter test test/auth_provider_permissions_test.dart
```
يتحقق من بوابة الصلاحيات في `AuthProvider` (بما في ذلك حالات المشرف).

### اختبارات قاعدة البيانات

```bash
flutter test test/db_service_smoke_test.dart
```
ينشئ قاعدة SQLite مؤقتة ويختبر إدخال مريض وبث التغييرات عبر `DBService` والمستودع الجديد للمرضى.

## المراقبة والتشغيل

- يتم تسجيل الأعطال في ملف موجود ضمن دليل البيانات الخاص بالمنصة (مثل `C:\aelmam_clinic\crash_log.txt`) بالإضافة إلى `dart:developer`.
- سجلات Edge Functions (مثل `admin__create_employee`) تحتوي على `console.error` عند فشل الاستدعاءات.
- يمكن ضبط حدود المرفقات أو تعطيلها عبر الثوابت المذكورة أعلاه لتجنب استهلاك التخزين.

## معالم في الكود

- **مستودع المرضى المحلي**: `lib/services/db_service_parts/patient_local_repository.dart` يحتوي على عمليات CRUD الخاصة بالمرضى.
- **سياسات الصلاحيات**: `AuthProvider` يغلق الميزات افتراضياً حتى اكتمال التحميل، مع واجهات اختبار `debugSetPermissions` و`debugSetCurrentUser`.
- **مرفقات الدردشة**: `ChatService` يستخدم `_friendlyFileName` للرفع ويطبق حدود الحجم وفق `AppConstants`.

## المساهمة

1. أنشئ فرعاً جديداً.
2. نفّذ التعديلات وشغّل الاختبارات أعلاه.
3. أرسل طلب دمج موضحاً تغييرك.
