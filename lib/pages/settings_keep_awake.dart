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
          title: Text(t('保持屏幕常亮', 'Keep the screen on')),
          subtitle: Text(
            t(
              '有脚本运行或终端开着时不熄屏（仅应用在前台时有效）',
              'While a script runs or a terminal is open (app in the foreground)',
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
          title: Text(t('终端后台保活', 'Keep terminals alive')),
          subtitle: Text(
            t(
              '终端开着时用前台服务和唤醒锁，切后台、息屏也继续运行',
              'A foreground service and wake lock keep open terminals running in the background',
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
