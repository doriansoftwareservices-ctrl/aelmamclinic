# Runtime Dependency Matrix

هذا المستند يوضح الترابطات الحرجة بين طبقات التطبيق بعد إصلاحات المراحل 1-3.

## Auth Flow

`main.dart`
-> `AuthProvider`
-> `NhostAuthService`
-> `PersistentAuthStore`
-> `NhostGraphqlService`
-> `ActiveAccountStore`

تأثير أي تعديل:
- كسر هنا قد يعيد مشكلة فقد الجلسة بعد إعادة الفتح
- كسر هنا قد يمنع `accountId` أو `role` أو `planCode` من الوصول لباقي الطبقات

## Push Flow

`AuthProvider.signOut()`
-> `PushNotificationsService.deactivateCurrentToken()`
-> `NhostGraphqlService`
-> `push_device_tokens`
-> `NotificationService`

تأثير أي تعديل:
- إذا لم يُحدّث `user_uid/account_id` مع التوكن سيصل الإشعار للحساب الخاطئ
- إذا لم يُعطّل التوكن عند الخروج سيستمر الجهاز في استقبال إشعارات حساب قديم

## Chat Flow

`main.dart`
-> `ChatProvider.scheduleAuthSync()`
-> `ChatProvider.ensureBootstrapped()`
-> `ChatRealtimeNotifier.start()`
-> `ChatService`
-> `NhostGraphqlService`

تأثير أي تعديل:
- قد يعيد تكرار bootstrap أو تكرار subscriptions
- قد يترك اشتراكات حساب قديم بعد تبديل الحساب

## Sync Flow

`AuthProvider.bootstrapSync()`
-> `NhostAuthService.bootstrapSyncForCurrentUser()`
-> `DeviceIdService.getId()`
-> `SyncService`
-> `DBService.bindSyncPush()`

تأثير أي تعديل:
- قد يعيد `pushAll()/pullAll()` غير المشروط
- قد يكرر backfill لكل إقلاع
- قد يربط هوية جهاز أو حساب خاطئة

## Admin Dashboard

`AdminDashboardScreen`
-> `AdminBillingService`
-> `AdminInsightsService`
-> `SuperAdminAccountsService`
-> `NhostApiClient` / `NhostGraphqlService`

تأثير أي تعديل:
- قد يعيد التحميل الثقيل لكل التبويبات عند الفتح
- قد يضاعف polling أو الطلبات المتوازية بلا داع

## Statistics / Plan UI

`StatisticsOverviewScreen`
-> `AuthProvider.planCode`
-> `AuthProvider.planEndAt`
-> `Billing/upgrade UI`

تأثير أي تعديل:
- استدعاءات شبكة غير ضرورية عند الإقلاع
- تنبيهات خطة غير دقيقة أو متكررة

## Safe Change Rules

- أي تعديل في `AuthProvider` يجب اختباره مع:
  - `signIn`
  - `signOut`
  - `restart`
  - `account switch`
- أي تعديل في `PushNotificationsService` يجب اختباره مع:
  - `token refresh`
  - `signOut`
  - `getInitialMessage`
- أي تعديل في `ChatProvider` يجب اختباره مع:
  - `ensureBootstrapped`
  - `signedOut reset`
  - `re-enter chat screen`
- أي تعديل في `NhostAuthService` يجب اختباره مع:
  - `bootstrapSync reuse`
  - `dirty tables only`
  - `disposeSync on auth change`
