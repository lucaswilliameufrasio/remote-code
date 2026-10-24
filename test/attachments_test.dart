import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_dev/core/attachments.dart';

void main() {
  test('Should encode UTF-8 text as an inline v2 attachment', () {
    final attachment = PromptAttachment.fromBytes(
        'notes.txt', Uint8List.fromList(utf8.encode('Review the patch.')));
    expect(attachment.mime, 'text/plain');
    expect(attachment.modality, 'text');
    final json = attachment.toJson();
    expect(json.keys.toSet(), {'uri', 'name'});
    final data = Uri.parse(json['uri'] as String).data;
    expect(data?.mimeType, 'text/plain');
    expect(data?.contentAsString(), 'Review the patch.');
  });

  test('Should detect supported images and PDF by content instead of filename',
      () {
    final signatures = {
      'image/png': [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a],
      'image/jpeg': [0xff, 0xd8, 0xff, 0x00],
      'image/gif': ascii.encode('GIF89a'),
      'image/webp': [
        ...ascii.encode('RIFF'),
        0,
        0,
        0,
        0,
        ...ascii.encode('WEBP')
      ],
      'application/pdf': ascii.encode('%PDF-1.7'),
    };
    for (final entry in signatures.entries) {
      final attachment = PromptAttachment.fromBytes(
          'file.bin', Uint8List.fromList(entry.value));
      expect(attachment.mime, entry.key);
    }
  });

  test('Should reject audio video binary and malformed UTF-8 content', () {
    for (final bytes in [
      [0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x41, 0x56, 0x45],
      [0, 0, 0, 0x20, 0x66, 0x74, 0x79, 0x70],
      [0x50, 0x4b, 0, 0],
      [0xff, 0xfe, 0xfd],
    ]) {
      expect(
          () =>
              PromptAttachment.fromBytes('file.txt', Uint8List.fromList(bytes)),
          throwsA(isA<AttachmentException>()));
    }
  });

  test('Should reject empty and oversized files before encoding them', () {
    expect(() => PromptAttachment.fromBytes('empty.txt', Uint8List(0)),
        throwsA(isA<AttachmentException>()));
    expect(
        () => PromptAttachment.fromBytes(
            'large.txt', Uint8List(PromptAttachment.maxBytes + 1)),
        throwsA(isA<AttachmentException>()));
  });

  test('Should bound file count and aggregate attachment bytes', () {
    final text = PromptAttachment.fromBytes('a.txt', Uint8List.fromList([65]));
    expect(() => PromptAttachment.validateBatch(List.filled(5, text)),
        throwsA(isA<AttachmentException>()));
    final large = PromptAttachment.fromBytes(
        'a.txt', Uint8List.fromList(List.filled(3 * 1024 * 1024, 65)));
    expect(() => PromptAttachment.validateBatch([large, large]),
        throwsA(isA<AttachmentException>()));
  });

  test('Should require explicit model support for images and PDF', () {
    final pdf = PromptAttachment.fromBytes(
        'a.pdf', Uint8List.fromList(ascii.encode('%PDF-1.7')));
    expect(() => PromptAttachment.validateModel([pdf], {}),
        throwsA(isA<AttachmentException>()));
    expect(
        () => PromptAttachment.validateModel([
              pdf
            ], {
              'capabilities': {
                'input': ['text', 'image']
              }
            }),
        throwsA(isA<AttachmentException>()));
    PromptAttachment.validateModel([
      pdf
    ], {
      'capabilities': {
        'input': ['text', 'pdf']
      }
    });
  });
}
