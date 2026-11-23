import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../local_line_discipline.dart';
import 'debian_shell_bridge.dart';
import 'debian_shell_support.dart';
import 'terminal_locale.dart';
import 'terminal_session.dart';

/// An interactive shell inside the Debian guest (proot), the same environment scripts
/// run in: `/python-runner/site-packages`, `python3`, `pip`, `apt`.
///
/// Like the local shell it runs over plain pipes (no PTY), so [LineDiscipline] provides
/// echo and line editing and full-screen programs such as vim or top do not work.
class DebianShellSession extends TerminalSession {
  DebianShellSession({
    required super.id,
    required super.title,
    DebianShellBridge bridge = const DebianShellBridge(),
  }) : _bridge = bridge,
       super(kind: 'debian') {
    _line = LineDiscipline(
      echo: echo,
      sendLine: _onLine,
      onInterrupt: _sigint,
      onEof: _eof,
    );
    terminal.onOutput = (data) => _typed(filter.apply(data), 'human');
  }

  final DebianShellBridge _bridge;
  late final LineDiscipline _line;
  Process? _process;
  StreamSubscription<String>? _outSub;
  StreamSubscription<String>? _errSub;
  int _generation = 0;
  bool _running = false;
  String _tempDir = '';
  String _actor = 'human';

  void _typed(String data, String actor) {
    _actor = actor;
    _line.feed(data);
    _actor = 'human';
  }

  @override
  void sendText(String text, {String actor = 'human'}) => _typed(text, actor);

  @override
  void interrupt() => _typed('\x03', _actor);

  void _onLine(String line) {
    logger.input(line, actor: _actor);
    _toShell(line);
  }

  void _toShell(String line) {
    final process = _process;
    if (process == null || !_running) return;
    process.stdin.add(utf8.encode('$line\n'));
  }

  void _eof() {
    final process = _process;
    if (process == null || !_running) return;
    unawaited(process.stdin.close());
  }

  /// Ctrl+C: SIGINT to the programs that are running inside the guest. Signalling proot
  /// itself would end the whole session, so the guest's own processes are found through
  /// /proc (they are descendants of the proot process).
  void _sigint() {
    unawaited(_interruptRunningPrograms());
  }

  Future<void> _interruptRunningPrograms() async {
    final process = _process;
    if (process == null || !_running) return;
    final parents = await _readParentPids();
    final targets = leafDescendantPids(parents, process.pid);
    if (targets.isEmpty) {
      info(
        tr(
          '无法中断：读不到 /proc 里的进程信息。可以用菜单里的“强制结束”。',
          'Cannot interrupt: the process list in /proc is not readable. Use "Force stop" from the menu.',
        ),
      );
      return;
    }
    for (final pid in targets) {
      Process.killPid(pid, ProcessSignal.sigint);
    }
  }

  /// pid -> parent pid for every process this app can see in /proc.
  Future<Map<int, int>> _readParentPids() async {
    final parents = <int, int>{};
    try {
      await for (final entity in Directory('/proc').list(followLinks: false)) {
        final pid = int.tryParse(entity.path.split('/').last);
        if (pid == null) continue;
        try {
          final stat = await File('${entity.path}/stat').readAsString();
          final parent = parentPidFromStat(stat);
          if (parent != null) parents[pid] = parent;
        } catch (_) {
          // The process ended, or its stat file is not readable.
        }
      }
    } catch (_) {
      // /proc is hidden: the caller reports that interrupting is not possible.
    }
    return parents;
  }

  Future<void> _releaseTempDir() async {
    final dir = _tempDir;
    _tempDir = '';
    if (dir.isNotEmpty) await _bridge.release(dir);
  }

  /// Ends the shell and everything it started: guest programs first, then proot.
  Future<void> _stopProcess() async {
    final out = _outSub;
    final err = _errSub;
    final process = _process;
    _outSub = null;
    _errSub = null;
    _process = null;
    _running = false;
    await out?.cancel();
    await err?.cancel();
    if (process != null) {
      final parents = await _readParentPids();
      for (final pid in descendantPids(parents, process.pid).reversed) {
        Process.killPid(pid, ProcessSignal.sigkill);
      }
      process.kill(ProcessSignal.sigkill);
    }
    await _releaseTempDir();
  }

  @override
  Future<void> start() async {
    final generation = ++_generation;
    setStatus(TerminalSessionStatus.connecting);
    await _stopProcess();
    info(tr('正在启动 Debian 终端 …', 'Starting the Debian terminal …'));

    final DebianShellLaunch launch;
    try {
      launch = await _bridge.prepare();
    } catch (e) {
      if (generation != _generation) return;
      error(tr('无法启动 Debian 终端：$e', 'Cannot start the Debian terminal: $e'));
      logger.event('session', 'failed to prepare: $e');
      setStatus(TerminalSessionStatus.failed, '$e');
      return;
    }
    if (generation != _generation) {
      unawaited(_bridge.release(launch.tempDir));
      return;
    }
    _tempDir = launch.tempDir;

    final mode = launch.compatMode ? tr('开', 'on') : tr('关', 'off');
    info(
      tr(
        'Debian 终端（${launch.shell}）。没有 PTY（伪终端），vim、top 这类全屏程序不可用。兼容模式（PROOT_NO_SECCOMP）：$mode。',
        'Debian terminal (${launch.shell}). No PTY (pseudo terminal): full-screen programs such as vim or top do not work. Compatibility mode (PROOT_NO_SECCOMP): $mode.',
      ),
    );

    try {
      final process = await Process.start(
        launch.executable,
        launch.arguments,
        environment: launch.environment,
        includeParentEnvironment: false,
      );
      if (generation != _generation) {
        process.kill(ProcessSignal.sigkill);
        unawaited(_releaseTempDir());
        return;
      }
      _process = process;
      _running = true;
      unawaited(process.stdin.done.catchError((Object _) => null));
      _outSub = process.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(_onShellOutput);
      _errSub = process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(_onShellOutput);
      unawaited(
        process.exitCode.then((code) {
          if (generation != _generation) return;
          _running = false;
          info(tr('[shell 已退出，代码 $code]', '[shell exited with code $code]'));
          logger.event('session', 'shell exited with code $code');
          setStatus(TerminalSessionStatus.closed, 'exit $code');
          unawaited(_releaseTempDir());
        }),
      );
      logger.event('session', 'opened debian shell', detail: launch.shell);
      setStatus(TerminalSessionStatus.running);
    } catch (e) {
      error(tr('启动 shell 失败：$e', 'Could not start the shell: $e'));
      logger.event('session', 'failed to start: $e');
      setStatus(TerminalSessionStatus.failed, '$e');
      unawaited(_releaseTempDir());
    }
  }

  void _onShellOutput(String text) {
    final cleaned = stripShellNoise(text);
    if (cleaned.isEmpty) return;
    emit(cleaned.replaceAll(RegExp(r'\r?\n'), '\r\n'));
  }

  @override
  Future<void> close() async {
    final wasAlive = isAlive;
    _generation++;
    await _stopProcess();
    if (wasAlive) logger.event('session', 'closed');
    setStatus(TerminalSessionStatus.closed);
  }
}
