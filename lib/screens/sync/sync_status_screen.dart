import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import 'package:aelmamclinic/app/theme/app_colors.dart';
import 'package:aelmamclinic/core/constants/app_spacing.dart';
import 'package:aelmamclinic/core/widgets/data_surface_widgets.dart';
import 'package:aelmamclinic/providers/auth_provider.dart';
import 'package:aelmamclinic/services/sync_diagnostics_service.dart';
import 'package:aelmamclinic/utils/l10n_extensions.dart';
import 'package:aelmamclinic/widgets/localized_text.dart';

class SyncStatusScreen extends StatefulWidget {
  const SyncStatusScreen({super.key, this.embedded = false});

  static const String routeName = '/sync/status';

  final bool embedded;

  @override
  State<SyncStatusScreen> createState() => _SyncStatusScreenState();
}

class _SyncStatusScreenState extends State<SyncStatusScreen> {
  static const SyncDiagnosticsService _diagnosticsService =
      SyncDiagnosticsService();

  Future<SyncDiagnosticsSnapshot>? _future;
  SyncDiagnosticsSnapshot? _latestSnapshot;
  bool _syncing = false;
  bool _exporting = false;
  bool _sharing = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    final auth = context.read<AuthProvider>();
    setState(() {
      _future = _diagnosticsService.collect(auth: auth).then((snapshot) {
        _latestSnapshot = snapshot;
        return snapshot;
      });
    });
  }

  Future<void> _syncNow() async {
    final messenger = ScaffoldMessenger.of(context);
    final auth = context.read<AuthProvider>();
    if (!auth.canEnterClinicShell) {
      messenger.showSnackBar(
        const SnackBar(
          content: LocalizedText(
            'هذا الدور لا يملك محرك مزامنة عيادة مباشر، تم تحديث التشخيص فقط.',
          ),
        ),
      );
      _reload();
      return;
    }
    setState(() => _syncing = true);
    try {
      await auth.syncNow();
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: LocalizedText('تم طلب تحديث المزامنة الآن.')),
      );
      _reload();
    } catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: LocalizedText('تعذر بدء تحديث المزامنة: $error'),
          backgroundColor: AppColors.danger,
        ),
      );
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _exportJson() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _exporting = true);
    try {
      final auth = context.read<AuthProvider>();
      final snapshot =
          _latestSnapshot ?? await _diagnosticsService.collect(auth: auth);
      final result = await _diagnosticsService.export(snapshot);
      try {
        await Clipboard.setData(
          ClipboardData(text: '${result.path}\n\n${result.jsonPreview}'),
        );
      } catch (_) {
        await Clipboard.setData(ClipboardData(text: result.path));
      }
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const LocalizedText('تم تصدير تقرير المزامنة'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const LocalizedText('تم حفظ ملف JSON ونسخ المسار إلى الحافظة:'),
              const SizedBox(height: AppSpacing.sm),
              SelectableText(result.path),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: result.path));
                Navigator.of(dialogContext).pop();
              },
              child: const LocalizedText('نسخ المسار'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const LocalizedText('تم'),
            ),
          ],
        ),
      );
    } catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: LocalizedText('فشل تصدير تقرير المزامنة: $error'),
          backgroundColor: AppColors.danger,
        ),
      );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _shareJson() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _sharing = true);
    try {
      final auth = context.read<AuthProvider>();
      final snapshot =
          _latestSnapshot ?? await _diagnosticsService.collect(auth: auth);
      final result = await _diagnosticsService.export(snapshot);
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(result.path)],
          text:
              'تقرير تشخيص ElmamClinic JSON - الدور: ${snapshot.summary['role'] ?? snapshot.scope}',
        ),
      );
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: LocalizedText('تم تجهيز ملف التشخيص للمشاركة.')),
      );
    } catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: LocalizedText('فشل مشاركة تقرير التشخيص: $error'),
          backgroundColor: AppColors.danger,
        ),
      );
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  Future<void> _copySummary(SyncDiagnosticsSnapshot snapshot) async {
    final summary = snapshot.summary;
    final text = <String>[
      'حالة المزامنة: ${_overallLabel(summary['overall'])}',
      'الدور: ${summary['role'] ?? snapshot.scope}',
      'الجلسة: ${summary['session_topology_state'] ?? '-'}',
      'الشبكة: ${summary['network_status'] ?? '-'}',
      'مرحلة المحرك: ${summary['sync_phase'] ?? 'غير مربوط'}',
      'جداول معلقة: ${summary['dirty_table_count'] ?? 0}',
      'مشاكل حرجة: ${summary['danger_issue_count'] ?? 0}',
      'تحذيرات: ${summary['warning_issue_count'] ?? 0}',
    ].join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: LocalizedText('تم نسخ ملخص حالة المزامنة.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final child = FutureBuilder<SyncDiagnosticsSnapshot>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError || !snapshot.hasData) {
          return _ErrorView(
            message: 'تعذر تحميل تشخيص المزامنة: ${snapshot.error}',
            onRetry: _reload,
          );
        }
        return _content(snapshot.data!);
      },
    );

    if (widget.embedded) {
      return child;
    }
    return Scaffold(
      appBar: AppBar(
        title: const LocalizedText('حالة المزامنة'),
        actions: [
          IconButton(
            tooltip: context.trRaw('تحديث التشخيص'),
            onPressed: _reload,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: SafeArea(child: child),
    );
  }

  Widget _content(SyncDiagnosticsSnapshot snapshot) {
    final tone = _overallTone(snapshot.summary['overall']);
    final auth = context.watch<AuthProvider>();
    final canRunClinicSync = auth.canEnterClinicShell;

    return RefreshIndicator(
      onRefresh: () async {
        _reload();
        await _future;
      },
      child: AppScreen(
        maxWidth: AppSpacing.maxWorkstationWidth,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppPageHeader(
              title: 'حالة المزامنة',
              subtitle:
                  'تشخيص شامل للمزامنة المحلية والسحابية حسب الدور الحالي، مع تصدير JSON كامل للفحص.',
              icon: Icons.sync_problem_rounded,
              statusChip: AppStatusChip(
                label: _overallLabel(snapshot.summary['overall']),
                tone: tone,
                icon: _overallIcon(snapshot.summary['overall']),
              ),
              actions: [
                FilledButton.icon(
                  onPressed: _syncing ? null : _syncNow,
                  icon: _syncing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.sync_rounded),
                  label: LocalizedText(
                    canRunClinicSync ? 'تحديث الآن' : 'تحديث التشخيص',
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: () => _copySummary(snapshot),
                  icon: const Icon(Icons.copy_rounded),
                  label: const LocalizedText('نسخ الملخص'),
                ),
                OutlinedButton.icon(
                  onPressed: _exporting ? null : _exportJson,
                  icon: _exporting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.file_download_outlined),
                  label: const LocalizedText('تصدير JSON'),
                ),
                OutlinedButton.icon(
                  onPressed: _sharing ? null : _shareJson,
                  icon: _sharing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.ios_share_rounded),
                  label: const LocalizedText('مشاركة JSON'),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),
            AppInfoBanner(
              tone: tone,
              icon: _overallIcon(snapshot.summary['overall']),
              title: _bannerTitle(snapshot),
              message: _bannerMessage(snapshot),
            ),
            const SizedBox(height: AppSpacing.lg),
            _metricGrid(snapshot),
            const SizedBox(height: AppSpacing.lg),
            _issuesSection(snapshot),
            const SizedBox(height: AppSpacing.lg),
            _runtimeSection(snapshot),
            const SizedBox(height: AppSpacing.lg),
            _tablesSection(snapshot),
            const SizedBox(height: AppSpacing.lg),
            _eventsSection(snapshot),
          ],
        ),
      ),
    );
  }

  Widget _metricGrid(SyncDiagnosticsSnapshot snapshot) {
    final summary = snapshot.summary;
    final runtime = snapshot.runtime;
    return AppResponsiveGrid(
      minItemWidth: 190,
      children: [
        AppMetricCard(
          label: 'الحالة',
          value: _overallLabel(summary['overall']),
          icon: _overallIcon(summary['overall']),
          tone: _overallTone(summary['overall']),
        ),
        AppMetricCard(
          label: 'الشبكة',
          value: '${summary['network_status'] ?? 'unknown'}',
          icon: summary['network_status'] == 'online'
              ? Icons.wifi_rounded
              : Icons.cloud_off_rounded,
          tone: summary['network_status'] == 'online'
              ? AppTone.success
              : AppTone.warning,
        ),
        AppMetricCard(
          label: 'مرحلة المحرك',
          value: '${summary['sync_phase'] ?? 'غير مربوط'}',
          icon: Icons.settings_backup_restore_rounded,
          tone: runtime == null ? AppTone.warning : AppTone.info,
          caption: '${summary['sync_phase_reason'] ?? ''}',
        ),
        AppMetricCard(
          label: 'معلق للدفع',
          value: '${summary['dirty_table_count'] ?? 0}',
          icon: Icons.cloud_upload_rounded,
          tone: snapshot.pendingDirtyTableCount > 0
              ? AppTone.warning
              : AppTone.success,
        ),
        AppMetricCard(
          label: 'Outbox المزامنة',
          value:
              '${summary['clinic_outbox_pending_count'] ?? 0}/${summary['clinic_outbox_failed_count'] ?? 0}',
          icon: Icons.outbox_rounded,
          tone:
              _asInt(summary['clinic_outbox_terminal_failed_count']) > 0 ||
                  _asInt(summary['clinic_outbox_conflict_count']) > 0
              ? AppTone.danger
              : _asInt(summary['clinic_outbox_failed_count']) > 0 ||
                    _asInt(summary['clinic_outbox_pending_count']) > 0
              ? AppTone.warning
              : AppTone.success,
          caption: 'معلقة / فاشلة',
        ),
        AppMetricCard(
          label: 'جداول مزامنة',
          value: '${summary['sync_table_count'] ?? 0}',
          icon: Icons.table_chart_rounded,
          tone: AppTone.primary,
        ),
        AppMetricCard(
          label: 'Outbox الدردشة',
          value:
              '${summary['chat_outbox_pending_count'] ?? 0}/${summary['chat_outbox_failed_count'] ?? 0}',
          icon: Icons.mark_chat_unread_rounded,
          tone: _asInt(summary['chat_outbox_failed_count']) > 0
              ? AppTone.danger
              : _asInt(summary['chat_outbox_pending_count']) > 0
              ? AppTone.warning
              : AppTone.success,
          caption: 'معلقة / فاشلة',
        ),
        AppMetricCard(
          label: 'الأخطاء والتحذيرات',
          value:
              '${summary['danger_issue_count'] ?? 0}/${summary['warning_issue_count'] ?? 0}',
          icon: Icons.report_problem_rounded,
          tone: snapshot.hasDanger
              ? AppTone.danger
              : snapshot.hasWarning
              ? AppTone.warning
              : AppTone.success,
          caption: 'حرجة / تحذيرات',
        ),
      ],
    );
  }

  Widget _issuesSection(SyncDiagnosticsSnapshot snapshot) {
    return AppSectionCard(
      title: 'المشاكل المكتشفة',
      subtitle: 'قائمة مرتبة بما يحتاج مراجعة أو إجراء.',
      icon: Icons.rule_rounded,
      tone: snapshot.hasDanger
          ? AppTone.danger
          : snapshot.hasWarning
          ? AppTone.warning
          : AppTone.success,
      child: Column(
        children: [
          for (final issue in snapshot.issues) ...[
            _IssueTile(issue: issue),
            const SizedBox(height: AppSpacing.sm),
          ],
        ],
      ),
    );
  }

  Widget _runtimeSection(SyncDiagnosticsSnapshot snapshot) {
    final runtime = snapshot.runtime;
    final auth = snapshot.auth;
    final network = snapshot.network;
    return AppSectionCard(
      title: 'حالة المحرك والجلسة',
      subtitle:
          'قراءة مباشرة من AuthProvider وSyncService وNetworkStatusService.',
      icon: Icons.memory_rounded,
      tone: AppTone.info,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              _FactChip(
                label: 'الدور',
                value: '${auth['role'] ?? snapshot.scope}',
              ),
              _FactChip(
                label: 'حالة الجلسة',
                value: '${auth['session_topology_state'] ?? '-'}',
              ),
              _FactChip(
                label: 'حساب',
                value: auth['has_account_context'] == true
                    ? 'موجود'
                    : 'غير جاهز',
              ),
              _FactChip(label: 'شبكة', value: '${network['status'] ?? '-'}'),
              _FactChip(
                label: 'آخر فحص',
                value: _formatIso(network['last_checked_at']),
              ),
              _FactChip(
                label: 'آخر وصول ناجح',
                value: _formatIso(network['last_reachable_at']),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          if (runtime == null)
            const Text(
              'محرك المزامنة غير مربوط لهذا الدور أو لم يتم تهيئته بعد.',
            )
          else
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                _FactChip(label: 'المرحلة', value: '${runtime['phase']}'),
                _FactChip(label: 'السبب', value: '${runtime['phase_reason']}'),
                _FactChip(
                  label: 'Realtime',
                  value: runtime['realtime_enabled'] == true ? 'نشط' : 'متوقف',
                ),
                _FactChip(
                  label: 'اشتراكات',
                  value: '${runtime['active_subscription_count'] ?? 0}',
                ),
                _FactChip(
                  label: 'آخر Pull',
                  value: _formatIso(runtime['last_pull_at']),
                ),
                _FactChip(
                  label: 'آخر Realtime',
                  value: _formatIso(runtime['last_realtime_event_at']),
                ),
              ],
            ),
          const SizedBox(height: AppSpacing.md),
          _JsonExpansion(
            title: 'عرض JSON المحرك والجلسة',
            payload: {'auth': auth, 'network': network, 'runtime': runtime},
          ),
        ],
      ),
    );
  }

  Widget _tablesSection(SyncDiagnosticsSnapshot snapshot) {
    return AppSectionCard(
      title: 'الجداول وخرائط المزامنة',
      subtitle:
          'ملخص لكل جدول يملك أعمدة المزامنة مع dirty/mapping/identity checks.',
      icon: Icons.storage_rounded,
      tone: AppTone.primary,
      child: snapshot.database['clinic_local_state_checked'] == false
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const AppInfoBanner(
                  tone: AppTone.info,
                  icon: Icons.admin_panel_settings_rounded,
                  title: 'هذا الدور لا يستخدم مزامنة عيادة محلية مباشرة',
                  message:
                      'تم تجاوز فحص جداول العيادة المحلية لأن الجلسة الحالية ليست ضمن نطاق owner/admin/employee لحساب عيادة. سيبقى JSON متضمنًا حالة الجلسة والأخطاء العامة.',
                ),
                const SizedBox(height: AppSpacing.md),
                _JsonExpansion(
                  title: 'عرض تفاصيل نطاق التشخيص',
                  payload: {'database': snapshot.database},
                ),
              ],
            )
          : Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppResponsiveGrid(
            minItemWidth: 220,
            children: snapshot.tableDiagnostics.take(12).map((table) {
              final dirty = table['dirty'] == true;
              final missing =
                  _asInt(table['missing_account_id_count']) +
                  _asInt(table['missing_device_id_count']) +
                  _asInt(table['missing_local_id_count']) +
                  _asInt(table['missing_updated_at_count']);
              final duplicates = _asInt(table['duplicate_sync_key_groups']);
              final tone = duplicates > 0 || missing > 0
                  ? AppTone.danger
                  : dirty
                  ? AppTone.warning
                  : AppTone.success;
              return AppListItemCard(
                title: '${table['table']}',
                subtitle:
                    'صفوف: ${table['row_count']} | ناقص هوية: $missing | تكرار: $duplicates',
                icon: Icons.table_rows_rounded,
                tone: tone,
                badges: [
                  AppStatusChip(
                    label: dirty ? 'dirty' : 'clean',
                    tone: dirty ? AppTone.warning : AppTone.success,
                  ),
                ],
              );
            }).toList(),
          ),
          if (snapshot.tableDiagnostics.length > 12) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              'تم عرض أول 12 جدولًا فقط هنا. ملف JSON يحتوي كل الجداول (${snapshot.tableDiagnostics.length}).',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: AppColors.textSecondary),
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          _JsonExpansion(
            title: 'عرض تفاصيل الجداول وخرائط المزامنة',
            payload: {
              'sync_tables': snapshot.tableDiagnostics,
              'mapping_diagnostics': snapshot.mappingDiagnostics,
              'database': snapshot.database,
            },
          ),
        ],
      ),
    );
  }

  Widget _eventsSection(SyncDiagnosticsSnapshot snapshot) {
    final runtimeHasError = snapshot.recentEvents.any(
      (event) => event['level'] == 'error',
    );
    final runtimeHasWarning = snapshot.recentEvents.any(
      (event) => event['level'] == 'warn',
    );
    final appErrorLogs = snapshot.appErrorLogs;
    final hasAppErrors = appErrorLogs.isNotEmpty;
    final tone = runtimeHasError || hasAppErrors
        ? AppTone.danger
        : runtimeHasWarning
        ? AppTone.warning
        : AppTone.neutral;
    return AppSectionCard(
      title: 'الأخطاء والأحداث الأخيرة',
      subtitle:
          'تجميع آخر أحداث runtime العامة وسجل app_errors.log وليس أخطاء المزامنة فقط.',
      icon: Icons.fact_check_rounded,
      tone: tone,
      child: snapshot.recentEvents.isEmpty && appErrorLogs.isEmpty
          ? const Text('لا توجد أخطاء أو أحداث runtime مسجلة حاليًا.')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (appErrorLogs.isNotEmpty) ...[
                  const LocalizedText('آخر أخطاء التطبيق العامة:'),
                  const SizedBox(height: AppSpacing.sm),
                  for (final event in appErrorLogs.reversed.take(6)) ...[
                    AppListItemCard(
                      title: '${event['level'] ?? 'APP'} - ${event['ts'] ?? ''}',
                      subtitle: '${event['message'] ?? ''}',
                      icon: Icons.error_outline_rounded,
                      tone: AppTone.danger,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                  ],
                  const SizedBox(height: AppSpacing.md),
                ],
                if (snapshot.recentEvents.isNotEmpty) ...[
                  const LocalizedText('آخر أحداث runtime:'),
                  const SizedBox(height: AppSpacing.sm),
                  for (final event in snapshot.recentEvents.reversed.take(8)) ...[
                    AppListItemCard(
                      title: '${event['code'] ?? 'event'}',
                      subtitle:
                          '${event['message'] ?? event['error'] ?? event['scope'] ?? ''}',
                      icon: event['level'] == 'error'
                          ? Icons.error_outline_rounded
                          : event['level'] == 'warn'
                          ? Icons.warning_amber_rounded
                          : Icons.info_outline_rounded,
                      tone: event['level'] == 'error'
                          ? AppTone.danger
                          : event['level'] == 'warn'
                          ? AppTone.warning
                          : AppTone.info,
                      badges: [
                        AppStatusChip(
                          label: '${event['level'] ?? '-'}',
                          tone: event['level'] == 'error'
                              ? AppTone.danger
                              : event['level'] == 'warn'
                              ? AppTone.warning
                              : AppTone.info,
                        ),
                      ],
                      meta: [
                        Text('${event['ts'] ?? ''}'),
                        Text('${event['scope'] ?? ''}'),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.sm),
                  ],
                ],
                _JsonExpansion(
                  title: 'عرض كل الأخطاء والأحداث في التشخيص الحالي',
                  payload: {
                    'app_error_logs': appErrorLogs,
                    'recent_runtime_events': snapshot.recentEvents,
                  },
                ),
              ],
            ),
    );
  }

  String _bannerTitle(SyncDiagnosticsSnapshot snapshot) {
    final overall = snapshot.summary['overall'];
    if (overall == 'danger') return 'توجد مشاكل مزامنة تحتاج إجراء';
    if (overall == 'warning') return 'توجد مؤشرات تحتاج متابعة';
    return 'المزامنة لا تظهر بها مشكلة حاليًا';
  }

  String _bannerMessage(SyncDiagnosticsSnapshot snapshot) {
    final summary = snapshot.summary;
    if (summary['overall'] == 'danger') {
      return 'راجع قسم المشاكل المكتشفة أولًا. التقرير يحتوي تفاصيل الجداول والـ runtime لتحديد السبب بدقة.';
    }
    if (summary['overall'] == 'warning') {
      return 'يمكن الضغط على تحديث الآن ثم إعادة فحص التشخيص. إذا بقيت المؤشرات، صدّر JSON للفحص.';
    }
    return 'الفحص الحالي لا يبيّن أخطاء blocking أو جداول dirty أو مشاكل mapping واضحة.';
  }

  AppTone _overallTone(Object? value) {
    return switch (value?.toString()) {
      'danger' => AppTone.danger,
      'warning' => AppTone.warning,
      'success' => AppTone.success,
      _ => AppTone.neutral,
    };
  }

  IconData _overallIcon(Object? value) {
    return switch (value?.toString()) {
      'danger' => Icons.sync_problem_rounded,
      'warning' => Icons.warning_amber_rounded,
      'success' => Icons.cloud_done_rounded,
      _ => Icons.help_outline_rounded,
    };
  }

  String _overallLabel(Object? value) {
    return switch (value?.toString()) {
      'danger' => 'تحتاج إجراء',
      'warning' => 'تحتاج متابعة',
      'success' => 'سليمة',
      _ => 'غير معروف',
    };
  }

  String _formatIso(Object? value) {
    final raw = value?.toString();
    if (raw == null || raw.trim().isEmpty || raw == 'null') {
      return 'لم يحدث';
    }
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return raw;
    final local = parsed.toLocal();
    return '${local.year.toString().padLeft(4, '0')}-'
        '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }

  int _asInt(Object? value) {
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}

class _IssueTile extends StatelessWidget {
  const _IssueTile({required this.issue});

  final JsonMap issue;

  @override
  Widget build(BuildContext context) {
    final severity = issue['severity']?.toString() ?? 'neutral';
    final tone = switch (severity) {
      'danger' => AppTone.danger,
      'warning' => AppTone.warning,
      'success' => AppTone.success,
      _ => AppTone.neutral,
    };
    return AppListItemCard(
      title: '${issue['title'] ?? issue['code'] ?? ''}',
      subtitle: '${issue['recommendation'] ?? ''}',
      icon: switch (severity) {
        'danger' => Icons.error_outline_rounded,
        'warning' => Icons.warning_amber_rounded,
        'success' => Icons.check_circle_outline_rounded,
        _ => Icons.info_outline_rounded,
      },
      tone: tone,
      badges: [
        AppStatusChip(label: '${issue['code'] ?? severity}', tone: tone),
      ],
      maxTitleLines: 3,
      actions: [
        if (issue.containsKey('evidence'))
          TextButton.icon(
            onPressed: () {
              showAppResponsiveDialog<void>(
                context: context,
                title: 'الدليل التقني',
                icon: Icons.manage_search_rounded,
                tone: tone,
                contentBuilder: (_) => SelectableText(
                  const JsonEncoder.withIndent('  ').convert(issue['evidence']),
                  textDirection: TextDirection.ltr,
                ),
              );
            },
            icon: const Icon(Icons.code_rounded),
            label: const LocalizedText('عرض الدليل'),
          ),
      ],
    );
  }
}

class _JsonExpansion extends StatelessWidget {
  const _JsonExpansion({required this.title, required this.payload});

  final String title;
  final Object? payload;

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: EdgeInsets.zero,
      title: LocalizedText(title),
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.border),
          ),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: SelectableText(
              const JsonEncoder.withIndent('  ').convert(payload),
              textDirection: TextDirection.ltr,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ),
      ],
    );
  }
}

class _FactChip extends StatelessWidget {
  const _FactChip({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Chip(
      label: Text('$label: $value'),
      backgroundColor: AppColors.surfaceMuted,
      side: BorderSide(color: AppColors.primary.withValues(alpha: 0.08)),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.sync_problem_rounded, color: AppColors.danger),
            const SizedBox(height: AppSpacing.md),
            LocalizedText(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: AppSpacing.md),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: const LocalizedText('إعادة المحاولة'),
            ),
          ],
        ),
      ),
    );
  }
}
