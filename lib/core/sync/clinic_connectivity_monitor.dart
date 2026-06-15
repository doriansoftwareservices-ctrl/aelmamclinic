import 'dart:async';

import 'package:aelmamclinic/core/sync/clinic_sync_models.dart';
import 'package:aelmamclinic/services/network_status_service.dart';

class ClinicConnectivityMonitor {
  ClinicConnectivityMonitor({NetworkStatusService? network})
    : _network = network ?? NetworkStatusService.instance;

  final NetworkStatusService _network;
  final StreamController<ClinicConnectivityStatus> _controller =
      StreamController<ClinicConnectivityStatus>.broadcast();
  StreamSubscription<bool>? _subscription;
  ClinicConnectivityStatus _status = ClinicConnectivityStatus.unknown;

  ClinicConnectivityStatus get status => _status;
  bool get isOnline => _status == ClinicConnectivityStatus.online;
  bool get isOffline => _status == ClinicConnectivityStatus.offline;
  bool get isUnknown => _status == ClinicConnectivityStatus.unknown;
  Stream<ClinicConnectivityStatus> get changes => _controller.stream;

  Future<ClinicConnectivityStatus> start({
    Duration probeInterval = const Duration(seconds: 20),
  }) async {
    await _network.start(periodicRefresh: probeInterval);
    await refresh();
    _subscription ??= _network.changes.listen((_) {
      _emit(_fromNetwork());
    });
    return _status;
  }

  Future<ClinicConnectivityStatus> refresh() async {
    await _network.refreshNow();
    _emit(_fromNetwork());
    return _status;
  }

  Future<bool> ensureOnlineForManualSync() async {
    final refreshed = await refresh();
    return refreshed == ClinicConnectivityStatus.online;
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
    await _controller.close();
  }

  ClinicConnectivityStatus _fromNetwork() {
    switch (_network.status) {
      case NetworkReachabilityStatus.online:
        return ClinicConnectivityStatus.online;
      case NetworkReachabilityStatus.offline:
        return ClinicConnectivityStatus.offline;
      case NetworkReachabilityStatus.unknown:
        return ClinicConnectivityStatus.unknown;
    }
  }

  void _emit(ClinicConnectivityStatus next) {
    if (_status == next) return;
    _status = next;
    if (!_controller.isClosed) {
      _controller.add(next);
    }
  }
}
