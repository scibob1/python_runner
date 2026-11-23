import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../application/terminal/debian_shell_bridge.dart';
import 'ssh_text.dart';

/// Preference key of the proot compatibility mode (PROOT_NO_SECCOMP=1). The native side
/// reads the same store (as `flutter.` + this key) every time it starts proot; default on.
const String debianCompatModeKey = 'debian_proot_compat_mode';

Future<bool> loadDebianCompatMode() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool(debianCompatModeKey) ?? true;
}

/// The compatibility-mode switch and a shortcut to the runtime diagnostics.
Future<void> showDebianRuntimeSettingsDialog(BuildContext context) async {
  final compat = await loadDebianCompatMode();
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (_) => _DebianSettingsDialog(initialCompat: compat),
  );
}

/// Shows what the Debian runtime reports about itself, ready to copy.
Future<void> openDebianDiagnostics(BuildContext context) {
  return Navigator.push(
    context,
    MaterialPageRoute<void>(builder: (_) => const DebianDiagnosticsPage()),
  );
}

class _DebianSettingsDialog extends StatefulWidget {
  const _DebianSettingsDialog({required this.initialCompat});

  final bool initialCompat;

  @override
  State<_DebianSettingsDialog> createState() => _DebianSettingsDialogState();
}

class _DebianSettingsDialogState extends State<_DebianSettingsDialog> {
  late bool _compat = widget.initialCompat;

  Future<void> _setCompat(bool value) async {
    setState(() => _compat = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(debianCompatModeKey, value);
  }

  @override
  Widget build(BuildContext context) {
    final t = SshText.of(context);
    return AlertDialog(
      title: Text(t('Debian 运行时设置', 'Debian runtime settings')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(t('兼容模式', 'Compatibility mode')),
            subtitle: Text(
              t(
                '以 PROOT_NO_SECCOMP=1 运行 proot。在鸿蒙上关闭它会让 getcwd 等调用返回“功能未实现”。对之后新开的 Debian 终端和脚本生效，已打开的终端需要重启。',
                'Runs proot with PROOT_NO_SECCOMP=1. On HarmonyOS turning it off makes getcwd and similar calls fail with "Function not implemented". Applies to Debian terminals and scripts started afterwards; restart open terminals.',
              ),
            ),
            value: _compat,
            onChanged: _setCompat,
          ),
          const SizedBox(height: 4),
          OutlinedButton.icon(
            onPressed: () => openDebianDiagnostics(context),
            icon: const Icon(Icons.fact_check_outlined),
            label: Text(t('运行时诊断', 'Runtime diagnostics')),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t('关闭', 'Close')),
        ),
      ],
    );
  }
}

/// Every key/value the Debian runtime reports: paths, whether files are executable, the
/// compatibility mode and the results of the start-up probes. No adb is needed: copy the
/// text from here.
class DebianDiagnosticsPage extends StatefulWidget {
  const DebianDiagnosticsPage({super.key});

  @override
  State<DebianDiagnosticsPage> createState() => _DebianDiagnosticsPageState();
}

class _DebianDiagnosticsPageState extends State<DebianDiagnosticsPage> {
  bool _loading = true;
  String _text = '';
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final info = await const DebianShellBridge().runtimeInfo();
      final keys = info.keys.toList()..sort();
      final text = keys.map((key) => '$key = ${info[key]}').join('\n');
      if (!mounted) return;
      setState(() {
        _text = text;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _copy() async {
    final t = SshText.of(context);
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: _text));
    messenger.showSnackBar(
      SnackBar(
        content: Text(t('已复制', 'Copied')),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = SshText.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(t('Debian 运行时诊断', 'Debian runtime diagnostics')),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: t('刷新', 'Refresh'),
            onPressed: _loading ? null : () => unawaited(_load()),
          ),
          IconButton(
            icon: const Icon(Icons.copy_all_outlined),
            tooltip: t('复制全部', 'Copy all'),
            onPressed: _text.isEmpty ? null : () => unawaited(_copy()),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: SelectableText(
                _error != null
                    ? t('读取失败：$_error', 'Failed to read: $_error')
                    : _text,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
    );
  }
}
