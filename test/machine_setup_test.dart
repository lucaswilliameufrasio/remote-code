import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_dev/core/models.dart';
import 'package:remote_dev/core/store.dart';
import 'package:remote_dev/features/home.dart';
import 'package:remote_dev/features/machine_setup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'Should open the selected agent guide and preserve the machine form',
      (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    final store = AppStore();
    await store.load();
    await tester.pumpWidget(MaterialApp(home: MachineEditor(store: store)));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Nome da máquina'), 'My computer');
    await tester.tap(find.text('Como configurar no computador'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<MachineSetupScreen>(find.byType(MachineSetupScreen))
            .backend,
        AgentBackend.openCode);
    expect(find.text('Configurar no computador'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('My computer'), findsOneWidget);
    await tester
        .ensureVisible(find.byType(DropdownButtonFormField<AgentBackend>));
    await tester.tap(find.byType(DropdownButtonFormField<AgentBackend>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Claude Code').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Como configurar no computador'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<MachineSetupScreen>(find.byType(MachineSetupScreen))
            .backend,
        AgentBackend.claudeCode);
    expect(find.text('1. Preparar o adaptador Claude Code'), findsOneWidget);
    expect(store.machines, isEmpty);
  });

  testWidgets(
      'Should copy only the public OpenCode command without form credentials',
      (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        final arguments = Map<String, dynamic>.from(call.arguments as Map);
        copied = arguments['text'] as String;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(const MaterialApp(
        home: MachineSetupScreen(backend: AgentBackend.openCode)));
    final copyButton =
        find.byTooltip('Copiar: Iniciar OpenCode · Bash/Zsh').hitTestable();
    await tester.scrollUntilVisible(copyButton, 250,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(copyButton);
    await tester.pumpAndSettle();
    expect(copied, contains('read -r -s OPENCODE_SERVER_PASSWORD'));
    expect(copied, contains('opencode serve --hostname 127.0.0.1 --port 4096'));
    expect(copied, isNot(contains('funnel')));
    expect(
        find.text('Comando copiado. Execute no computador.'), findsOneWidget);
  });

  testWidgets(
      'Should show Claude setup commands and private routing on a narrow screen',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(
        home: MachineSetupScreen(backend: AgentBackend.claudeCode)));
    final setup = find.text('make setup-claude');
    await tester.scrollUntilVisible(setup, 250,
        scrollable: find.byType(Scrollable).first);
    expect(setup, findsOneWidget);
    final start = find.byTooltip('Copiar: Iniciar adaptador Claude · Bash/Zsh');
    await tester.scrollUntilVisible(start, 250,
        scrollable: find.byType(Scrollable).first);
    expect(start, findsOneWidget);
    final route =
        find.text('tailscale serve --bg --https=8443 http://127.0.0.1:4097');
    await tester.scrollUntilVisible(route, 250,
        scrollable: find.byType(Scrollable).first);
    expect(route, findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
