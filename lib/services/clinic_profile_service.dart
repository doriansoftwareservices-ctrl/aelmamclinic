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
    return profile ?? ClinicProfile.fallback();
  }

  static Future<void> cacheProfile(ClinicProfile profile) async {
    if (profile.accountId.trim().isEmpty) return;
    await DBService.instance.saveClinicProfile(profile);
  }
}
