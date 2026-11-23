import 'package:flutter_test/flutter_test.dart';
import 'package:python_runner/features/ssh/application/terminal/debian_shell_support.dart';

void main() {
  group('DebianShellLaunch', () {
    test('parses the launch description of the native side', () {
      final launch = DebianShellLaunch.fromMap(<Object?, Object?>{
        'command': <Object?>[
          '/lib/libproot.so',
          '-r',
          '/rootfs',
          '/bin/bash',
          '--norc',
        ],
        'environment': <Object?, Object?>{'A': 'b', 'N': null},
        'tempDir': '/t',
        'shell': '/bin/bash',
        'compatMode': 'true',
      });
      expect(launch.executable, '/lib/libproot.so');
      expect(launch.arguments, <String>[
        '-r',
        '/rootfs',
        '/bin/bash',
        '--norc',
      ]);
      expect(launch.environment, <String, String>{'A': 'b'});
      expect(launch.tempDir, '/t');
      expect(launch.compatMode, isTrue);
    });

    test('rejects a description without a command', () {
      expect(
        () => DebianShellLaunch.fromMap(<Object?, Object?>{
          'command': <Object?>[],
        }),
        throwsFormatException,
      );
    });
  });

  group('stripShellNoise', () {
    test('hides the missing-terminal complaints of bash and dash', () {
      expect(
        stripShellNoise(
          'bash: cannot set terminal process group (-1): Inappropriate ioctl for device\n'
          'bash: no job control in this shell\n'
          'root # ',
        ),
        'root # ',
      );
      expect(
        stripShellNoise("sh: 0: can't access tty; job control turned off\n# "),
        '# ',
      );
    });

    test('keeps real errors', () {
      const text = 'bash: foo: command not found\n';
      expect(stripShellNoise(text), text);
    });
  });

  group('process tree', () {
    test('reads the parent pid out of /proc/<pid>/stat', () {
      expect(parentPidFromStat('123 (bash) S 45 123 123 0 -1'), 45);
      expect(parentPidFromStat('9 (a (b) c) R 7 1 1'), 7);
      expect(parentPidFromStat('garbage'), isNull);
    });

    test('finds descendants and the programs that are running', () {
      // proot(100) -> bash(101) -> sleep(102) and a pipeline cat(103) | grep(104)
      final parents = <int, int>{
        101: 100,
        102: 101,
        103: 101,
        104: 101,
        201: 200,
        200: 1,
      };
      expect(
        descendantPids(parents, 100),
        unorderedEquals(<int>[101, 102, 103, 104]),
      );
      expect(
        leafDescendantPids(parents, 100),
        unorderedEquals(<int>[102, 103, 104]),
      );
    });

    test('an idle shell is the only leaf', () {
      expect(leafDescendantPids(<int, int>{101: 100}, 100), <int>[101]);
    });

    test('no process information gives no targets', () {
      expect(leafDescendantPids(<int, int>{}, 100), isEmpty);
      expect(descendantPids(<int, int>{5: 6, 6: 5}, 1), isEmpty);
    });
  });
}
