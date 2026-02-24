class InventoryHealthReport {
  final int itemTypes;
  final int items;
  final int orphanItems;
  final int orphanPurchases;
  final int orphanConsumptions;
  final int missingAccountRows;
  final String? reason;

  const InventoryHealthReport({
    required this.itemTypes,
    required this.items,
    required this.orphanItems,
    required this.orphanPurchases,
    required this.orphanConsumptions,
    required this.missingAccountRows,
    this.reason,
  });

  factory InventoryHealthReport.empty({String? reason}) =>
      InventoryHealthReport(
        itemTypes: 0,
        items: 0,
        orphanItems: 0,
        orphanPurchases: 0,
        orphanConsumptions: 0,
        missingAccountRows: 0,
        reason: reason,
      );

  bool get hasIssues =>
      orphanItems > 0 ||
      orphanPurchases > 0 ||
      orphanConsumptions > 0 ||
      missingAccountRows > 0;
}
