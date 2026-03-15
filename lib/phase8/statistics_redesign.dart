Map<String, double> buildZeroFilledMonthlySeries({
  required DateTime from,
  required DateTime to,
}) {
  final normalizedFrom = DateTime(from.year, from.month, 1);
  final normalizedTo = DateTime(to.year, to.month, 1);
  final out = <String, double>{};
  var cursor = normalizedFrom;
  while (!cursor.isAfter(normalizedTo)) {
    final key =
        '${cursor.year.toString().padLeft(4, '0')}-${cursor.month.toString().padLeft(2, '0')}';
    out[key] = 0.0;
    cursor = DateTime(cursor.year, cursor.month + 1, 1);
  }
  return out;
}

Map<String, double> rollupDailySeriesToMonthly(
  Map<String, double> dailySeries, {
  required DateTime from,
  required DateTime to,
}) {
  final monthly = buildZeroFilledMonthlySeries(from: from, to: to);
  for (final entry in dailySeries.entries) {
    final date = DateTime.tryParse(entry.key);
    if (date == null) continue;
    final monthKey =
        '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}';
    if (!monthly.containsKey(monthKey)) continue;
    monthly[monthKey] = (monthly[monthKey] ?? 0.0) + entry.value;
  }
  return monthly;
}

Map<String, double> buildYearMonthlySeries(
  Map<String, double> dailySeries, {
  required int year,
}) {
  final out = <String, double>{
    for (var month = 1; month <= 12; month++)
      month.toString().padLeft(2, '0'): 0.0,
  };
  for (final entry in dailySeries.entries) {
    final date = DateTime.tryParse(entry.key);
    if (date == null || date.year != year) continue;
    final key = date.month.toString().padLeft(2, '0');
    out[key] = (out[key] ?? 0.0) + entry.value;
  }
  return out;
}

double sumSeries(Map<String, double> values) {
  return values.values.fold<double>(0.0, (sum, value) {
    if (value.isNaN || value.isInfinite) {
      return sum;
    }
    return sum + value;
  });
}
