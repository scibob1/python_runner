import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:python_runner/features/scripts/application/script_workspace_controller.dart';
import 'package:python_runner/services/native_bridge.dart';

import '../../application/local_shell_prefs.dart';
import '../../application/python_launch.dart';
import '../../application/ssh_connection.dart' show HostKeyPrompt;
import '../../application/ssh_profile_store.dart';
import '../../application/terminal/debian_shell_session.dart';
import '../../application/terminal/local_shell_session.dart';
import '../../application/terminal/session_manager.dart';
import '../../application/terminal/terminal_session.dart';
import '../../domain/ssh_profile.dart';
import '../debian_runtime_settings.dart';
import '../python_launcher.dart' as launcher;
import '../python_run_dialogs.dart';
import '../ssh_text.dart';
import '../widgets/terminal_pane.dart';
import 'ssh_profiles_page.dart';
import 'terminal_logs_page.dart';

/// Opens the terminal page, optionally on a given session.
Future<void> openTerminalHub(BuildContext context, {String? sessionId}) {
  return Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => TerminalHubPage(initialSessionId: sessionId),
    ),
  );
}

/// Terminal sessions as tabs. Sessions keep running when this page is left.
class TerminalHubPage extends ConsumerStatefulWidget {
  const TerminalHubPage({super.key, this.initialSessionId});

  final String? initialSessionId;

  @override
  ConsumerState<TerminalHubPage> createState() => _TerminalHubPageState();
}

class _TerminalHubPageState extends ConsumerState<TerminalHubPage>
    implements TerminalHost {
  final TerminalSessionManager _manager = TerminalSessionManager.instance;
  String? _activeId;

  @override
  void initState() {
    super.initState();
    _activeId = widget.initialSessionId;
    _manager.addListener(_onSessionsChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _attachHost();
    });
  }

  @override
  void dispose() {
    _manager.removeListener(_onSessionsChanged);
    for (final session in _manager.sessions) {
      if (identical(session.host, this)) session.host = null;
    }
    super.dispose();
  }

  void _onSessionsChanged() {
    if (!mounted) return;
    _attachHost();
    setState(() {});
  }

  /// Gives every session a screen to ask questions on, and starts the ones
  /// that were created but never started.
  void _attachHost() {
    for (final session in _manager.sessions) {
      session.host ??= this;
      if (session.status == TerminalSessionStatus.idle) {
        unawaited(session.start());
      }
    }
  }

  TerminalSession? _active(List<TerminalSession> sessions) {
    if (sessions.isEmpty) return null;
    for (final session in sessions) {
      if (session.id == _activeId) return session;
    }
    return sessions.last;
  }

  // ── TerminalHost ──

  @override
  Future<void> launchPython(PythonLaunch launch) async {
    if (!mounted) return;
    await launcher.launchPython(context, ref, launch);
  }

  @override
  List<String> scriptNames() => ref
      .read(scriptWorkspaceControllerProvider)
      .scripts
      .map((script) => script.name)
      .toList();

  @override
  Future<String> readScript(String name) => ref
      .read(scriptWorkspaceControllerProvider.notifier)
      .readScript(name);

  @override
  Future<String?> askSecret(String title) async {
    if (!mounted) return null;
    final t = SshText.of(context);
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          obscureText: true,
          autofocus: true,
          enableSuggestions: false,
          autocorrect: false,
          onSubmitted: (value) => Navigator.pop(ctx, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(t('取消', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: Text(t('连接', 'Connect')),
          ),
        ],
      ),
    );
  }

  @override
  Future<bool> confirmHostKey(HostKeyPrompt prompt) async {
    if (!mounted) return false;
    final t = SshText.of(context);
    final previous = prompt.previousFingerprint;
    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(
          previous == null
              ? t('信任此主机？', 'Trust this host?')
              : t('主机密钥已变化！', 'Host key changed!'),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${prompt.host}:${prompt.port}  (${prompt.keyType})'),
              const SizedBox(height: 8),
              SelectableText(
                prompt.fingerprint,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
              if (previous != null) ...[
                const SizedBox(height: 12),
                Text(t('之前信任的指纹：', 'Previously trusted:')),
                SelectableText(
                  previous,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
                const SizedBox(height: 8),
                Text(
                  t(
                    '可能是服务器重装了系统，也可能有人在中途拦截连接。确认无误再继续。',
                    'The server may have been reinstalled, or someone may be intercepting the connection. Continue only if you are sure.',
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t('拒绝', 'Reject')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t('信任并继续', 'Trust & continue')),
          ),
        ],
      ),
    );
    return accepted ?? false;
  }

  // ── actions ──

  void _toast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  void _newLocal() {
    try {
      final session = _manager.createLocal();
      setState(() => _activeId = session.id);
    } on StateError catch (e) {
      _toast(e.message);
    }
  }

  void _newDebian() {
    try {
      final session = _manager.createDebian();
      setState(() => _activeId = session.id);
    } on StateError catch (e) {
      _toast(e.message);
    }
  }

  void _newSsh(SshProfile profile) {
    try {
      final session = _manager.createSsh(profile);
      setState(() => _activeId = session.id);
    } on StateError catch (e) {
      _toast(e.message);
    }
  }

  Future<void> _showNewSessionSheet() async {
    final t = SshText.of(context);
    final profiles = await SshProfileStore.instance.loadProfiles();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              leading: const Icon(Icons.terminal),
              title: Text(t('本机 Shell', 'Local shell')),
              subtitle: Text(
                t(
                  'Android 自带 sh，看不到 Debian 里的文件',
                  "Android's own sh, cannot see Debian files",
                ),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _newLocal();
              },
            ),
            ListTile(
              leading: const Icon(Icons.developer_board),
              title: Text(t('Debian 终端', 'Debian terminal')),
              subtitle: Text(
                t(
                  'proot 里的 Debian：python3、pip、/python-runner',
                  'Debian in proot: python3, pip, /python-runner',
                ),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _newDebian();
              },
            ),
            for (final profile in profiles)
              ListTile(
                leading: const Icon(Icons.dns_outlined),
                title: Text(profile.name),
                subtitle: Text(profile.endpoint),
                onTap: () {
                  Navigator.pop(ctx);
                  _newSsh(profile);
                },
              ),
            ListTile(
              leading: const Icon(Icons.settings_ethernet),
              title: Text(t('管理 SSH 主机…', 'Manage SSH hosts…')),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => const SshProfilesPage(),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _closeSession(TerminalSession session) async {
    await _manager.remove(session.id);
    if (mounted && _activeId == session.id) {
      setState(() => _activeId = null);
    }
  }

  String _shellQuote(String value) {
    final escaped = value.replaceAll("'", r"'\''");
    return "'$escaped'";
  }

  /// "Script working directory": `cd` into the directory scripts run in.
  Future<void> _enterScriptDir(TerminalSession? session) async {
    final t = SshText.of(context);
    final dir = await LocalShellPrefs.loadScriptWorkingDir();
    if (!mounted) return;
    if (dir == null) {
      _toast(
        t(
          '还没有设置脚本工作目录（在设置里可以设置）',
          'No script working directory is set (see Settings)',
        ),
      );
      return;
    }
    session?.sendText('cd ${_shellQuote(dir)}\n');
  }

  Future<void> _exportSessionLog(TerminalSession session) async {
    final t = SshText.of(context);
    final text = session.ring.read(0, maxChars: 1000000).text;
    if (text.trim().isEmpty) {
      _toast(t('没有可导出的内容', 'Nothing to export'));
      return;
    }
    final name = session.title.replaceAll(RegExp(r'[^A-Za-z0-9_.-]+'), '_');
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(RegExp(r'[^0-9]'), '')
        .substring(0, 14);
    try {
      final path = await NativeBridge().exportLog(
        text,
        fileName: 'terminal-$name-$stamp.txt',
      );
      if (!mounted) return;
      _toast(
        path.isEmpty
            ? t('已导出', 'Exported')
            : t('已导出到 $path', 'Exported to $path'),
      );
    } catch (e) {
      if (!mounted) return;
      _toast(t('导出失败：$e', 'Export failed: $e'));
    }
  }

  PopupMenuItem<String> _item(SshText t, String value, String zh, String en) {
    return PopupMenuItem<String>(value: value, child: Text(t(zh, en)));
  }

  /// The ⋮ menu: what is offered depends on the kind of the current session.
  List<PopupMenuEntry<String>> _menuEntries(
    SshText t,
    TerminalSession? session,
  ) {
    final entries = <PopupMenuEntry<String>>[];
    if (session is LocalShellSession) {
      entries
        ..add(_item(t, 'startDir', '启动目录…', 'Start directory…'))
        ..add(_item(t, 'scriptDir', '脚本工作目录', 'Script working directory'))
        ..add(_item(t, 'help', '内置命令说明', 'Built-in commands'))
        ..add(_item(t, 'interrupt', '中断 (SIGINT)', 'Interrupt (SIGINT)'))
        ..add(_item(t, 'forceStop', '强制结束', 'Force stop'))
        ..add(_item(t, 'closeTab', '关闭此终端', 'Close this terminal'));
    } else if (session is DebianShellSession) {
      entries
        ..add(_item(t, 'interrupt', '中断 (SIGINT)', 'Interrupt (SIGINT)'))
        ..add(_item(t, 'forceStop', '强制结束', 'Force stop'))
        ..add(_item(t, 'closeTab', '关闭此终端', 'Close this terminal'));
    } else if (session != null) {
      entries
        ..add(_item(t, 'disconnect', '断开连接', 'Disconnect'))
        ..add(_item(t, 'reconnect', '重新连接', 'Reconnect'))
        ..add(_item(t, 'interrupt', '中断', 'Interrupt'));
    }
    if (session != null) {
      entries
        ..add(const PopupMenuDivider())
        ..add(_item(t, 'clear', '清屏', 'Clear screen'))
        ..add(_item(t, 'export', '导出本会话日志', 'Export this session log'));
    }
    entries
      ..add(const PopupMenuDivider())
      ..add(
        _item(
          t,
          'debianSettings',
          'Debian 运行时设置…',
          'Debian runtime settings…',
        ),
      )
      ..add(_item(t, 'debianDiagnostics', '运行时诊断', 'Runtime diagnostics'));
    return entries;
  }

  Future<void> _onMenu(String value, TerminalSession? session) async {
    switch (value) {
      case 'startDir':
        final t = SshText.of(context);
        final changed = await showLocalShellSettingsDialog(context);
        if (!mounted) return;
        if (changed && session != null) {
          _toast(
            t(
              '启动目录已保存，正在重启此终端',
              'Start directory saved, restarting this terminal',
            ),
          );
          unawaited(session.restart());
        }
      case 'scriptDir':
        await _enterScriptDir(session);
      case 'help':
        if (session is LocalShellSession) session.printHelp();
      case 'interrupt':
        session?.interrupt();
      case 'forceStop':
      case 'disconnect':
        await session?.close();
      case 'reconnect':
        if (session != null) unawaited(session.restart());
      case 'closeTab':
        if (session != null) await _closeSession(session);
      case 'clear':
        session?.terminal.write('\x1b[3J\x1b[2J\x1b[H');
      case 'export':
        if (session != null) await _exportSessionLog(session);
      case 'debianSettings':
        await showDebianRuntimeSettingsDialog(context);
      case 'debianDiagnostics':
        await openDebianDiagnostics(context);
    }
  }

  Color _statusColor(TerminalSessionStatus status) => switch (status) {
        TerminalSessionStatus.running => Colors.greenAccent,
        TerminalSessionStatus.connecting => Colors.amber,
        TerminalSessionStatus.failed => Colors.redAccent,
        _ => Colors.grey,
      };

  PreferredSizeWidget _buildTabs(
    List<TerminalSession> sessions,
    TerminalSession? active,
  ) {
    return PreferredSize(
      preferredSize: const Size.fromHeight(40),
      child: SizedBox(
        height: 40,
        child: ListView(
          scrollDirection: Axis.horizontal,
          children: [
            for (final session in sessions)
              InkWell(
                onTap: () => setState(() => _activeId = session.id),
                child: Container(
                  padding: const EdgeInsets.only(left: 12, right: 4),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        width: 2,
                        color: identical(session, active)
                            ? Theme.of(context).colorScheme.primary
                            : Colors.transparent,
                      ),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.circle,
                        size: 9,
                        color: _statusColor(session.status),
                      ),
                      const SizedBox(width: 6),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 140),
                        child: Text(
                          session.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        iconSize: 16,
                        icon: const Icon(Icons.close),
                        onPressed: () => _closeSession(session),
                      ),
                    ],
                  ),
                ),
              ),
            IconButton(
              icon: const Icon(Icons.add),
              onPressed: _showNewSessionSheet,
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = SshText.of(context);
    final sessions = _manager.sessions;
    final active = _active(sessions);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(t('终端', 'Terminal')),
        bottom: _buildTabs(sessions, active),
        actions: [
          IconButton(
            icon: const Icon(Icons.receipt_long_outlined),
            tooltip: t('日志', 'Logs'),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => const TerminalLogsPage(),
              ),
            ),
          ),
          if (active != null)
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: t('重新连接 / 重启', 'Reconnect / restart'),
              onPressed: () => unawaited(active.restart()),
            ),
          PopupMenuButton<String>(
            tooltip: t('更多', 'More'),
            onSelected: (value) => unawaited(_onMenu(value, active)),
            itemBuilder: (_) => _menuEntries(t, active),
          ),
        ],
      ),
      body: active == null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.terminal, size: 48, color: Colors.white38),
                  const SizedBox(height: 12),
                  Text(
                    t('没有打开的终端', 'No terminal is open'),
                    style: const TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _showNewSessionSheet,
                    icon: const Icon(Icons.add),
                    label: Text(t('新建终端', 'New terminal')),
                  ),
                ],
              ),
            )
          : SafeArea(
              child: TerminalPane(
                key: ValueKey(active.id),
                terminal: active.terminal,
                filter: active.filter,
              ),
            ),
    );
  }
}
