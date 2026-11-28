import 'package:flutter_test/flutter_test.dart';
import 'package:python_runner/features/mcp/application/mcp_confirmation_service.dart';
import 'package:python_runner/features/mcp/application/mcp_terminal_service.dart';
import 'package:python_runner/features/mcp/domain/mcp_error_codes.dart';
import 'package:python_runner/features/mcp/domain/mcp_permission.dart';
import 'package:python_runner/features/mcp/infrastructure/mcp_terminal_tools.dart';
import 'package:python_runner/features/ssh/application/terminal/session_manager.dart';
import 'package:python_runner/features/ssh/application/terminal/terminal_session.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/mcp_test_helper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  McpTerminalService newService() =>
      McpTerminalService(confirmations: McpConfirmationService());

  test('the terminal permission is off by default and counts as a write scope',
      () {
    expect(McpPermission.defaults, isNot(contains(McpPermission.terminal)));
    expect(McpPermission.terminal.isWriteScope, isTrue);
  });

  test('terminal tools are listed next to the regular ones and need the permission',
      () {
    final registry = McpTerminalToolRegistry(
      FakeMcpApplicationFacade(),
      terminal: newService(),
    );
    final names = registry.definitions.map((d) => d.name).toSet();
    expect(
      names,
      containsAll(<String>[
        'pyrunner_terminal_list',
        'pyrunner_terminal_open',
        'pyrunner_terminal_close',
        'pyrunner_terminal_send',
        'pyrunner_terminal_read',
        'pyrunner_terminal_wait_output',
        'pyrunner_terminal_interrupt',
        'pyrunner_terminal_tell_user',
        'pyrunner_terminal_wait_reply',
        'pyrunner_terminal_inbox',
        'pyrunner_script_list',
      ]),
    );
    final terminalTools = registry.definitions
        .where((d) => d.name.startsWith('pyrunner_terminal_'));
    expect(terminalTools, isNotEmpty);
    expect(
      terminalTools.every((d) => d.permission == McpPermission.terminal),
      isTrue,
    );
    expect(registry.find('pyrunner_terminal_send'), isNotNull);
    expect(registry.find('pyrunner_script_list'), isNotNull);
    expect(registry.find('pyrunner_nope'), isNull);
  });

  test('commands are not confirmed one by one unless the person turns it on',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final service = newService();
    await service.loadSettings();
    expect(service.confirmEach, isFalse);
  });

  test('a command with more than one line is refused before anything happens',
      () async {
    final service = newService();
    await expectLater(
      service.send(
        sessionId: 'local-1',
        command: 'ls\nrm -rf x',
        clientLabel: 'test',
      ),
      throwsA(isA<McpToolException>()),
    );
  });

  test('a message for the user is unread until the chat is opened', () {
    final service = newService();
    service.tellUser('Done with the install', 'test');
    expect(service.unreadCount, 1);
    service.markSeen();
    expect(service.unreadCount, 0);
  });

  test('the AI can wait for the answer to its message', () async {
    final service = newService();
    final id = service.tellUser('Shall I continue?', 'test')['message_id'] as int;

    final waiting = service.waitReply(messageId: id, timeoutSeconds: 5);
    service.userSay('yes');
    final result = await waiting;

    expect(result['replied'], isTrue);
    expect(result['reply'], 'yes');
  });

  test('unprompted messages from the user are handed over once', () async {
    final service = newService();
    service.userSay('hello');
    final first = await service.inbox();
    expect(first['messages'] as List<dynamic>, hasLength(1));

    final next = await service.inbox(afterId: first['next_after_id'] as int);
    expect(next['messages'] as List<dynamic>, isEmpty);
  });

  test('while paused the terminal tools are refused but the chat keeps working',
      () async {
    final service = newService();
    service.setPaused(true);
    expect(service.listSessions, throwsA(isA<McpToolException>()));
    service.userSay('please continue');
    final inbox = await service.inbox();
    expect(inbox['messages'] as List<dynamic>, hasLength(1));
    expect(inbox['paused'], isTrue);
  });

  test('a terminal or script that waits for the person is announced once',
      () {
    final service = newService();
    service.raiseAttention('terminal', 'local-1', 'Asks for a password');
    service.raiseAttention('terminal', 'local-1', 'Asks for a password');
    expect(service.attention, hasLength(1));
    expect(service.unreadCount, 1);

    service.raiseAttention('script', 'a.py', 'Waits for input');
    expect(service.attention, hasLength(2));

    service.clearAttentionKind('script');
    expect(service.attention.single.kind, 'terminal');
    service.clearAttention('terminal', 'local-1');
    expect(service.attention, isEmpty);
  });

  test('the open tool offers local and Debian shells, not SSH', () {
    final registry = McpTerminalToolRegistry(
      FakeMcpApplicationFacade(),
      terminal: newService(),
    );
    final schema = registry.find('pyrunner_terminal_open')!.definition.inputSchema;
    final properties = schema['properties'] as Map<String, dynamic>;
    final kind = properties['kind'] as Map<String, dynamic>;
    expect(kind['enum'], <String>['local', 'debian']);
    expect(schema['required'], isNull);
  });

  test('opening a session of another kind is refused', () async {
    final service = newService();
    await expectLater(
      service.openSession(kind: 'ssh'),
      throwsA(
        isA<McpToolException>()
            .having((e) => e.code, 'code', McpErrorCodes.invalidArgument),
      ),
    );
    expect(TerminalSessionManager.instance.sessions, isEmpty);
  });

  test('a Debian shell that cannot start is reported and not left behind',
      () async {
    final service = newService();
    // No native side in a unit test: preparing the shell fails.
    await expectLater(
      service.openSession(kind: 'debian'),
      throwsA(
        isA<McpToolException>()
            .having((e) => e.code, 'code', 'TERMINAL_START_FAILED'),
      ),
    );
    expect(TerminalSessionManager.instance.sessions, isEmpty);
  });

  test('every kind of session tells the AI where it runs', () {
    final manager = TerminalSessionManager.instance;
    final sessions = <TerminalSession>[
      manager.createLocal(),
      manager.createDebian(),
    ];
    addTearDown(() async {
      for (final session in sessions) {
        await manager.remove(session.id);
      }
    });
    final byKind = <String, String>{
      for (final session in sessions)
        session.kind: McpTerminalService.environmentOf(session),
    };
    expect(byKind['local'], contains('Android sh'));
    expect(byKind['local'], contains('cannot see files inside the Debian guest'));
    expect(byKind['debian'], contains('/python-runner/site-packages'));
  });

  test('notices from the app are not messages from the user', () async {
    final service = newService();
    service.raiseAttention('terminal', 'local-1', 'Asks for a password');
    final inbox = await service.inbox();
    expect(inbox['messages'] as List<dynamic>, isEmpty);
  });
}
