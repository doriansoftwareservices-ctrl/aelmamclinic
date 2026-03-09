# Backend Integration

هذا المستند يصف العقد الحالي بين تطبيق Flutter وبيئة `Nhost`:
- `Auth`
- `GraphQL/Hasura`
- `Storage`
- `Edge Functions`
- `FCM push lifecycle`

أي تعديل في الطبقات التالية يجب أن يراجع معه هذا المستند:
- `lib/providers/auth_provider.dart`
- `lib/services/nhost_auth_service.dart`
- `lib/services/nhost_graphql_service.dart`
- `lib/services/push_notifications_service.dart`
- `lib/providers/chat_provider.dart`

## Runtime Endpoints

المصدر النهائي لعناوين الخدمات هو `lib/core/nhost_config.dart` مع دعم overrides
آمنة من `config.json` أو `--dart-define`.

القيم المسموح بوجودها على العميل:
- `nhostSubdomain`
- `nhostRegion`
- `nhostGraphqlUrl`
- `nhostAuthUrl`
- `nhostStorageUrl`
- `nhostFunctionsUrl`

القيم الممنوع شحنها داخل العميل:
- `HASURA_GRAPHQL_ADMIN_SECRET`
- `HASURA_GRAPHQL_JWT_SECRET`
- `NHOST_WEBHOOK_SECRET`
- أي مفاتيح admin مشابهة

## Session Contract

مصدر الحقيقة للجلسة:
- `Nhost auth session` في `PersistentAuthStore`
- `AuthProvider.currentUser` كتمثيل واجهة محلي

قواعد أساسية:
- لا يجوز إعادة تسجيل الدخول تلقائيًا من كلمة مرور مخزنة
- استعادة الجلسة تتم فقط من `stored credentials/refresh token`
- `signOut()` يجب أن ينظف:
  - `ActiveAccountStore`
  - مفاتيح `auth.*`
  - `chatCode`
  - `accountId`
  - أي `pending wipe`
- تغير الحساب يجب أن يوقف اشتراكات الدردشة و`push token binding` قبل إعادة bootstrap

## GraphQL / RPC

الدوال الحرجة أثناء الإقلاع والتحقق:

| الدالة | الغرض | الملاحظات |
| --- | --- | --- |
| `my_profile()` | حساب المستخدم الحالي | تستخدم لتحديد `account_id`, `role`, `chat_code` |
| `my_account_id()` | fallback لحسم الحساب | يجب ألا تسقط الجلسة محليًا عند فشل شبكي عابر |
| `my_account_plan()` | الخطة الحالية | يستخدمها `AuthProvider` وشاشات الإحصائيات والترقية |
| `my_feature_permissions(p_account uuid)` | أذونات الخصائص وCRUD | أي كسر هنا ينعكس مباشرة على المستودع والإحصائيات |
| `fn_is_super_admin_gql` | تمييز السوبر أدمن | يوجد fallback عند غياب الاستعلام في بعض البيئات |
| `chat_accept_invitation(...)` | قبول دعوة دردشة | يجب أن يعيد `{ok: true}` |
| `chat_decline_invitation(...)` | رفض دعوة دردشة | يجب أن يعيد `{ok: true}` |
| `chat_mark_delivered(uuid[])` | تسجيل الاستلام | يستدعى بعد مزامنة الرسائل |

## Sync Contract

الربط الحالي بين الجلسة والمزامنة:
- `AuthProvider.bootstrapSync(...)`
- `NhostAuthService.bootstrapSyncForCurrentUser(...)`
- `DBService.bindSyncPush(...)`

القواعد الحالية بعد الإصلاح:
- يعاد استخدام `SyncService` إذا كان `accountId + deviceId` لم يتغيرا
- لا يتم `pushAll()/pullAll()` بعد bootstrap إلا عند وجود جداول متسخة فعليًا
- `backfillAccountForTables(...)` يعمل مرة واحدة لكل جلسة حساب
- عند `signedOut` أو تبديل الحساب يجب التخلص من `SyncService` القديم كاملًا

## Push Notifications Contract

ملفات الترابط:
- `lib/services/push_notifications_service.dart`
- `lib/services/notification_service.dart`
- `functions/_shared/notify_utils.js`
- `functions/notify-plan-request/index.js`

قواعد التوكن:
- الجدول: `push_device_tokens`
- المفتاح الفريد: `token`
- `on_conflict` يجب أن يحدث:
  - `user_uid`
  - `account_id`
  - `role`
  - `platform`
  - `locale_code`
  - `is_active`
  - `updated_at`

قواعد اللغة:
- `locale_code` يجب أن يحتوي فقط:
  - `ar`
  - `en`
- عند تغيير اللغة من التطبيق يجب أن يعاد ربط التوكن بنفس الحساب مع `locale_code`
  الجديد.
- Edge Functions يجب أن تجمع التوكنات حسب `locale_code` وترسل دفعات مستقلة لكل
  لغة.
- إذا لم تكن migration مطبقة بعد، يوجد fallback مرحلي إلى `ar` فقط، لكنه ليس
  حالة اعتماد نهائية.

قواعد العميل:
- `initForAuth()` يجب أن يكون idempotent لنفس `accountId + role + languageCode`
- عند تغيير التوكن: يعطل التوكن القديم ثم يسجل الجديد
- عند `signOut()`: يعطل التوكن الحالي ثم ينهي الخدمة
- `getInitialMessage()` يجب أن يعالج فتح التطبيق من إشعار وهو مغلق
- تغيير اللغة يجب أن يحدّث:
  - local channels
  - scheduled reminders
  - `push_device_tokens.locale_code`

أنواع payload المستخدمة حاليًا:
- `patient:<id>`
- `admin:plan_request`
- `admin:seat_request`
- `conversation_id`

ملفات الترابط الخلفي الحالية:
- `functions/notify-chat-message/index.js`
- `functions/notify-new-patient/index.js`
- `functions/notify-plan-request/index.js`

ملاحظة تشغيلية:
- بعد أي تعديل في Event Triggers يجب إعادة التحقق من:
  - `scripts/setup_push_triggers.sh`
  - وصول `chat/patient/plan_request/seat_request` فعليًا

## Storage

Buckets الحرجة:
- `chat-attachments`
- `subscription-proofs`

المتوقع من العميل:
- الرفع عبر `NhostStorageService`
- التعامل مع `403` كخطأ صلاحيات واضح للمستخدم
- عدم حفظ أسرار وصول داخل العميل

## Edge Functions

المسارات الحرجة:
- `notify-plan-request`
- دوال إنشاء المالك/الموظف الإدارية

المتوقع:
- أي Function ترسل FCM يجب أن تعطل التوكنات غير الصالحة
- أي Function إدارية يجب أن تعتمد على Nhost Auth Admin API أو service role على الخادم فقط

## Manual Validation

التحقق التشغيلي الكامل موثق في:
- `docs/smoke_tests.md`
- `docs/runtime_dependency_matrix.md`
