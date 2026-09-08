/// Settings screen: curated sections over the exposed configuration
/// namespaces. Mobile is a lightweight viewer — complex and sensitive
/// configuration (plugins, provider catalogs, credentials) is read-only here
/// and edited on the desktop; the only in-app edit is the appearance
/// preference. Copy mirrors the web locales verbatim.
library;

import 'dart:convert';

import 'package:dsh_dart_sdk/dsh_dart_sdk.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../state/connection_controller.dart';
import '../state/theme_controller.dart';

/// Shipped app version shown in the About section; keep in sync with
/// `pubspec.yaml` `version:`.
  const _appVersion = '1.0.96';

/// Settings namespaces mapped into the 插件 section (web's configurable plugin
/// cards). Read-only on mobile.
const _pluginNamespaces = <String, String>{
  'shell': 'Shell（命令执行）',
  'agent-loop': 'Agent 循环',
  'web-search-deepseek': 'Web 搜索',
};

/// Friendly labels for common field keys; unknown keys fall back to the raw
/// key.
const _fieldLabels = <String, String>{
  'apiKeyEnv': 'API 密钥环境变量',
  'baseURL': 'Base URL',
  'thinking': '思考模式',
  'reasoningEffort': '推理强度',
  'maxTokens': '最大 Token 数',
  'defaultContextWindow': '默认上下文窗口',
  'models': '模型列表',
  'streamIdleTimeoutMs': '流式空闲超时',
  'retryPolicy': '重试策略',
  'timeoutMs': '命令超时',
  'graceMs': '宽限期',
  'maxOutputBytes': '输出上限（字节）',
  'cwd': '工作目录',
  'pwshPath': 'PowerShell 路径',
  'maxParallelToolCalls': '并行工具调用上限',
  'apiKey': 'API 密钥',
  'model': '模型',
  'apiVersion': 'API 版本',
  'maxUses': '最大使用次数',
  'preference': '偏好',
  'defaultPreset': '默认预设',
  'default': '默认预设',
  'providers': '提供方',
};

/// Curated settings screen over the host's configuration namespaces.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.connection, required this.themeController});

  final ConnectionController connection;

  /// App appearance preference; the 通用 外观 row writes through it.
  final ThemeController themeController;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  SettingsDescribeResult? _describe;
  List<ConfigurableProviderView> _providers = const [];
  bool _loading = true;
  String? _error;

  /// Speech plugin health: null = not probed, true = available, false = absent.
  bool? _speechAvailable;
  bool _speechProbing = false;

  @override
  void initState() {
    super.initState();
    widget.themeController.addListener(_onThemeChanged);
    _load();
  }

  @override
  void dispose() {
    widget.themeController.removeListener(_onThemeChanged);
    super.dispose();
  }

  void _onThemeChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final describe = await widget.connection.config.settingsDescribe();
      final providers = await widget.connection.config.llmProviders();
      if (!mounted) return;
      setState(() {
        _describe = describe;
        _providers = providers;
        _loading = false;
      });
      _probeSpeech();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _probeSpeech() async {
    setState(() { _speechProbing = true; });
    final client = DshSpeechClient(
      baseUrl: widget.connection.baseUrl,
      token: widget.connection.token,
    );
    final ok = await client.health();
    if (!mounted) return;
    setState(() {
      _speechAvailable = ok;
      _speechProbing = false;
    });
  }

  Future<void> _openSpeechConfig() async {
    final client = DshSpeechClient(
      baseUrl: widget.connection.baseUrl,
      token: widget.connection.token,
    );
    final url = Uri.parse(client.configPageUrl());
    await launchUrl(url, mode: LaunchMode.externalApplication);
  }

  SettingsNamespaceView? _ns(String name) {
    final namespaces = _describe?.namespaces ?? const <SettingsNamespaceView>[];
    for (final ns in namespaces) {
      if (ns.ns == name) return ns;
    }
    return null;
  }

  Object? _value(String ns, String field) => _ns(ns)?.value?[field];

  String _localeLabel() {
    switch (_value('locale', 'preference')) {
      case 'zh':
        return '简体中文';
      case 'en':
        return 'English';
      default:
        return '跟随系统';
    }
  }

  String _permissionLabel() {
    final preset = _value('permission', 'defaultPreset');
    if (preset is! String) return '—';
    return switch (preset) {
      'workspace-write' => '工作区写入',
      'danger-full-access' => '完全访问',
      _ => preset,
    };
  }

  String _agentPresetLabel() {
    final preset = _value('agent-presets', 'default');
    if (preset is! String) return '—';
    return preset.isEmpty ? '—' : preset;
  }

  String get _appearanceLabel => switch (widget.themeController.mode) {
        ThemeMode.dark => '深色',
        ThemeMode.light => '浅色',
        ThemeMode.system => '跟随系统',
      };

  void _openDetail(String ns, String title) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _NamespaceDetailScreen(connection: widget.connection, ns: ns, title: title),
      ),
    );
  }

  Future<void> _showAppearancePicker() async {
    const options = <(ThemeMode, String)>[
      (ThemeMode.dark, '深色'),
      (ThemeMode.light, '浅色'),
      (ThemeMode.system, '跟随系统'),
    ];
    final choice = await showModalBottomSheet<ThemeMode>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(
                '外观',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
            ),
            for (final (mode, label) in options)
              ListTile(
                leading: Icon(
                  mode == widget.themeController.mode
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: mode == widget.themeController.mode
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
                title: Text(label),
                onTap: () => Navigator.of(context).pop(mode),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice != null) await widget.themeController.setMode(choice);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _ErrorView(message: _error!, onRetry: _load)
              : ListView(
                  padding: const EdgeInsets.only(bottom: 24),
                  children: [
                    const _SectionHeader('通用'),
                    _row(
                      icon: Icons.palette_outlined,
                      title: '外观',
                      subtitle: _appearanceLabel,
                      onTap: _showAppearancePicker,
                    ),
                    _row(
                      icon: Icons.language,
                      title: '语言',
                      subtitle: _localeLabel(),
                      onTap: () => _openDetail('locale', '语言'),
                    ),
                    _row(
                      icon: Icons.admin_panel_settings_outlined,
                      title: '权限预设',
                      subtitle: _permissionLabel(),
                      onTap: () => _openDetail('permission', '权限预设'),
                    ),
                    const Divider(),
                    const _SectionHeader('模型'),
                    ..._modelRows(),
                    const Divider(),
                    const _SectionHeader('Agent 预设'),
                    _row(
                      icon: Icons.assignment_outlined,
                      title: '默认预设',
                      subtitle: _agentPresetLabel(),
                      onTap: () => _openDetail('agent-presets', 'Agent 预设'),
                    ),
                    const Divider(),
                    const _SectionHeader('插件'),
                    ..._pluginRows(),
                    const Divider(),
                    const _SectionHeader('语音'),
                    _row(
                      icon: Icons.mic_outlined,
                      title: '语音服务',
                      subtitle: _speechProbing
                          ? '检测中…'
                          : _speechAvailable == true
                              ? '已连接 · 点击配置提供商'
                              : (_speechAvailable == false ? '未安装' : '未检测'),
                      onTap: _speechAvailable == true ? _openSpeechConfig : _probeSpeech,
                    ),
                    const Divider(),
                    const _SectionHeader('关于'),
                    _row(
                      icon: Icons.dns_outlined,
                      title: '服务器',
                      subtitle: widget.connection.baseUrl.toString(),
                      onTap: null,
                    ),
                    _row(
                      icon: Icons.info_outline,
                      title: '版本',
                      subtitle: 'DeepSeek Harness 移动端 v$_appVersion',
                      onTap: null,
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                      child: Text(
                        '插件与模型等高级配置请在桌面端修改',
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
      floatingActionButton: FloatingActionButton.small(
        tooltip: '刷新',
        onPressed: _load,
        child: const Icon(Icons.refresh),
      ),
    );
  }

  List<Widget> _modelRows() {
    final rows = <Widget>[];
    for (final provider in _providers) {
      rows.add(
        _row(
          icon: provider.active ? Icons.cloud_done : Icons.cloud_outlined,
          title: provider.displayName,
          subtitle: provider.active ? '活跃' : '未激活',
          onTap: () => _openDetail(provider.settingsNs, provider.displayName),
        ),
      );
    }
    // Fallback: a model-provider namespace the provider directory did not list.
    for (final ns in _describe?.namespaces ?? const <SettingsNamespaceView>[]) {
      if (ns.ns.startsWith('llm-') && !_providers.any((p) => p.settingsNs == ns.ns)) {
        rows.add(_row(icon: Icons.cloud_outlined, title: ns.ns, onTap: () => _openDetail(ns.ns, ns.ns)));
      }
    }
    if (rows.isEmpty) {
      rows.add(const ListTile(title: Text('无可用提供方'), enabled: false));
    }
    return rows;
  }

  List<Widget> _pluginRows() {
    final rows = <Widget>[];
    for (final entry in _pluginNamespaces.entries) {
      final ns = _ns(entry.key);
      if (ns == null) continue;
      rows.add(
        _row(
          icon: Icons.extension_outlined,
          title: entry.value,
          subtitle: '只读 · 桌面端修改',
          onTap: () => _openDetail(entry.key, entry.value),
        ),
      );
    }
    if (rows.isEmpty) {
      rows.add(const ListTile(title: Text('没有可配置的插件'), enabled: false));
    }
    return rows;
  }

  Widget _row({
    required IconData icon,
    required String title,
    String? subtitle,
    VoidCallback? onTap,
  }) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle),
      trailing: onTap == null ? null : const Icon(Icons.chevron_right, size: 20),
      onTap: onTap,
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        text,
        style: TextStyle(
          fontWeight: FontWeight.bold,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
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
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.tonal(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}

/// Read-only detail view of one settings namespace's redacted value.
/// Configuration changes belong on the desktop; this page only renders what
/// the host exposes.
class _NamespaceDetailScreen extends StatefulWidget {
  const _NamespaceDetailScreen({
    required this.connection,
    required this.ns,
    required this.title,
  });

  final ConnectionController connection;
  final String ns;
  final String title;

  @override
  State<_NamespaceDetailScreen> createState() => _NamespaceDetailScreenState();
}

class _NamespaceDetailScreenState extends State<_NamespaceDetailScreen> {
  SettingsNamespaceView? _view;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final describe = await widget.connection.config.settingsDescribe();
      final view = describe.namespaces.where((n) => n.ns == widget.ns).firstOrNull;
      if (!mounted) return;
      setState(() {
        _view = view;
        _loading = false;
        if (view == null) _error = '命名空间 ${widget.ns} 未暴露';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.open_in_browser, size: 22),
            tooltip: '在浏览器打开管理页',
            onPressed: () async {
              final base = widget.connection.baseUrl.toString();
              final token = widget.connection.token;
              final url = Uri.parse('$base/m/?token=$token');
              await launchUrl(url, mode: LaunchMode.externalApplication);
            },
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _ErrorView(message: _error!, onRetry: _load)
              : _view == null
                  ? const Center(child: Text('无视图'))
                  : ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        Text(
                          '生效方式 ${_view!.applies} · 修订 ${_view!.revision}',
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 8),
                        for (final entry in _view!.value?.entries ?? const <String, Object?>{}.entries)
                          _fieldTile(_fieldLabels[entry.key] ?? entry.key, entry.value),
                        if ((_view!.secrets).isNotEmpty) ...[
                          const SizedBox(height: 8),
                          const Text('凭据（值不在设备端显示）', style: TextStyle(fontWeight: FontWeight.w600)),
                          for (final secret in _view!.secrets)
                            _fieldTile(
                              secret.path.join(' > '),
                              secret.set ? '已配置' : '未配置',
                            ),
                        ],
                        const SizedBox(height: 16),
                        Text(
                          '此配置为只读。如需修改，请在桌面端打开「设置」。',
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
    );
  }

  Widget _fieldTile(String label, Object? value) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(label),
      subtitle: Text(_formatValue(value)),
    );
  }
}

String _formatValue(Object? value) {
  if (value is String) return value;
  if (value is num || value is bool) return '$value';
  if (value == null) return '—';
  return const JsonEncoder.withIndent('  ').convert(value);
}
