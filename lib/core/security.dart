import 'dart:convert';
import 'dart:math';

import 'package:bip39/bip39.dart' as bip39;
import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

abstract interface class DeviceAuthenticator {
  Future<List<BiometricType>> availableBiometrics();
  Future<bool> authenticate();
}

final class LocalDeviceAuthenticator implements DeviceAuthenticator {
  final LocalAuthentication _authentication;

  LocalDeviceAuthenticator({LocalAuthentication? authentication})
      : _authentication = authentication ?? LocalAuthentication();

  @override
  Future<List<BiometricType>> availableBiometrics() async {
    try {
      final isSupported = await _authentication.isDeviceSupported();
      if (!isSupported) {
        return const [];
      }
      return await _authentication.getAvailableBiometrics();
    } on PlatformException {
      return const [];
    } on MissingPluginException {
      return const [];
    }
  }

  @override
  Future<bool> authenticate() async {
    try {
      return await _authentication.authenticate(
        localizedReason: 'Desbloqueie o Remoto para continuar.',
        options: const AuthenticationOptions(
          biometricOnly: false,
          stickyAuth: true,
        ),
      );
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}

final class AppSecurity {
  static const storageKey = 'remote_dev_security_v1';
  static const minimumPasswordLength = 8;
  static const _schemaVersion = 1;
  static const _passwordIterations = 600000;

  static final Pbkdf2 _passwordHasher = Pbkdf2.hmacSha256(
    iterations: _passwordIterations,
    bits: 256,
  );
  static final Sha256 _recoveryHasher = Sha256();

  final FlutterSecureStorage storage;
  final DeviceAuthenticator authenticator;
  final Random _secureRandom = Random.secure();

  bool onboardingComplete = false;
  bool biometricEnabled = false;
  String? error;
  String? _passwordSalt;
  String? _passwordHash;
  String? _recoverySalt;
  String? _recoveryHash;

  AppSecurity({
    required this.storage,
    DeviceAuthenticator? authenticator,
  }) : authenticator = authenticator ?? LocalDeviceAuthenticator();

  bool get hasPassword => _passwordSalt != null && _passwordHash != null;

  bool get requiresUnlock => hasPassword || biometricEnabled;

  static String? passwordValidationMessage(String password) {
    if (password.length < minimumPasswordLength) {
      return 'Use pelo menos $minimumPasswordLength caracteres.';
    }
    if (password.length > 128) {
      return 'A senha pode ter no máximo 128 caracteres.';
    }
    return null;
  }

  static String normalizeRecoveryPhrase(String phrase) {
    return phrase
        .trim()
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .join(' ');
  }

  Future<void> load() async {
    onboardingComplete = false;
    biometricEnabled = false;
    error = null;
    _passwordSalt = null;
    _passwordHash = null;
    _recoverySalt = null;
    _recoveryHash = null;

    try {
      final raw = await storage.read(key: storageKey);
      if (raw == null) {
        return;
      }

      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        throw const FormatException('Invalid security settings.');
      }
      final settings = Map<String, dynamic>.from(decoded);
      if (settings['schemaVersion'] != _schemaVersion) {
        throw const FormatException('Unsupported security settings.');
      }

      final loadedOnboardingComplete = settings['onboardingComplete'];
      final loadedBiometricEnabled = settings['biometricEnabled'];
      if (loadedOnboardingComplete is! bool ||
          loadedBiometricEnabled is! bool) {
        throw const FormatException('Invalid security flags.');
      }

      final passwordSalt = _validatedEncodedValue(settings['passwordSalt'], 16);
      final passwordHash = _validatedEncodedValue(settings['passwordHash'], 32);
      final recoverySalt = _validatedEncodedValue(settings['recoverySalt'], 16);
      final recoveryHash = _validatedEncodedValue(settings['recoveryHash'], 32);

      if ((passwordSalt == null) != (passwordHash == null) ||
          (recoverySalt == null) != (recoveryHash == null) ||
          (passwordSalt == null) != (recoverySalt == null) ||
          (loadedBiometricEnabled && !loadedOnboardingComplete) ||
          (!loadedOnboardingComplete && passwordSalt != null)) {
        throw const FormatException('Inconsistent security settings.');
      }

      onboardingComplete = loadedOnboardingComplete;
      biometricEnabled = loadedBiometricEnabled;
      _passwordSalt = passwordSalt;
      _passwordHash = passwordHash;
      _recoverySalt = recoverySalt;
      _recoveryHash = recoveryHash;
    } on Object {
      error =
          'Não foi possível validar a proteção local. Os dados foram preservados e o app foi bloqueado para evitar acesso sem verificação.';
    }
  }

  Future<String> createRecoveryPhrase() async {
    return bip39.generateMnemonic(strength: 128);
  }

  Future<bool> hasEnrolledBiometrics() async {
    final biometrics = await authenticator.availableBiometrics();
    return biometrics.isNotEmpty;
  }

  Future<bool> unlockWithBiometrics() {
    return authenticator.authenticate();
  }

  Future<void> completeWithoutProtection() async {
    await _persist(
      onboardingComplete: true,
      biometricEnabled: false,
      passwordSalt: null,
      passwordHash: null,
      recoverySalt: null,
      recoveryHash: null,
    );
  }

  Future<void> saveProtection({
    String? password,
    String? recoveryPhrase,
    required bool enableBiometrics,
  }) async {
    if (password != null && passwordValidationMessage(password) != null) {
      throw const FormatException('A senha não atende aos requisitos.');
    }
    if ((password == null) != (recoveryPhrase == null)) {
      throw const FormatException(
          'Senha e recuperação precisam ser definidas juntas.');
    }
    if (enableBiometrics && !await hasEnrolledBiometrics()) {
      throw StateError('Nenhuma biometria está cadastrada neste dispositivo.');
    }

    String? passwordSalt;
    String? passwordHash;
    String? recoverySalt;
    String? recoveryHash;

    if (password != null && recoveryPhrase != null) {
      final normalizedPhrase = normalizeRecoveryPhrase(recoveryPhrase);
      if (!bip39.validateMnemonic(normalizedPhrase)) {
        throw const FormatException('A frase de recuperação não é válida.');
      }

      final generatedPasswordSalt = _randomBytes(16);
      final generatedRecoverySalt = _randomBytes(16);
      final derivedPasswordHash = await _derivePasswordHash(
        password,
        generatedPasswordSalt,
      );
      final derivedRecoveryHash = await _deriveRecoveryHash(
        normalizedPhrase,
        generatedRecoverySalt,
      );

      passwordSalt = base64Encode(generatedPasswordSalt);
      passwordHash = base64Encode(derivedPasswordHash);
      recoverySalt = base64Encode(generatedRecoverySalt);
      recoveryHash = base64Encode(derivedRecoveryHash);
    }

    await _persist(
      onboardingComplete: true,
      biometricEnabled: enableBiometrics,
      passwordSalt: passwordSalt,
      passwordHash: passwordHash,
      recoverySalt: recoverySalt,
      recoveryHash: recoveryHash,
    );
  }

  Future<bool> verifyPassword(String password) async {
    final saltValue = _passwordSalt;
    final hashValue = _passwordHash;
    if (saltValue == null || hashValue == null || password.length > 128) {
      return false;
    }

    final candidateHash = await _derivePasswordHash(
      password,
      base64Decode(saltValue),
    );
    return _matches(candidateHash, base64Decode(hashValue));
  }

  Future<bool> verifyRecoveryPhrase(String phrase) async {
    final saltValue = _recoverySalt;
    final hashValue = _recoveryHash;
    final normalizedPhrase = normalizeRecoveryPhrase(phrase);
    if (saltValue == null ||
        hashValue == null ||
        !bip39.validateMnemonic(normalizedPhrase)) {
      return false;
    }

    final candidateHash = await _deriveRecoveryHash(
      normalizedPhrase,
      base64Decode(saltValue),
    );
    return _matches(candidateHash, base64Decode(hashValue));
  }

  Future<bool> recoverPassword({
    required String recoveryPhrase,
    required String newPassword,
  }) async {
    if (passwordValidationMessage(newPassword) != null ||
        !await verifyRecoveryPhrase(recoveryPhrase)) {
      return false;
    }

    final recoverySalt = _recoverySalt;
    final recoveryHash = _recoveryHash;
    if (recoverySalt == null || recoveryHash == null) {
      return false;
    }

    final newPasswordSalt = _randomBytes(16);
    final newPasswordHash = await _derivePasswordHash(
      newPassword,
      newPasswordSalt,
    );
    await _persist(
      onboardingComplete: true,
      biometricEnabled: biometricEnabled,
      passwordSalt: base64Encode(newPasswordSalt),
      passwordHash: base64Encode(newPasswordHash),
      recoverySalt: recoverySalt,
      recoveryHash: recoveryHash,
    );
    return true;
  }

  Future<void> _persist({
    required bool onboardingComplete,
    required bool biometricEnabled,
    required String? passwordSalt,
    required String? passwordHash,
    required String? recoverySalt,
    required String? recoveryHash,
  }) async {
    final value = jsonEncode({
      'schemaVersion': _schemaVersion,
      'onboardingComplete': onboardingComplete,
      'biometricEnabled': biometricEnabled,
      'passwordSalt': passwordSalt,
      'passwordHash': passwordHash,
      'recoverySalt': recoverySalt,
      'recoveryHash': recoveryHash,
    });
    await storage.write(key: storageKey, value: value);

    this.onboardingComplete = onboardingComplete;
    this.biometricEnabled = biometricEnabled;
    _passwordSalt = passwordSalt;
    _passwordHash = passwordHash;
    _recoverySalt = recoverySalt;
    _recoveryHash = recoveryHash;
    error = null;
  }

  Future<List<int>> _derivePasswordHash(String password, List<int> salt) async {
    final derivedKey = await _passwordHasher.deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: salt,
    );
    return derivedKey.extractBytes();
  }

  Future<List<int>> _deriveRecoveryHash(String phrase, List<int> salt) async {
    final digest = await _recoveryHasher.hash([
      ...salt,
      ...utf8.encode('remoto-recovery-v1:$phrase'),
    ]);
    return digest.bytes;
  }

  List<int> _randomBytes(int length) {
    return List<int>.generate(length, (_) => _secureRandom.nextInt(256));
  }

  String? _validatedEncodedValue(dynamic value, int expectedLength) {
    if (value == null) {
      return null;
    }
    if (value is! String) {
      throw const FormatException('Invalid encoded security value.');
    }
    final decoded = base64Decode(value);
    if (decoded.length != expectedLength) {
      throw const FormatException('Invalid encoded security length.');
    }
    return value;
  }

  bool _matches(List<int> candidate, List<int> expected) {
    if (candidate.length != expected.length) {
      return false;
    }

    var difference = 0;
    for (var index = 0; index < candidate.length; index++) {
      difference |= candidate[index] ^ expected[index];
    }
    return difference == 0;
  }
}
