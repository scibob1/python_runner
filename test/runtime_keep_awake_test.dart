import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:python_runner/services/runtime_keep_awake.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeNative implements KeepAwakeNative {
  final List<bool> screen = <bool>[];
  final List<bool> service = <bool>[];

  @override
  Future<void> setKeepScreenOn(bool enabled) async => screen.add(enabled);

  @override
  Future<void> setTerminalKeepAlive(bool enabled) async => service.add(enabled);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('policy', () {
    test('the screen stays on only while something runs and the switch is on', () {
      bool on({bool enabled = true, bool script = false, bool terminal = false}) =>
          screenShouldStayOn(
            enabled: enabled,
            scriptRunning: script,
            terminalOpen: terminal,
          );
      expect(on(), isFalse);
      expect(on(script: true), isTrue);
      expect(on(terminal: true), isTrue);
      expect(on(enabled: false, script: true, terminal: true), isFalse);
    });

    test('the terminal service needs an open terminal and the switch', () {
      expect(terminalServiceWanted(enabled: true, terminalOpen: true), isTrue);
      expect(terminalServiceWanted(enabled: true, terminalOpen: false), isFalse);
      expect(terminalServiceWanted(enabled: false, terminalOpen: true), isFalse);
    });
  });

  group('RuntimeKeepAwake', () {
    late ValueNotifier<int> changes;
    late _FakeNative native;
    var script = false;
    var terminal = false;

    RuntimeKeepAwake build() => RuntimeKeepAwake(
          sources: changes,
          scriptRunning: () => script,
          terminalOpen: () => terminal,
          native: native,
        );

    void changed() => changes.value++;

    setUp(() {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      changes = ValueNotifier<int>(0);
      native = _FakeNative();
      script = false;
      terminal = false;
    });

    test('follows scripts and terminals and only calls native on a change',
        () async {
      final keepAwake = build();
      await keepAwake.start();
      expect(native.screen, isEmpty);

      script = true;
      changed();
      changed();
      expect(native.screen, <bool>[true]);

      terminal = true;
      changed();
      expect(native.service, <bool>[true]);
      expect(native.screen, <bool>[true]);

      script = false;
      changed();
      expect(native.screen, <bool>[true]); // the terminal still keeps it on

      terminal = false;
      changed();
      expect(native.screen, <bool>[true, false]);
      expect(native.service, <bool>[true, false]);
      keepAwake.dispose();
    });

    test('both switches are on by default and can be turned off', () async {
      terminal = true;
      final keepAwake = build();
      await keepAwake.start();
      expect(keepAwake.screenOn, isTrue);
      expect(keepAwake.serviceOn, isTrue);

      SharedPreferences.setMockInitialValues(<String, Object>{
        RuntimeKeepAwake.screenOnKey: false,
        RuntimeKeepAwake.terminalKeepAliveKey: false,
      });
      await keepAwake.reload();
      expect(keepAwake.screenOn, isFalse);
      expect(keepAwake.serviceOn, isFalse);
      expect(native.screen, <bool>[true, false]);
      expect(native.service, <bool>[true, false]);
      keepAwake.dispose();
    });

    test('a stored switch is honoured at start', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        RuntimeKeepAwake.screenOnKey: false,
      });
      script = true;
      terminal = true;
      final keepAwake = build();
      await keepAwake.start();
      expect(keepAwake.screenOn, isFalse);
      expect(keepAwake.serviceOn, isTrue);
      keepAwake.dispose();
    });

    test('a missing native side is not an error', () async {
      script = true;
      final keepAwake = RuntimeKeepAwake(
        sources: changes,
        scriptRunning: () => script,
        terminalOpen: () => terminal,
      );
      await keepAwake.start();
      expect(keepAwake.screenOn, isTrue);
      keepAwake.dispose();
    });
  });
}
