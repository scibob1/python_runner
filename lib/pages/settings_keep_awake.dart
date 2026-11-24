part of 'settings_page.dart';

/// Keep the screen on and the terminals alive while something runs.
class _KeepAwakeCard extends StatefulWidget {
  const _KeepAwakeCard();

  @override
  State<_KeepAwakeCard> createState() => _KeepAwakeCardState();
}

class _KeepAwakeCardState extends State<_KeepAwakeCard> {
  bool _screenOn = true;
  bool _terminalKeepAlive = true;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _screenOn = prefs.getBool(RuntimeKeepAwake.screenOnKey) ?? true;
      _terminalKeepAlive =
          prefs.getBool(RuntimeKeepAwake.terminalKeepAliveKey) ?? true;
      _loaded = true;
    });
  }

  Future<void> _save(String key, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
    await RuntimeKeepAwake.current?.reload();
  }

  @override
  Widget build(BuildContext context) {
    final t = SshText.of(context);
    return _SectionCard(
      icon: Icons.light_mode_outlined,
      title: t('运行时保活', 'Keep running'),
      children: [
        SwitchListTile(
          title: Text(t('运行时保持屏幕常亮', 'Keep the screen on while running')),
          subtitle: Text(
            t(
              '有脚本在运行，或者有终端开着时，屏幕不自动熄灭。只在应用在前台时有效，息屏后系统更容易冻结后台进程。',
              'The screen does not turn off while a script runs or a terminal is open. Only while the app is on screen; with the screen off the system freezes background processes more readily.',
            ),
          ),
          value: _screenOn,
          onChanged: _loaded
              ? (value) {
                  setState(() => _screenOn = value);
                  unawaited(_save(RuntimeKeepAwake.screenOnKey, value));
                }
              : null,
        ),
        SwitchListTile(
          title: Text(t('终端后台保活', 'Keep terminals alive in the background')),
          subtitle: Text(
            t(
              '有终端开着时，用前台服务和唤醒锁让 shell 和里面运行的程序在后台、息屏时继续运行，通知栏会显示“终端运行中”。关闭所有终端后自动释放。',
              'While a terminal is open, a foreground service and a wake lock keep the shell and its programs running in the background and with the screen off; a "terminal running" notice shows. Released when the last terminal is closed.',
            ),
          ),
          value: _terminalKeepAlive,
          onChanged: _loaded
              ? (value) {
                  setState(() => _terminalKeepAlive = value);
                  unawaited(_save(RuntimeKeepAwake.terminalKeepAliveKey, value));
                }
              : null,
        ),
      ],
    );
  }
}
