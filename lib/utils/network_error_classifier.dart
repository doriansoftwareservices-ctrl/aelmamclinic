import 'dart:async';
import 'dart:io';

abstract final class NetworkErrorClassifier {
  static bool isTransportError(Object error) {
    if (error is SocketException ||
        error is TimeoutException ||
        error is HandshakeException ||
        error is HttpException) {
      return true;
    }
    return isTransportLikeMessage(error.toString());
  }

  static bool isTransportLikeMessage(String message) {
    final s = message.toLowerCase();
    return s.contains('socketexception') ||
        s.contains('failed host lookup') ||
        s.contains('timed out') ||
        s.contains('timeout') ||
        s.contains('handshakeexception') ||
        s.contains('connection closed before full header was received') ||
        s.contains('connection reset by peer') ||
        s.contains('software caused connection abort') ||
        s.contains('clientexception') ||
        s.contains('semaphore timeout') ||
        s.contains('semaphore') ||
        s.contains('tls') ||
        s.contains('certificate');
  }

  static bool isServerUnavailableLikeMessage(String message) {
    final s = message.toLowerCase();
    return s.contains('statuscode=502') ||
        s.contains('statuscode=503') ||
        s.contains('status: 502') ||
        s.contains('status: 503') ||
        s.contains('bad gateway') ||
        s.contains('service unavailable') ||
        s.contains('service temporarily unavailable') ||
        s.contains('temporarily unavailable') ||
        s.contains('responseformatexception') ||
        s.contains('formatexception') ||
        s.contains('unexpected character') ||
        s.contains('document is empty') ||
        s.contains('eof') ||
        s.contains('context deadline exceeded');
  }
}
