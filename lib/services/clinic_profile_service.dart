import 'package:aelmamclinic/core/active_account_store.dart';
import 'package:aelmamclinic/models/clinic_profile.dart';
import 'package:aelmamclinic/services/db_service.dart';

class ClinicProfileService {
  static Future<ClinicProfile> loadActiveOrFallback() async {
    final accountId = await ActiveAccountStore.readAccountId();
    if (accountId == null || accountId.trim().isEmpty) {
      return ClinicProfile.fallback();
    }
    final profile = await DBService.instance.getClinicProfile(accountId);
    if (profile == null || !profile.isComplete) {
      return ClinicProfile.fallback();
    }
    return profile;
  }

  static Future<void> cacheProfile(ClinicProfile profile) async {
    if (profile.accountId.trim().isEmpty) return;
    await DBService.instance.saveClinicProfile(profile);
  }

  static Future<bool> isProfileComplete() async {
    final accountId = await ActiveAccountStore.readAccountId();
    if (accountId == null || accountId.trim().isEmpty) return false;
    final profile = await DBService.instance.getClinicProfile(accountId);
    return profile?.isComplete ?? false;
  }
}
