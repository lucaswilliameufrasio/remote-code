import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:local_auth/local_auth.dart' show BiometricType;
import 'package:remote_dev/core/security.dart';
import 'package:remote_dev/core/models.dart';
import 'package:remote_dev/core/store.dart';
import 'package:remote_dev/main.dart';
import 'package:remote_dev/features/machine_setup.dart';

class _NoBiometrics implements DeviceAuthenticator {
  @override
  Future<List<BiometricType>> availableBiometrics() async => const [];

  @override
  Future<bool> authenticate() async => false;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Should finish onboarding and show the workspace on iOS',
      (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    const storage = FlutterSecureStorage();
    final store = AppStore(
      storage: storage,
      security: AppSecurity(
        storage: storage,
        authenticator: _NoBiometrics(),
      ),
    );
    await store.load();

    await tester.pumpWidget(RemoteDevApp(store: store));
    await tester.pumpAndSettle();
    expect(find.text('Seu trabalho,\nsempre por perto.'), findsOneWidget);

    await tester.tap(find.text('Começar'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continuar sem proteção'));
    await tester.pumpAndSettle();

    expect(store.security.onboardingComplete, isTrue);
    expect(find.text('Seu trabalho,\nsem interrupções.'), findsOneWidget);
    await tester.tap(find.text('Máquinas').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Conectar máquina'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Como configurar no computador'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<MachineSetupScreen>(find.byType(MachineSetupScreen))
            .backend,
        AgentBackend.openCode);
    await tester.pageBack();
    await tester.pumpAndSettle();
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
}
