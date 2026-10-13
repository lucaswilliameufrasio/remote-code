import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:remote_dev/core/models.dart';
import 'package:remote_dev/core/store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('App store restoration', () {
    setUp(() => FlutterSecureStorage.setMockInitialValues({}));
    test('Should recover sessions across machines after a cold restart',
        () async {
      final store = AppStore();
      const desktop = Machine(
          id: 'desktop',
          name: 'Desktop',
          url: 'https://a.example.ts.net',
          password: 'a-secret');
      const mac = Machine(
          id: 'mac',
          name: 'Mac',
          url: 'https://b.example.ts.net',
          password: 'b-secret');
      await store.putMachine(desktop);
      await store.putMachine(mac);
      await store.remember(
          desktop,
          const Session(
              id: 'ses_1', title: 'Backend', directory: '/work/backend'),
          draft: 'continue backend');
      await store.remember(desktop,
          const Session(id: 'ses_2', title: 'Front', directory: '/work/front'),
          draft: 'continue front');
      await store.remember(
          mac,
          const Session(
              id: 'ses_1', title: 'Mobile', directory: '/workspace/project-1'));
      final restoredStore = AppStore();
      await restoredStore.load();
      expect(restoredStore.bookmarks.length, 3);
      expect(restoredStore.bookmark('desktop', 'ses_1')!.draft,
          'continue backend');
      expect(
          restoredStore.bookmark('desktop', 'ses_2')!.draft, 'continue front');
      expect(restoredStore.bookmark('mac', 'ses_1')!.session.directory,
          '/workspace/project-1');
      expect(restoredStore.machine('desktop')!.directories,
          containsAll(['/work/backend', '/work/front']));
      expect(restoredStore.machine('mac')!.password, 'b-secret');
    });
    test('Should keep concurrent machine profile writes after restart',
        () async {
      final store = AppStore();
      await Future.wait([
        store.putMachine(const Machine(
            id: 'a', name: 'A', url: 'https://a.ts.net', password: 'secret')),
        store.putMachine(const Machine(
            id: 'b', name: 'B', url: 'https://b.ts.net', password: 'secret')),
      ]);
      final restoredStore = AppStore();
      await restoredStore.load();
      expect(restoredStore.machines.length, 2);
    });
    test('Should reject private HTTP URLs outside the tailnet address space',
        () {
      expect(validateServerUrl('http://100.64.0.1:4096'), isNull);
      expect(validateServerUrl('http://100.127.255.255:4096'), isNull);
      expect(validateServerUrl('http://100.128.0.1:4096'), isNotNull);
      expect(validateServerUrl('http://100.64.999.1:4096'), isNotNull);
      expect(validateServerUrl('http://8.8.8.8:4096'), isNotNull);
      expect(validateServerUrl('https://userinfo@host.ts.net'), isNotNull);
      expect(validateServerUrl('https://host.ts.net/proxy'), isNotNull);
    });
    test('Should allow loopback HTTP only for an explicit local preview', () {
      expect(validateServerUrl('http://127.0.0.1:4096'), isNotNull);
      expect(
        validateServerUrl(
          'http://127.0.0.1:4096',
          allowLoopbackHttp: true,
        ),
        isNull,
      );
      expect(
        validateServerUrl(
          'http://192.168.1.20:4096',
          allowLoopbackHttp: true,
        ),
        isNotNull,
      );
    });
  });
}
