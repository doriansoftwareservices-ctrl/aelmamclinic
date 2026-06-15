import 'dart:async';

import 'package:aelmamclinic/core/sync/clinic_sync_domains.dart';

typedef ClinicDomainPullCallback = Future<void> Function(
  Set<ClinicSyncDomain> domains,
);

class ClinicServerDirectedSyncCoordinator {
  ClinicServerDirectedSyncCoordinator({
    required ClinicDomainPullCallback onPullDomains,
    Duration debounce = const Duration(seconds: 2),
  })  : _onPullDomains = onPullDomains,
        _debounce = debounce;

  final ClinicDomainPullCallback _onPullDomains;
  final Duration _debounce;
  final Set<ClinicSyncDomain> _pending = <ClinicSyncDomain>{};
  Timer? _timer;
  bool _running = false;

  bool get hasPendingSignals => _pending.isNotEmpty || _timer != null;

  void notifyTable(String table) {
    notifyDomain(ClinicSyncDomains.domainForTable(table));
  }

  void notifyDomain(ClinicSyncDomain domain) {
    _pending.add(domain);
    _timer?.cancel();
    _timer = Timer(_debounce, () => unawaited(flush()));
  }

  Future<void> flush() async {
    if (_running || _pending.isEmpty) return;
    _timer?.cancel();
    _timer = null;
    _running = true;
    final domains = Set<ClinicSyncDomain>.from(_pending);
    _pending.clear();
    try {
      await _onPullDomains(domains);
    } finally {
      _running = false;
      if (_pending.isNotEmpty) {
        _timer = Timer(_debounce, () => unawaited(flush()));
      }
    }
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    _pending.clear();
  }
}
