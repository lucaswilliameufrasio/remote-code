class FileChange {
  final String file, patch, status;
  final int additions, deletions;

  const FileChange(
      {required this.file,
      required this.patch,
      required this.status,
      required this.additions,
      required this.deletions});
}
