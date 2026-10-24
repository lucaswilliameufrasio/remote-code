import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_dev/core/models.dart';
import 'package:remote_dev/core/store.dart';
import 'package:remote_dev/core/prompt_attempt.dart';

void main() {
  group('Persisted uncertain prompt', () {
    test('Should generate independent valid IDs for identical prompt text', () {
      final first = PromptAttempt.create('Review');
      final second = PromptAttempt.create('Review');
      expect(first.id, startsWith('msg_'));
      expect(first.id, isNot(second.id));
    });

    test(
        'Should preserve an unresolved marker through draft edits and app reload',
        () async {
      FlutterSecureStorage.setMockInitialValues({});
      final store = AppStore();
      await store.load();
      const machine = Machine(
          id: 'machine',
          name: 'Test',
          url: 'https://host.example',
          password: 'test');
      const session =
          Session(id: 'ses_test', title: 'Test', directory: '/work');
      final attempt = PromptAttempt.create('Original');
      await store.remember(machine, session,
          draft: 'Original', pendingPrompt: attempt);
      await store.remember(machine, session, draft: 'Edited');
      final restored = AppStore();
      await restored.load();
      final bookmark = restored.bookmark(machine.id, session.id);
      expect(bookmark?.pendingPrompt?.id, attempt.id);
      expect(bookmark?.pendingPrompt?.text, 'Original');
      expect(bookmark?.draft, 'Edited');
      await restored.remember(machine, session, clearPendingPrompt: true);
      final cleared = AppStore();
      await cleared.load();
      expect(cleared.bookmark(machine.id, session.id)?.pendingPrompt, isNull);
      expect(cleared.bookmark(machine.id, session.id)?.draft, 'Edited');
    });
  });
}
