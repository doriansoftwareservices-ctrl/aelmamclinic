class ClinicProfile {
  final String accountId;
  final String nameAr;
  final String cityAr;
  final String streetAr;
  final String nearAr;
  final String nameEn;
  final String cityEn;
  final String streetEn;
  final String nearEn;
  final String phone;

  const ClinicProfile({
    required this.accountId,
    required this.nameAr,
    required this.cityAr,
    required this.streetAr,
    required this.nearAr,
    required this.nameEn,
    required this.cityEn,
    required this.streetEn,
    required this.nearEn,
    required this.phone,
  });

  String get addressAr => _joinParts([cityAr, streetAr, nearAr]);
  String get addressEn => _joinParts([cityEn, streetEn, nearEn]);
  bool get isComplete =>
      nameAr.trim().isNotEmpty &&
      cityAr.trim().isNotEmpty &&
      streetAr.trim().isNotEmpty &&
      nearAr.trim().isNotEmpty &&
      nameEn.trim().isNotEmpty &&
      cityEn.trim().isNotEmpty &&
      streetEn.trim().isNotEmpty &&
      nearEn.trim().isNotEmpty &&
      phone.trim().isNotEmpty;

  String _joinParts(List<String> parts) {
    return parts.where((p) => p.trim().isNotEmpty).join(' - ');
  }

  Map<String, dynamic> toMap() => {
        'account_id': accountId,
        'name_ar': nameAr,
        'city_ar': cityAr,
        'street_ar': streetAr,
        'near_ar': nearAr,
        'name_en': nameEn,
        'city_en': cityEn,
        'street_en': streetEn,
        'near_en': nearEn,
        'phone': phone,
      };

  factory ClinicProfile.fromMap(Map<String, dynamic> map) => ClinicProfile(
        accountId: map['account_id']?.toString() ?? '',
        nameAr: map['name_ar']?.toString() ?? '',
        cityAr: map['city_ar']?.toString() ?? '',
        streetAr: map['street_ar']?.toString() ?? '',
        nearAr: map['near_ar']?.toString() ?? '',
        nameEn: map['name_en']?.toString() ?? '',
        cityEn: map['city_en']?.toString() ?? '',
        streetEn: map['street_en']?.toString() ?? '',
        nearEn: map['near_en']?.toString() ?? '',
        phone: map['phone']?.toString() ?? '',
      );

  factory ClinicProfile.fallback() => const ClinicProfile(
        accountId: '',
        nameAr: 'مركز إلمام الطبي',
        cityAr: 'العنوان1',
        streetAr: 'العنوان2',
        nearAr: 'العنوان3',
        nameEn: 'Elmam Health Center',
        cityEn: 'Address1',
        streetEn: 'Address2',
        nearEn: 'Address3',
        phone: '12345678',
      );
}

class ClinicProfileInput {
  final String nameAr;
  final String cityAr;
  final String streetAr;
  final String nearAr;
  final String nameEn;
  final String cityEn;
  final String streetEn;
  final String nearEn;
  final String phone;

  const ClinicProfileInput({
    required this.nameAr,
    required this.cityAr,
    required this.streetAr,
    required this.nearAr,
    required this.nameEn,
    required this.cityEn,
    required this.streetEn,
    required this.nearEn,
    required this.phone,
  });

  Map<String, dynamic> toArgs() => {
        'clinic_name_ar': nameAr,
        'city_ar': cityAr,
        'street_ar': streetAr,
        'near_ar': nearAr,
        'clinic_name_en': nameEn,
        'city_en': cityEn,
        'street_en': streetEn,
        'near_en': nearEn,
        'phone': phone,
      };
}
