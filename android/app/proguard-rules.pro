# قواعد مخصصة لحماية الكود

# إذا كنت تستخدم Flutter:
-keep class io.flutter.app.** { *; }
-keep class io.flutter.embedding.** { *; }
-keep class io.flutter.plugins.** { *; }

# إزالة سجلات Log في إصدار Release لتقليل المعلومات الظاهرة
-assumenosideeffects class android.util.Log {
  public static *** v(...);
  public static *** d(...);
  public static *** i(...);
  public static *** w(...);
  public static *** e(...);
  public static *** wtf(...);
}

# Google Play Services / Google Sign-In
-dontwarn com.google.android.gms.**
-keep class com.google.android.gms.** { *; }

# Play Core (Split Install / In-App Updates)
-dontwarn com.google.android.play.core.**
-keep class com.google.android.play.core.** { *; }

# مثال لقواعد عامة (يمكنك إضافة قواعد أخرى حسب المكتبات المستخدمة)
-dontwarn okhttp3.**
-keep class okhttp3.** { *; }
