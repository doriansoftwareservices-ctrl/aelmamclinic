// lib/utils/chat_code_utils.dart

class ChatCodeUtils {
  static String normalize(String value) {
    return value.replaceAll(RegExp(r'[^0-9]'), '');
  }

  static bool isChatCode(String value) {
    final digits = normalize(value);
    return digits.length == 7 && digits.startsWith('555');
  }

  static String format(String value) {
    final digits = normalize(value);
    if (digits.length == 7 && digits.startsWith('555')) {
      return '555-${digits.substring(3)}';
    }
    return value;
  }
}
