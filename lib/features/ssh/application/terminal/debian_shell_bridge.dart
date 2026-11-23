import 'package:flutter/services.dart';

import 'debian_shell_support.dart';

/// The native calls behind the Debian terminal and the Debian runtime settings.
class DebianShellBridge {
  const DebianShellBridge();

  static const MethodChannel _channel = MethodChannel(
    'com.daozhang.py/native_bridge',
  );

  /// Builds the proot command line and environment of a new interactive shell.
  Future<DebianShellLaunch> prepare({String? workingDir}) async {
    final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
      'prepareLinuxLikeShell',
      <String, Object?>{'workingDir': workingDir},
    );
    if (raw == null) {
      throw StateError('The native side returned no launch description');
    }
    return DebianShellLaunch.fromMap(raw);
  }

  /// Gives the shell's temporary proot directory back; never throws.
  Future<void> release(String tempDir) async {
    if (tempDir.isEmpty) return;
    try {
      await _channel.invokeMethod<Object?>(
        'releaseLinuxLikeShell',
        <String, Object?>{'tempDir': tempDir},
      );
    } catch (_) {
      // The directory is pruned on the next run anyway.
    }
  }

  /// Everything the runtime reports about itself (paths, compat mode, self-check probes).
  Future<Map<String, String>> runtimeInfo() async {
    final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
      'getLinuxLikeRuntimeInfo',
    );
    final info = <String, String>{};
    raw?.forEach((key, value) {
      if (key != null) info[key.toString()] = value?.toString() ?? '';
    });
    return info;
  }
}
