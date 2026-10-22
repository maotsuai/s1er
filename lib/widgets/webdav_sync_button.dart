import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/webdav_sync_provider.dart';
import '../utils/s1_snack_bar.dart';
import 's1_adaptive_sheet.dart';

/// 自动同步只在既有顶栏显示轻量状态；详细信息由用户主动展开。
class WebDavSyncButton extends ConsumerStatefulWidget {
  const WebDavSyncButton({super.key});

  @override
  ConsumerState<WebDavSyncButton> createState() => _WebDavSyncButtonState();
}

class _WebDavSyncButtonState extends ConsumerState<WebDavSyncButton> {
  Timer? _successTimer;
  bool _showSuccess = false;

  @override
  void dispose() {
    _successTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(webDavConfigProvider).asData?.value;
    if (config == null) return const SizedBox.shrink();
    final sync = ref.watch(webDavSyncProvider);
    ref.listen(webDavSyncProvider, (previous, next) {
      if (next.lastSuccess == null ||
          previous?.lastSuccess == next.lastSuccess) {
        return;
      }
      _successTimer?.cancel();
      setState(() => _showSuccess = true);
      _successTimer = Timer(const Duration(seconds: 2), () {
        if (mounted) setState(() => _showSuccess = false);
      });
    });
    final tooltip = sync.isSyncing
        ? '正在同步'
        : sync.error != null
            ? '同步失败，点击查看'
            : sync.hasPendingChanges
                ? '有待同步改动'
                : _showSuccess
                    ? '已同步'
                    : 'WebDAV 同步';
    return IconButton(
      tooltip: tooltip,
      onPressed: () => showS1InfoSheet<void>(
        context: context,
        builder: (_) => const _SyncStatus(),
      ),
      icon: sync.isSyncing
          ? const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Badge(
              isLabelVisible: sync.error != null || sync.hasPendingChanges,
              backgroundColor: sync.error != null
                  ? Theme.of(context).colorScheme.error
                  : Theme.of(context).colorScheme.primary,
              child: Icon(
                sync.error != null
                    ? Icons.cloud_off_outlined
                    : _showSuccess
                        ? Icons.cloud_done_outlined
                        : Icons.cloud_outlined,
              ),
            ),
    );
  }
}

class _SyncStatus extends ConsumerWidget {
  const _SyncStatus();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sync = ref.watch(webDavSyncProvider);
    String time(DateTime value) {
      final localizations = MaterialLocalizations.of(context);
      final local = value.toLocal();
      return '${localizations.formatMediumDate(local)} ${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(local))}';
    }

    return S1AdaptiveSheetScaffold(
      title: 'WebDAV 同步',
      scrollable: true,
      maxHeightFactor: 0.8,
      children: [
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              sync.isSyncing
                  ? '正在合并并同步…'
                  : sync.error ??
                      (sync.hasPendingChanges
                          ? '有待同步改动'
                          : sync.lastSuccess == null
                              ? '尚未同步'
                              : '本机改动已同步'),
            ),
            const SizedBox(height: 8),
            Text(
              sync.lastSuccess == null
                  ? '尚未成功同步'
                  : '上次成功：${time(sync.lastSuccess!)}',
            ),
            if (sync.isPaused) const Text('自动同步已暂停，请检查 WebDAV 配置后重试。'),
            if (sync.hasPendingChanges &&
                sync.nextAttempt != null &&
                !sync.isPaused)
              Text('下次可同步：${time(sync.nextAttempt!)}'),
            if (sync.hasDeferredRefresh) const Text('云端界面设置将在离开帖子后应用。'),
            const SizedBox(height: 20),
            FilledButton.icon(
              icon: const Icon(Icons.sync),
              label: const Text('立即同步'),
              onPressed: sync.isSyncing
                  ? null
                  : () async {
                      await ref.read(webDavSyncProvider.notifier).sync();
                      if (!context.mounted) return;
                      final result = ref.read(webDavSyncProvider);
                      S1SnackBar.show(context, message: result.error ?? '同步成功');
                    },
            ),
          ],
        ),
      ],
    );
  }
}
