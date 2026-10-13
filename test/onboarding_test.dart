import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart' show BiometricType;
import 'package:remote_dev/core/security.dart';
import 'package:remote_dev/core/store.dart';
import 'package:remote_dev/main.dart';

class _FakeBiometrics implements DeviceAuthenticator {
  final bool isAvailable;
  final bool authenticationResult;

  const _FakeBiometrics({
    this.isAvailable = false,
    this.authenticationResult = false,
  });

  @override
  Future<List<BiometricType>> availableBiometrics() async {
    return isAvailable ? const [BiometricType.face] : const [];
  }

  @override
  Future<bool> authenticate() async => authenticationResult;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  AppStore createStore({
    bool biometricAvailable = false,
    bool authenticationResult = false,
  }) {
    const storage = FlutterSecureStorage();
    return AppStore(
      storage: storage,
      security: AppSecurity(
        storage: storage,
        authenticator: _FakeBiometrics(
          isAvailable: biometricAvailable,
          authenticationResult: authenticationResult,
        ),
      ),
    );
  }

  testWidgets('Should complete onboarding without enabling protection',
      (tester) async {
    final store = createStore();
    await store.load();

    await tester.pumpWidget(RemoteDevApp(store: store));
    await tester.pumpAndSettle();

    expect(find.text('Seu trabalho,\nsempre por perto.'), findsOneWidget);
    expect(find.text('Começar'), findsOneWidget);

    await tester.ensureVisible(find.text('Começar'));
    await tester.tap(find.text('Começar'));
    await tester.pumpAndSettle();
    expect(find.text('Como você quer proteger o app?'), findsOneWidget);

    await tester.ensureVisible(find.text('Continuar sem proteção'));
    await tester.tap(find.text('Continuar sem proteção'));
    await tester.pumpAndSettle();

    expect(store.security.onboardingComplete, isTrue);
    expect(store.security.requiresUnlock, isFalse);
    expect(find.text('Seu trabalho,\nsem interrupções.'), findsOneWidget);
  });

  testWidgets('Should require a valid matching password before recovery setup',
      (tester) async {
    final store = createStore();
    await store.load();

    await tester.pumpWidget(RemoteDevApp(store: store));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Começar'));
    await tester.tap(find.text('Começar'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(SwitchListTile).first);
    await tester.tap(find.byType(SwitchListTile).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continuar com senha'));
    await tester.pumpAndSettle();

    await tester.enterText(find.bySemanticsLabel('Senha'), 'short');
    await tester.enterText(find.bySemanticsLabel('Confirme a senha'), 'short');
    await tester.tap(find.text('Gerar frase de recuperação'));
    await tester.pumpAndSettle();

    expect(find.text('Use pelo menos 8 caracteres.'), findsOneWidget);
    expect(store.security.requiresUnlock, isFalse);
  });

  testWidgets('Should lock the app on background and unlock with biometrics',
      (tester) async {
    final store = createStore(
      biometricAvailable: true,
      authenticationResult: true,
    );
    await store.load();

    await tester.pumpWidget(RemoteDevApp(store: store));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Começar'));
    await tester.tap(find.text('Começar'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(SwitchListTile).last);
    await tester.tap(find.byType(SwitchListTile).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ativar biometria'));
    await tester.pumpAndSettle();

    expect(store.security.biometricEnabled, isTrue);
    expect(find.text('Seu trabalho,\nsem interrupções.'), findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpAndSettle();
    expect(find.text('Desbloquear Remoto'), findsOneWidget);

    await tester.tap(find.text('Usar biometria ou código do dispositivo'));
    await tester.pumpAndSettle();

    expect(find.text('Desbloquear Remoto'), findsNothing);
    expect(find.text('Seu trabalho,\nsem interrupções.'), findsOneWidget);
  });

  testWidgets('Should reset a forgotten password with the recovery phrase',
      (tester) async {
    final store = createStore();
    await store.load();
    final recoveryPhrase = await store.security.createRecoveryPhrase();
    await tester.runAsync(() async {
      await store.security.saveProtection(
        password: 'original test password',
        recoveryPhrase: recoveryPhrase,
        enableBiometrics: false,
      );
    });

    await tester.pumpWidget(RemoteDevApp(store: store));
    await tester.pumpAndSettle();
    expect(find.text('Desbloquear Remoto'), findsOneWidget);

    await tester.ensureVisible(find.text('Esqueci minha senha'));
    await tester.tap(find.text('Esqueci minha senha'));
    await tester.pumpAndSettle();
    expect(find.text('Recuperar acesso'), findsOneWidget);
    await tester.ensureVisible(find.byType(TextField).first);
    await tester.enterText(find.byType(TextField).first, recoveryPhrase);
    await tester.tap(find.text('Validar frase'));
    await tester.pumpAndSettle();

    expect(find.text('Definir uma nova senha'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'new test password');
    await tester.enterText(find.byType(TextField).last, 'new test password');
    await tester.ensureVisible(find.text('Redefinir senha e desbloquear'));
    await tester.tap(find.text('Redefinir senha e desbloquear'));
    await tester.pumpAndSettle();

    expect(find.text('Seu trabalho,\nsem interrupções.'), findsOneWidget);
  });
}
