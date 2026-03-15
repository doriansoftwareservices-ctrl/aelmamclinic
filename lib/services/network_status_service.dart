import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:aelmamclinic/services/network_probe.dart';

/// Online/Offline based on real internet reachability (not just Wi-Fi).
enum NetworkReachabilityStatus {
  unknown,
  online,
  offline,
}

class NetworkStatusService {
  NetworkStatusService._();
  static final NetworkStatusService instance = NetworkStatusService._();

  final StreamController<bool> _controller =
      StreamController<bool>.broadcast();
  StreamSubscription<List<ConnectivityResult>>? _sub;
  Timer? _debounce;
  Timer? _periodicRefresh;
  bool _started = false;
  bool _online = true;
  NetworkReachabilityStatus _status = NetworkReachabilityStatus.unknown;
  Future<bool>? _refreshInFlight;
  DateTime? _lastCheckedAt;
  DateTime? _lastReachableAt;
  String? _lastError;

  bool get _desktopReachabilityRelaxed =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.macOS);

  bool get isOnline => _online;
  NetworkReachabilityStatus get status => _status;
  DateTime? get lastCheckedAt => _lastCheckedAt;
  DateTime? get lastReachableAt => _lastReachableAt;
  String? get lastError => _lastError;
  Stream<bool> get changes => _controller.stream;

  Future<void> start({
    Duration periodicRefresh = const Duration(seconds: 25),
  }) async {
    if (_started) return;
    _started = true;
    final initial = await Connectivity().checkConnectivity();
    await refreshNow(results: initial);
    _sub = Connectivity().onConnectivityChanged.listen((results) {
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 350), () {
        unawaited(refreshNow(results: results));
      });
    });
    _periodicRefresh?.cancel();
    _periodicRefresh = Timer.periodic(periodicRefresh, (_) {
      unawaited(refreshNow());
    });
  }

  Future<bool> refreshNow({
    List<ConnectivityResult>? results,
  }) {
    final inFlight = _refreshInFlight;
    if (inFlight != null) {
      return inFlight;
    }
    final future = _refresh(results);
    _refreshInFlight = future;
    future.whenComplete(() {
      if (identical(_refreshInFlight, future)) {
        _refreshInFlight = null;
      }
    });
    return future;
  }

  Future<bool> _refresh(List<ConnectivityResult>? results) async {
    final effectiveResults = results ?? await Connectivity().checkConnectivity();
    final hasLink =
        effectiveResults.isNotEmpty &&
        effectiveResults.any((r) => r != ConnectivityResult.none);
    var next = false;
    String? nextError;
    if (!hasLink) {
      next = false;
      nextError = 'no_link';
    } else if (_desktopReachabilityRelaxed) {
      next = true;
    } else {
      try {
        next = await hasRealInternet();
        if (!next) {
          nextError = 'backend_probe_failed';
        }
      } catch (error) {
        next = false;
        nextError = '$error';
      }
    }

    _lastCheckedAt = DateTime.now();
    if (next) {
      _lastReachableAt = _lastCheckedAt;
      _lastError = null;
    } else {
      _lastError = nextError;
    }

    final nextStatus = next
        ? NetworkReachabilityStatus.online
        : NetworkReachabilityStatus.offline;
    final changed = next != _online || nextStatus != _status;
    _online = next;
    _status = nextStatus;
    if (changed) {
      _controller.add(_online);
    }
    return _online;
  }

  Future<void> dispose() async {
    _debounce?.cancel();
    _periodicRefresh?.cancel();
    await _sub?.cancel();
    await _controller.close();
    _started = false;
    _refreshInFlight = null;
  }
}
