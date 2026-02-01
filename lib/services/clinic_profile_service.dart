import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aelmamclinic/core/active_account_store.dart';
import 'package:aelmamclinic/models/clinic_profile.dart';
import 'package:aelmamclinic/services/db_service.dart';

class ClinicProfileService {
  static const String _planCodeKey = 'auth.planCode';
  static const String _fallbackLogoAsset = 'assets/images/logo2.png';

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

  static Future<bool> isPaidPlan() async {
    final sp = await SharedPreferences.getInstance();
    final code = (sp.getString(_planCodeKey) ?? 'free').toLowerCase().trim();
    return code.isNotEmpty && code != 'free';
  }

  static Future<Uint8List> loadReportLogoBytes() async {
    try {
      final paid = await isPaidPlan();
      if (paid) {
        final accountId = await ActiveAccountStore.readAccountId();
        if (accountId != null && accountId.trim().isNotEmpty) {
          final profile = await DBService.instance.getClinicProfile(accountId);
          final path = profile?.logoPath?.trim() ?? '';
          if (path.isNotEmpty) {
            final file = File(path);
            if (await file.exists()) {
              return await file.readAsBytes();
            }
          }
        }
      }
    } catch (_) {}
    final bytes = await rootBundle.load(_fallbackLogoAsset);
    return bytes.buffer.asUint8List();
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
