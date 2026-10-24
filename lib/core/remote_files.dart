class RemoteFileEntry {
  final String path;
  final bool isDirectory;

  const RemoteFileEntry({required this.path, required this.isDirectory});

  String get name => path.split('/').last;
}

class RemoteFilePreview {
  final String text;
  final bool truncated;

  const RemoteFilePreview(this.text, {required this.truncated});
}

bool isProjectRelativePath(String path, {bool allowRoot = false}) {
  if (path.isEmpty) {
    return allowRoot;
  }
  if (path.startsWith('/') ||
      path.contains('\\') ||
      path.contains(':') ||
      path.contains('%') ||
      path.runes.any((character) => character < 32)) {
    return false;
  }
  return path.split('/').every(
      (segment) => segment.isNotEmpty && segment != '.' && segment != '..');
}
