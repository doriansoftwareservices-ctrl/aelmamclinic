class AdminSystemHealth {
  final int storageFiles;
  final int chatAttachments;
  final int pendingSubscriptions;
  final DateTime serverTime;

  const AdminSystemHealth({
    required this.storageFiles,
    required this.chatAttachments,
    required this.pendingSubscriptions,
    required this.serverTime,
  });

  factory AdminSystemHealth.fromJson(Map<String, dynamic> json) {
    final st = json['server_time']?.toString();
    return AdminSystemHealth(
      storageFiles: (json['storage_files'] is num)
          ? (json['storage_files'] as num).toInt()
          : int.tryParse('${json['storage_files']}') ?? 0,
      chatAttachments: (json['chat_attachments'] is num)
          ? (json['chat_attachments'] as num).toInt()
          : int.tryParse('${json['chat_attachments']}') ?? 0,
      pendingSubscriptions: (json['pending_subscriptions'] is num)
          ? (json['pending_subscriptions'] as num).toInt()
          : int.tryParse('${json['pending_subscriptions']}') ?? 0,
      serverTime: st == null
          ? DateTime.now()
          : DateTime.tryParse(st) ?? DateTime.now(),
    );
  }
}
