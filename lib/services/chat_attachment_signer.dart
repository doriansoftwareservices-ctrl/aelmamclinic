// lib/services/chat_attachment_signer.dart
import 'dart:typed_data';
import 'package:supabase_flutter/supabase_flutter.dart';

class ChatAttachmentSigner {
  final SupabaseClient _sb;
  static const String bucket = 'chat-attachments';

  ChatAttachmentSigner(this._sb);

  /// يرفع ملف (upsert) على المسار القياسي: attachments/<conv>/<msg>/<file>
  Future<void> uploadBytes({
    required Uint8List bytes,
    required String conversationId,
    required String messageId,
    required String fileName,
    String contentType = 'application/octet-stream',
    bool upsert = true,
  }) async {
    final path = 'attachments/$conversationId/$messageId/$fileName';
    await _sb.storage.from(bucket).uploadBinary(
          path,
          bytes,
          fileOptions: FileOptions(
            upsert: upsert,
            contentType: contentType,
          ),
        );
  }

  /// يطلب URL موقّع من Edge Function: sign-attachment
  Future<Uri> sign({
    required String conversationId,
    required String messageId,
    required String fileName,
    Duration ttl = const Duration(minutes: 15),
  }) async {
    final path = 'attachments/$conversationId/$messageId/$fileName';
    final res = await _sb.functions.invoke(
      'sign-attachment',
      body: {
        'bucket': bucket,
        'path': path,
        'expiresIn': ttl.inSeconds,
      },
    );

    final data = (res.data is Map) ? (res.data as Map) : <String, dynamic>{};
    if (data['ok'] == true && data['signedUrl'] is String) {
      return Uri.parse(data['signedUrl'] as String);
    }
    throw Exception('sign-attachment failed: ${res.data}');
  }
}
