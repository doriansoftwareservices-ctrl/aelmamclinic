import 'network_probe_stub.dart'
    if (dart.library.io) 'network_probe_io.dart';

Future<bool> hasRealInternet() => probeHasRealInternet();
