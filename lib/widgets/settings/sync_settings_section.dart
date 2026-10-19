import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/automation_settings_provider.dart';
import '../../providers/daily_attendance_provider.dart';
import '../../providers/webdav_sync_provider.dart';
import '../../utils/s1_snack_bar.dart';
import '../s1_confirm_dialog.dart';
import 'settings_section_header.dart';

class SyncSettingsSection extends ConsumerWidget {
  const SyncSettingsSection({super.key});

  Future<void> _configure(
    BuildContext context,
    WidgetRef ref,
    WebDavConfig? config,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _WebDavConnectionDialog(
        initial: config,
        onSave: ref.read(webDavConfigProvider.notifier).save,
      ),
    );
  }

  Future<void> _change(
    BuildContext context,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } catch (e) {
      if (context.mounted) {
        S1SnackBar.show(context, message: '无法保存设置，请检查本机安全存储后重试');
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connection = ref.watch(webDavConfigProvider);
    final config = connection.asData?.value;
    final automation = ref.watch(automationSettingsProvider);
    final sync = ref.watch(webDavSyncProvider);
    final attendance = ref.watch(dailyAttendanceProvider);
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final subtitleStyle =
        textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final status = sync.isSyncing
        ? '正在合并并同步…'
        : sync.error ??
            (sync.lastSuccess == null
                ? '尚未同步'
                : '上次成功：${MaterialLocalizations.of(context).formatFullDate(sync.lastSuccess!.toLocal())} '
                    '${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(sync.lastSuccess!.toLocal()))}');

    return Card(
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SettingsSectionHeader(title: '同步与自动化'),
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.cloud_outlined),
              title: const Text('WebDAV 连接'),
              subtitle: Text(
                connection.isLoading
                    ? '正在读取连接信息…'
                    : connection.hasError
                        ? '读取安全存储失败，点击重新配置'
                        : config == null
                            ? '配置服务器目录、用户名和应用专用密码'
                            : '已配置，凭据仅保存在本机',
                style: subtitleStyle,
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: sync.isSyncing || connection.isLoading
                  ? null
                  : () => _configure(context, ref, config),
            ),
            SwitchListTile(
              title: const Text('启动时自动同步'),
              subtitle: Text('每次冷启动同步一次，失败后可手动重试', style: subtitleStyle),
              value: automation.syncOnStartup,
              onChanged: config == null || sync.isSyncing
                  ? null
                  : (value) => _change(
                        context,
                        () => ref
                            .read(automationSettingsProvider.notifier)
                            .setSyncOnStartup(value),
                      ),
            ),
            ListTile(
              leading: sync.isSyncing
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.sync),
              title: const Text('立即同步'),
              subtitle: Text(
                status,
                style: subtitleStyle?.copyWith(
                  color: sync.error == null ? null : scheme.error,
                ),
              ),
              onTap: config == null || sync.isSyncing
                  ? null
                  : ref.read(webDavSyncProvider.notifier).sync,
            ),
            if (config != null)
              ListTile(
                leading: const Icon(Icons.link_off),
                title: const Text('移除 WebDAV 连接'),
                onTap: sync.isSyncing
                    ? null
                    : () async {
                        final confirmed = await showS1ConfirmDialog(
                          context,
                          title: '移除 WebDAV 连接',
                          content: '清除本机连接信息并关闭自动同步，云端文件保留。',
                          confirmLabel: '移除',
                        );
                        if (confirmed && context.mounted) {
                          await _change(
                            context,
                            ref.read(webDavConfigProvider.notifier).clear,
                          );
                        }
                      },
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                '同步现有备份中的设置、阅读历史、投票、黑名单和置顶帖。'
                '首次同项以云端为准；之后合并两端改动，同项冲突以本机为准，阅读进度取最近阅读。'
                'Cookie、草稿和同步凭据不上传。'
                '${kIsWeb ? ' Web 端需服务器允许 CORS，并暴露 ETag 响应头。' : ''}',
                style: subtitleStyle,
              ),
            ),
            Divider(color: scheme.outlineVariant),
            SwitchListTile(
              secondary: const Icon(Icons.event_available_outlined),
              title: const Text('自动签到'),
              subtitle:
                  Text('启动并恢复登录后签到，当天成功后跳过；失败不连续重试', style: subtitleStyle),
              value: automation.autoSign,
              onChanged: (value) => _change(
                context,
                () => ref
                    .read(automationSettingsProvider.notifier)
                    .setAutoSign(value),
              ),
            ),
            if (attendance.isSubmitting || attendance.result != null)
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text(
                  attendance.isSubmitting
                      ? '正在签到…'
                      : attendance.result!.message,
                  style: subtitleStyle,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _WebDavConnectionDialog extends StatefulWidget {
  const _WebDavConnectionDialog({required this.initial, required this.onSave});
  final WebDavConfig? initial;
  final Future<void> Function(WebDavConfig) onSave;

  @override
  State<_WebDavConnectionDialog> createState() =>
      _WebDavConnectionDialogState();
}

class _WebDavConnectionDialogState extends State<_WebDavConnectionDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _url = TextEditingController(text: widget.initial?.directoryUrl);
  late final _username = TextEditingController(text: widget.initial?.username);
  late final _password = TextEditingController(text: widget.initial?.password);
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || !_formKey.currentState!.validate()) return;
    final config = WebDavConfig(
      directoryUrl: _url.text.trim(),
      username: _username.text.trim(),
      password: _password.text,
    );
    try {
      config.directoryUri;
    } on FormatException catch (e) {
      setState(() => _error = e.message);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSave(config);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '保存失败，请检查本机安全存储后重试';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('WebDAV 连接'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '填写已存在的目录，所有设备使用同一目录。同步文件：${WebDavConfig.fileName}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _url,
                  enabled: !_saving,
                  decoration: const InputDecoration(
                    labelText: 'WebDAV 目录地址',
                    hintText: 'https://dav.example.com/s1er/',
                  ),
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  validator: (value) =>
                      value == null || value.trim().isEmpty ? '请输入目录地址' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _username,
                  enabled: !_saving,
                  decoration: const InputDecoration(labelText: '用户名'),
                  autocorrect: false,
                  validator: (value) =>
                      value == null || value.trim().isEmpty ? '请输入用户名' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _password,
                  enabled: !_saving,
                  decoration: const InputDecoration(labelText: '密码 / 应用专用密码'),
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  validator: (value) =>
                      value == null || value.isEmpty ? '请输入密码' : null,
                ),
                const SizedBox(height: 12),
                Text(
                  '建议使用 HTTPS。HTTP 会明文传输凭据和同步内容。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.error,
                        ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? '保存中…' : '保存'),
        ),
      ],
    );
  }
}
