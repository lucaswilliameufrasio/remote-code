import 'dart:typed_data';
import 'package:file_picker_platform_interface/file_picker_platform_interface.dart';
import '../core/attachments.dart';

abstract interface class AttachmentPicker {
  Future<PromptAttachment?> pick();
}

class PlatformAttachmentPicker implements AttachmentPicker {
  const PlatformAttachmentPicker();

  @override
  Future<PromptAttachment?> pick() async {
    final file = await FilePickerPlatform.instance.pickFile(
      type: FileType.custom,
      allowedExtensions: [
        'png',
        'jpg',
        'jpeg',
        'gif',
        'webp',
        'pdf',
        'txt',
        'md',
        'csv',
        'json',
        'yaml',
        'yml',
        'log',
        'xml',
        'html',
      ],
    );
    if (file == null) {
      return null;
    }
    final knownLength = file.lengthSync();
    if (knownLength != null && knownLength > PromptAttachment.maxBytes) {
      throw const AttachmentException(
          'O limite de anexos é 5 MiB por mensagem.');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in file.readAsByteStream()) {
      if (bytes.length + chunk.length > PromptAttachment.maxBytes) {
        throw const AttachmentException(
            'O limite de anexos é 5 MiB por mensagem.');
      }
      bytes.add(chunk);
    }
    return PromptAttachment.fromBytes(file.name, bytes.takeBytes());
  }
}
