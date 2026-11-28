/// What the native side returns for an interactive shell in the Debian guest.
class DebianShellLaunch {
  const DebianShellLaunch({
    required this.command,
    required this.environment,
    required this.tempDir,
    required this.shell,
    required this.compatMode,
  });

  factory DebianShellLaunch.fromMap(Map<Object?, Object?> raw) {
    final rawCommand = raw['command'];
    final command = rawCommand is List
        ? rawCommand.map((e) => e.toString()).toList()
        : <String>[];
    if (command.isEmpty) {
      throw const FormatException('The launch description has no command');
    }
    final environment = <String, String>{};
    final rawEnvironment = raw['environment'];
    if (rawEnvironment is Map) {
      rawEnvironment.forEach((key, value) {
        if (key != null && value != null) {
          environment[key.toString()] = value.toString();
        }
      });
    }
    return DebianShellLaunch(
      command: command,
      environment: environment,
      tempDir: raw['tempDir']?.toString() ?? '',
      shell: raw['shell']?.toString() ?? '',
      compatMode: raw['compatMode']?.toString() == 'true',
    );
  }

  /// proot plus its arguments, ending with the guest shell.
  final List<String> command;

  /// The complete environment of the proot process (the guest gets its own via `env -i`).
  final Map<String, String> environment;

  /// proot's temporary directory; handed back when the shell ends.
  final String tempDir;

  final String shell;
  final bool compatMode;

  String get executable => command.first;

  List<String> get arguments => command.sublist(1);
}

/// `bash -i` / `sh -i` over pipes complain about the missing terminal; harmless, so hidden.
final RegExp _shellNoise = RegExp(
  r"^(?:/bin/)?(?:ba)?sh: (?:\d+: )?(?:cannot set terminal process group[^\r\n]*|no job control in this shell|can't access tty; job control turned off|can't find tty fd[^\r\n]*|warning: won't have full job control)\r?\n",
  multiLine: true,
);

String stripShellNoise(String text) => text.replaceAll(_shellNoise, '');

/// The parent pid out of the text of `/proc/<pid>/stat` (`pid (comm) S ppid ...`).
int? parentPidFromStat(String stat) {
  // The command name may contain spaces and parentheses, so cut after the last ')'.
  final close = stat.lastIndexOf(')');
  if (close < 0) return null;
  final fields = stat.substring(close + 1).trim().split(RegExp(r'\s+'));
  if (fields.length < 2) return null;
  return int.tryParse(fields[1]);
}

/// All descendants of [root] (children first, breadth first), given pid -> parent pid.
List<int> descendantPids(Map<int, int> parents, int root) {
  final children = <int, List<int>>{};
  parents.forEach((pid, parent) {
    (children[parent] ??= <int>[]).add(pid);
  });
  final result = <int>[];
  final seen = <int>{root};
  final queue = <int>[root];
  while (queue.isNotEmpty) {
    final current = queue.removeAt(0);
    for (final child in children[current] ?? const <int>[]) {
      if (seen.add(child)) {
        result.add(child);
        queue.add(child);
      }
    }
  }
  return result;
}

/// The descendants of [root] that have no children of their own: the programs that are
/// actually running (an idle shell is a leaf too, and a SIGINT does not hurt it).
List<int> leafDescendantPids(Map<int, int> parents, int root) {
  final all = descendantPids(parents, root);
  final parentsOfDescendants = all
      .map((pid) => parents[pid])
      .whereType<int>()
      .toSet();
  return all.where((pid) => !parentsOfDescendants.contains(pid)).toList();
}
