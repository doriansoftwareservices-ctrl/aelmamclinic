import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:aelmamclinic/services/network_probe.dart';

/// Online/Offline based on real internet reachability (not just Wi-Fi).
class NetworkStatusService {
  NetworkStatusService._();
  static final NetworkStatusService instance = NetworkStatusService._();

  final StreamController<bool> _controller =
      StreamController<bool>.broadcast();
  StreamSubscription<List<ConnectivityResult>>? _sub;
  Timer? _debounce;
  bool _started = false;
  bool _online = true;

  bool get isOnline => _online;
  Stream<bool> get changes => _controller.stream;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    final initial = await Connectivity().checkConnectivity();
    await _refresh(initial);
    _sub = Connectivity().onConnectivityChanged.listen((results) {
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 350), () {
        unawaited(_refresh(results));
      });
    });
  }

  Future<void> _refresh(List<ConnectivityResult> results) async {
    final hasLink =
        results.isNotEmpty && results.any((r) => r != ConnectivityResult.none);
    final next = hasLink && await hasRealInternet();
    if (next == _online) return;
    _online = next;
    _controller.add(_online);
  }

  Future<void> dispose() async {
    _debounce?.cancel();
    await _sub?.cancel();
    await _controller.close();
    _started = false;
  }
}
