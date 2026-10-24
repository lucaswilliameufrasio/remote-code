String pairingCodeFromQr(String value, String serverUrl) {
  final server = Uri.tryParse(serverUrl);
  final scanned = Uri.tryParse(value.trim());
  if (server == null ||
      scanned == null ||
      server.scheme != 'https' ||
      server.host.isEmpty ||
      scanned.scheme != 'https' ||
      scanned.origin != server.origin ||
      scanned.userInfo.isNotEmpty ||
      scanned.hasQuery ||
      scanned.hasFragment ||
      scanned.pathSegments.length != 3 ||
      scanned.pathSegments[0] != 'auth' ||
      scanned.pathSegments[1] != 'connect') {
    throw const FormatException(
        'O QR deve conter um link de pareamento HTTPS da máquina indicada.');
  }
  final code = scanned.pathSegments[2];
  if (code.isEmpty ||
      code.length > 256 ||
      code.contains(RegExp(r'[^A-Za-z0-9_-]'))) {
    throw const FormatException(
        'O QR não contém um código de pareamento válido.');
  }
  return code;
}
