import 'dart:math';
import 'models.dart';

class PromptAttempt {
  final String id, text;
  final int created;
  const PromptAttempt(
      {required this.id, required this.text, required this.created});

  factory PromptAttempt.create(String text) {
    final random = Random.secure();
    final suffix = List.generate(
            16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'))
        .join();
    final created = DateTime.now().millisecondsSinceEpoch;
    return PromptAttempt(
        id: 'msg_rc_${created.toRadixString(16)}_$suffix',
        text: text,
        created: created);
  }

  factory PromptAttempt.fromJson(Json value) {
    final id = value['id'];
    final text = value['text'];
    final created = value['created'];
    if (id is! String ||
        !id.startsWith('msg_') ||
        text is! String ||
        created is! int) {
      throw const FormatException('Invalid persisted prompt attempt');
    }
    return PromptAttempt(id: id, text: text, created: created);
  }

  Json toJson() => {'id': id, 'text': text, 'created': created};
}
