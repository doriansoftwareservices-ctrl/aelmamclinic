class PaymentMethod {
  final String id;
  final String name;
  final String? logoUrl;
  final String bankAccount;

  const PaymentMethod({
    required this.id,
    required this.name,
    required this.bankAccount,
    this.logoUrl,
  });

  factory PaymentMethod.fromMap(Map<String, dynamic> map) {
    return PaymentMethod(
      id: (map['id'] ?? '').toString(),
      name: (map['name'] ?? '').toString(),
      bankAccount: (map['bank_account'] ?? '').toString(),
      logoUrl: map['logo_url']?.toString(),
    );
  }
}
