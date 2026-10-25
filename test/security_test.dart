import 'package:bip39/bip39.dart' as bip39;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart' show BiometricType;
import 'package:remote_dev/core/security.dart';

class _FakeDeviceAuthenticator implements DeviceAuthenticator {
  final bool hasBiometrics;
  final bool authenticationResult;
  int authenticationCount = 0;

  _FakeDeviceAuthenticator({
    this.hasBiometrics = false,
    this.authenticationResult = false,
  });

  @override
  Future<List<BiometricType>> availableBiometrics() async {
    return hasBiometrics ? const [BiometricType.face] : const [];
  }

  @override
  Future<bool> authenticate() async {
    authenticationCount += 1;
    return authenticationResult;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('App protection', () {
    test('Should store only salted verifiers and recover a forgotten password',
        () async {
      const storage = FlutterSecureStorage();
      final authenticator = _FakeDeviceAuthenticator(
        hasBiometrics: true,
        authenticationResult: true,
      );
      final security = AppSecurity(
        storage: storage,
        authenticator: authenticator,
      );
      await security.load();

      final recoveryPhrase = await security.createRecoveryPhrase();
      expect(recoveryPhrase.split(' ').length, 12);
      expect(bip39.validateMnemonic(recoveryPhrase), isTrue);

      await security.saveProtection(
        password: 'correct horse battery',
        recoveryPhrase: recoveryPhrase,
        enableBiometrics: true,
      );

      final storedSettings = await storage.read(key: AppSecurity.storageKey);
      expect(storedSettings, isNot(contains('correct horse battery')));
      expect(storedSettings, isNot(contains(recoveryPhrase)));

      final restoredSecurity = AppSecurity(
        storage: storage,
        authenticator: authenticator,
      );
      await restoredSecurity.load();
      expect(restoredSecurity.hasPassword, isTrue);
      expect(restoredSecurity.biometricEnabled, isTrue);
      expect(restoredSecurity.requiresUnlock, isTrue);
      expect(await restoredSecurity.unlockWithBiometrics(), isTrue);
      expect(await restoredSecurity.verifyPassword('correct horse battery'),
          isTrue);
      expect(
        await restoredSecurity.verifyRecoveryPhrase(
          '  ${recoveryPhrase.toUpperCase().replaceAll(' ', '   ')}  ',
        ),
        isTrue,
      );

      final wasRecovered = await restoredSecurity.recoverPassword(
        recoveryPhrase: recoveryPhrase,
        newPassword: 'another strong passphrase',
      );
      expect(wasRecovered, isTrue);
      expect(await restoredSecurity.verifyPassword('correct horse battery'),
          isFalse);
      expect(
        await restoredSecurity.verifyPassword('another strong passphrase'),
        isTrue,
      );
      // Exercises several real password/recovery KDF operations under coverage.
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('Should permit biometrics only when enrolled on the device', () async {
      const storage = FlutterSecureStorage();
      final authenticator = _FakeDeviceAuthenticator(
        hasBiometrics: true,
        authenticationResult: true,
      );
      final security = AppSecurity(
        storage: storage,
        authenticator: authenticator,
      );
      await security.load();

      await security.saveProtection(enableBiometrics: true);

      expect(security.hasPassword, isFalse);
      expect(security.biometricEnabled, isTrue);
      expect(await security.unlockWithBiometrics(), isTrue);
      expect(authenticator.authenticationCount, 1);
    });

    test('Should reject biometric setup without enrolled biometrics', () async {
      final security = AppSecurity(
        storage: const FlutterSecureStorage(),
        authenticator: _FakeDeviceAuthenticator(),
      );
      await security.load();

      await expectLater(
        security.saveProtection(enableBiometrics: true),
        throwsA(isA<StateError>()),
      );
      expect(security.onboardingComplete, isFalse);
    });

    test('Should block startup when saved protection metadata is malformed',
        () async {
      const storage = FlutterSecureStorage();
      await storage.write(
        key: AppSecurity.storageKey,
        value: '{"schemaVersion":1,"onboardingComplete":true,'
            '"biometricEnabled":false,"passwordSalt":"broken"}',
      );
      final security = AppSecurity(
        storage: storage,
        authenticator: _FakeDeviceAuthenticator(),
      );

      await security.load();

      expect(security.error, isNotNull);
      expect(security.onboardingComplete, isFalse);
      expect(security.requiresUnlock, isFalse);
    });

    test('Should validate password length before saving', () {
      expect(AppSecurity.passwordValidationMessage('short'), isNotNull);
      expect(AppSecurity.passwordValidationMessage('long enough'), isNull);
      expect(AppSecurity.passwordValidationMessage('a' * 129), isNotNull);
    });
  });
}
