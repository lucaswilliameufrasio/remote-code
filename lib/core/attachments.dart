import 'dart:convert';
import 'dart:typed_data';
import 'models.dart';

class AttachmentException implements Exception {
  final String message;
  const AttachmentException(this.message);
  @override
  String toString() => message;
}

class PromptAttachment {
  static const int maxBytes = 5 * 1024 * 1024;
  static const int maxCount = 4;
  final String name, mime;
  final Uint8List bytes;

  PromptAttachment._(this.name, this.mime, this.bytes);

  factory PromptAttachment.fromBytes(String name, Uint8List bytes) {
    if (bytes.isEmpty) {
      throw const AttachmentException('O arquivo está vazio.');
    }
    if (bytes.length > maxBytes) {
      throw const AttachmentException(
          'O limite de anexos é 5 MiB por mensagem.');
    }
    final mime = _detectMime(bytes);
    if (mime == null) {
      throw const AttachmentException(
        'Formato não suportado. Escolha PNG, JPEG, GIF, WebP, PDF ou texto UTF-8. Áudio e vídeo ainda não são aceitos.',
      );
    }
    return PromptAttachment._(
      name,
      mime,
      Uint8List.fromList(bytes).asUnmodifiableView(),
    );
  }

  String get modality => mime == 'application/pdf'
      ? 'pdf'
      : mime.startsWith('image/')
          ? 'image'
          : 'text';

  Json toJson() => {
        'uri': 'data:$mime;base64,${base64Encode(bytes)}',
        'name': name,
      };

  static void validateBatch(List<PromptAttachment> attachments) {
    if (attachments.length > maxCount) {
      throw const AttachmentException(
          'Anexe no máximo 4 arquivos por mensagem.');
    }
    var totalBytes = 0;
    for (final attachment in attachments) {
      totalBytes += attachment.bytes.length;
    }
    if (totalBytes > maxBytes) {
      throw const AttachmentException(
          'O limite total dos anexos é 5 MiB por mensagem.');
    }
  }

  static void validateModel(List<PromptAttachment> attachments, Json model) {
    final supportedInputs = object(model['capabilities'])['input'];
    for (final attachment in attachments) {
      if (attachment.modality == 'text') {
        continue;
      }
      if (supportedInputs is! List ||
          !supportedInputs.whereType<String>().any((input) =>
              input == attachment.modality ||
              input.startsWith('${attachment.modality}/'))) {
        throw AttachmentException(
          'O modelo atual não informa suporte a ${attachment.modality == 'pdf' ? 'PDF' : 'imagens'}. Escolha um modelo compatível ou remova o anexo.',
        );
      }
    }
  }
}

String? _detectMime(Uint8List bytes) {
  bool startsWith(List<int> signature, [int offset = 0]) {
    if (bytes.length < offset + signature.length) {
      return false;
    }
    for (var index = 0; index < signature.length; index++) {
      if (bytes[offset + index] != signature[index]) {
        return false;
      }
    }
    return true;
  }

  if (startsWith([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) {
    return 'image/png';
  }
  if (startsWith([0xff, 0xd8, 0xff])) {
    return 'image/jpeg';
  }
  if (startsWith(ascii.encode('GIF87a')) ||
      startsWith(ascii.encode('GIF89a'))) {
    return 'image/gif';
  }
  if (startsWith(ascii.encode('RIFF')) && startsWith(ascii.encode('WEBP'), 8)) {
    return 'image/webp';
  }
  if (startsWith(ascii.encode('%PDF-'))) {
    return 'application/pdf';
  }
  if (bytes.contains(0)) {
    return null;
  }
  try {
    utf8.decode(bytes, allowMalformed: false);
  } on FormatException {
    return null;
  }
  var controlBytes = 0;
  for (final byte in bytes) {
    if (byte < 9 || (byte > 13 && byte < 32)) {
      controlBytes++;
    }
  }
  return controlBytes / bytes.length <= .3 ? 'text/plain' : null;
}
