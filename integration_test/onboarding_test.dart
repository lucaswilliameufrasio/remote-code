import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:local_auth/local_auth.dart' show BiometricType;
import 'package:remote_dev/core/security.dart';
import 'package:remote_dev/core/store.dart';
import 'package:remote_dev/main.dart';

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
  });
}
