import 'dart:typed_data';
import 'package:file_picker_platform_interface/file_picker_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_dev/core/attachments.dart';
import 'package:remote_dev/features/attachment_picker.dart';

void main() {
  final originalPlatform = FilePickerPlatform.instance;
  tearDown(() => FilePickerPlatform.instance = originalPlatform);

  test('Should return no attachment when the native picker is cancelled',
      () async {
    FilePickerPlatform.instance = _PickerPlatform(null);
    expect(await const PlatformAttachmentPicker().pick(), isNull);
  });

  test('Should reject known oversized files before reading any bytes',
      () async {
    final file = _PickedFile(length: PromptAttachment.maxBytes + 1);
    FilePickerPlatform.instance = _PickerPlatform(file);
    await expectLater(const PlatformAttachmentPicker().pick(),
        throwsA(isA<AttachmentException>()));
    expect(file.readCalls, 0);
  });

  test('Should stop unknown-size streams when the byte limit is exceeded',
      () async {
    final file = _PickedFile(
        chunks: [Uint8List(PromptAttachment.maxBytes), Uint8List(1)]);
    FilePickerPlatform.instance = _PickerPlatform(file);
    await expectLater(const PlatformAttachmentPicker().pick(),
        throwsA(isA<AttachmentException>()));
  });

  test('Should read supported selected files without sending their local URI',
      () async {
    final file = _PickedFile(chunks: [
      Uint8List.fromList([72, 105])
    ]);
    FilePickerPlatform.instance = _PickerPlatform(file);
    final attachment = await const PlatformAttachmentPicker().pick();
    expect(attachment?.name, 'notes.txt');
    expect(attachment?.mime, 'text/plain');
    expect(attachment?.toJson()['uri'], 'data:text/plain;base64,SGk=');
  });
}

class _PickerPlatform extends FilePickerPlatform {
  final PlatformFile? file;
  _PickerPlatform(this.file);

  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    expect(type, FileType.custom);
    expect(allowedExtensions, containsAll(['png', 'pdf', 'txt']));
    expect(allowedExtensions, isNot(contains('mp4')));
    return file;
  }
}

final class _PickedFile extends PlatformFile {
  final int? knownLength;
  final List<Uint8List> chunks;
  int readCalls = 0;
  _PickedFile({int? length, this.chunks = const []}) : knownLength = length;
  @override
  String get name => 'notes.txt';
  @override
  Uri get uri => Uri.file('/private/notes.txt');
  @override
  Never get xFile => throw UnimplementedError();
  @override
  int? lengthSync() => knownLength;
  @override
  Future<int?> length() async => knownLength;
  @override
  Future<Uint8List> readAsBytes() async => throw UnimplementedError();
  @override
  Stream<Uint8List> readAsByteStream() async* {
    readCalls++;
    for (final chunk in chunks) {
      yield chunk;
    }
  }
}
