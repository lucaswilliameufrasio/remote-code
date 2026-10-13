Future<String?> loadLocalPreviewPassword({
  required bool isIOS,
  required String? processPassword,
  required Future<String?> Function() readNativePassword,
}) async {
  if (processPassword != null && processPassword.isNotEmpty) {
    return processPassword;
  }
  if (!isIOS) {
    return null;
  }
  return readNativePassword();
}
