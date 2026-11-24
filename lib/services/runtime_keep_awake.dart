import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The screen stays on while the app is open and something is running: a script,
/// or a terminal that is alive. Android only honours this while the app is on screen.
bool screenShouldStayOn({
  required bool enabled,
  required bool scriptRunning,
  required bool terminalOpen,
}) => enabled && (scriptRunning || terminalOpen);

/// A terminal that is open keeps the app's foreground service (with its wake lock) alive,
/// so the system does not freeze the shell or its children when the app is in the
/// background or the screen is off.
bool terminalServiceWanted({
  required bool enabled,
  required bool terminalOpen,
}) => enabled && terminalOpen;

/// The two native switches behind the keep-awake settings.
abstract class KeepAwakeNative {
  Future<void> setKeepScreenOn(bool enabled);

  Future<void> setTerminalKeepAlive(bool enabled);
}

class MethodChannelKeepAwake implements KeepAwakeNative {
  const MethodChannelKeepAwake();

  static const MethodChannel _channel = MethodChannel(
    'com.daozhang.py/native_bridge',
  );

  @override
  Future<void> setKeepScreenOn(bool enabled) async {
    await _channel.invokeMethod<Object?>(
      'setKeepScreenOn',
      <String, Object?>{'enabled': enabled},
    );
  }

  @override
  Future<void> setTerminalKeepAlive(bool enabled) async {
    await _channel.invokeMethod<Object?>(
      'setTerminalKeepAlive',
      <String, Object?>{'enabled': enabled},
    );
  }
}

/// Keeps the screen on and the terminals alive while the app works, following what
/// runs ([sources] notify when scripts or terminals change) and two settings.
class RuntimeKeepAwake {
  RuntimeKeepAwake({
    required Listenable sources,
    required bool Function() scriptRunning,
    required bool Function() terminalOpen,
    KeepAwakeNative native = const MethodChannelKeepAwake(),
  }) : _sources = sources,
       _scriptRunning = scriptRunning,
       _terminalOpen = terminalOpen,
       _native = native;

  static const String screenOnKey = 'keep_screen_on';
  static const String terminalKeepAliveKey = 'terminal_keep_alive';

  /// The running instance, so the settings page can tell it that a switch changed.
  static RuntimeKeepAwake? current;

  final Listenable _sources;
  final bool Function() _scriptRunning;
  final bool Function() _terminalOpen;
  final KeepAwakeNative _native;

  bool _screenEnabled = true;
  bool _terminalEnabled = true;
  bool _screenOn = false;
  bool _serviceOn = false;
  bool _started = false;

  bool get screenOn => _screenOn;

  bool get serviceOn => _serviceOn;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    current = this;
    await reload();
    _sources.addListener(apply);
  }

  void dispose() {
    _sources.removeListener(apply);
    if (identical(current, this)) current = null;
  }

  /// Reads the two settings again (both default to on) and applies them.
  Future<void> reload() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _screenEnabled = prefs.getBool(screenOnKey) ?? true;
      _terminalEnabled = prefs.getBool(terminalKeepAliveKey) ?? true;
    } catch (_) {
      // Keep the defaults (on).
    }
    apply();
  }

  void apply() {
    final terminalOpen = _terminalOpen();
    final screen = screenShouldStayOn(
      enabled: _screenEnabled,
      scriptRunning: _scriptRunning(),
      terminalOpen: terminalOpen,
    );
    final service = terminalServiceWanted(
      enabled: _terminalEnabled,
      terminalOpen: terminalOpen,
    );
    if (screen != _screenOn) {
      _screenOn = screen;
      unawaited(_guard(() => _native.setKeepScreenOn(screen)));
    }
    if (service != _serviceOn) {
      _serviceOn = service;
      unawaited(_guard(() => _native.setTerminalKeepAlive(service)));
    }
  }

  Future<void> _guard(Future<void> Function() call) async {
    try {
      await call();
    } catch (_) {
      // Without the native side (tests, hot restart) there is nothing to switch.
    }
  }
}
