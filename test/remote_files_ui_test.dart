import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_dev/core/api.dart';
import 'package:remote_dev/core/file_changes.dart';
import 'package:remote_dev/core/models.dart';
import 'package:remote_dev/core/remote_files.dart';
import 'package:remote_dev/features/file_changes.dart';
import 'package:remote_dev/features/remote_files.dart';

void main() {
  group('Remote file workflows', () {
    testWidgets(
        'Should browse folders return to the project and preview without sending',
        (tester) async {
      final api = _FilesApi();
      addTearDown(api.close);
      await tester.pumpWidget(MaterialApp(
          home: RemoteFilesScreen(api: api, directory: '/work/project')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('src'));
      await tester.pumpAndSettle();
      expect(api.paths, ['', 'src']);
      expect(find.text('/work/project/src'), findsOneWidget);
      await tester.tap(find.text('main.dart'));
      await tester.pumpAndSettle();
      expect(find.text('void main() {}'), findsOneWidget);
      expect(find.text('Inserir caminho no rascunho'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pasta anterior'));
      await tester.pumpAndSettle();
      expect(api.paths, ['', 'src', '']);
      expect(find.text('Pasta anterior'), findsNothing);
    });

    testWidgets(
        'Should select a subdirectory explicitly instead of opening files',
        (tester) async {
      final api = _FilesApi();
      addTearDown(api.close);
      String? selected;
      await tester.pumpWidget(MaterialApp(
          home: Builder(
              builder: (context) => Scaffold(
                    body: TextButton(
                        onPressed: () async {
                          selected = await Navigator.push<String>(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => RemoteFilesScreen(
                                      api: api,
                                      directory: '/work/project',
                                      chooseDirectory: true)));
                        },
                        child: const Text('Choose')),
                  ))));
      await tester.tap(find.text('Choose'));
      await tester.pumpAndSettle();
      expect(find.text('README.md'), findsNothing);
      await tester.tap(find.text('src'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Usar esta pasta'));
      await tester.pumpAndSettle();
      expect(selected, '/work/project/src');
    });

    testWidgets('Should ignore a stale search result after the query changes',
        (tester) async {
      final api = _FilesApi();
      addTearDown(api.close);
      final stale = Completer<List<RemoteFileEntry>>();
      api.stale = stale;
      await tester.pumpWidget(MaterialApp(
          home: RemoteFilesScreen(api: api, directory: '/work/project')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'old');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.enterText(find.byType(TextField), 'new');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      stale.complete(
          [const RemoteFileEntry(path: 'stale.txt', isDirectory: false)]);
      await tester.pumpAndSettle();
      expect(find.text('stale.txt'), findsNothing);
      expect(find.text('new.txt'), findsOneWidget);
    });

    testWidgets('Should retry a denied listing only after a user action',
        (tester) async {
      final api = _FilesApi()..denied = true;
      addTearDown(api.close);
      await tester.pumpWidget(MaterialApp(
          home: RemoteFilesScreen(api: api, directory: '/work/project')));
      await tester.pumpAndSettle();
      expect(find.text('Denied by host'), findsOneWidget);
      expect(api.paths, ['']);
      api.denied = false;
      await tester.tap(find.text('Tentar novamente'));
      await tester.pumpAndSettle();
      expect(find.text('src'), findsOneWidget);
    });

    testWidgets(
        'Should label a truncated preview and avoid implying a complete file',
        (tester) async {
      final api = _FilesApi()..truncated = true;
      addTearDown(api.close);
      await tester.pumpWidget(MaterialApp(
          home: RemoteFilesScreen(api: api, directory: '/work/project')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('README.md'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Prévia limitada a 256 KiB'), findsOneWidget);
    });
  });

  group('Visual session diff', () {
    testWidgets(
        'Should show file counts and open a readable patch with its comparison scope',
        (tester) async {
      final api = _FilesApi();
      addTearDown(api.close);
      await tester.pumpWidget(MaterialApp(
          home: FileChangesScreen(
              api: api,
              session: const Session(
                  id: 'ses_test', title: 'Test', directory: '/work/project'))));
      await tester.pumpAndSettle();
      expect(
          find.textContaining('Não é o diff completo do Git'), findsOneWidget);
      expect(find.text('1 arquivos · +1 / −1'), findsOneWidget);
      await tester.tap(find.text('main.dart'));
      await tester.pumpAndSettle();
      expect(find.text('+new'), findsOneWidget);
      expect(find.text('-old'), findsOneWidget);
      expect(find.text('@@ -1 +1 @@'), findsOneWidget);
    });

    testWidgets('Should warn when a patch exceeds the preview limit',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
          home: FilePatchScreen(
              change: FileChange(
                  file: 'large.txt',
                  patch: List.filled(2100, '+line').join('\n'),
                  status: 'added',
                  additions: 2100,
                  deletions: 0))));
      expect(find.textContaining('não está sendo exibido por completo'),
          findsOneWidget);
    });
  });
}

class _FilesApi extends OpenCodeApi {
  final paths = <String>[];
  bool denied = false, truncated = false;
  Completer<List<RemoteFileEntry>>? stale;
  _FilesApi()
      : super(const Machine(
            id: 'mock',
            name: 'Mock',
            url: 'https://mock.example.ts.net',
            password: 'test'));

  @override
  Future<List<RemoteFileEntry>> listRemoteFiles(String directory,
      {String path = ''}) async {
    paths.add(path);
    if (denied) {
      throw const ApiException(403, 'Denied by host');
    }
    return path.isEmpty
        ? [
            const RemoteFileEntry(path: 'src', isDirectory: true),
            const RemoteFileEntry(path: 'README.md', isDirectory: false),
          ]
        : [const RemoteFileEntry(path: 'src/main.dart', isDirectory: false)];
  }

  @override
  Future<List<RemoteFileEntry>> findRemoteFiles(String directory, String query,
      {bool directoriesOnly = false}) async {
    if (query == 'old' && stale != null) {
      return stale!.future;
    }
    return [const RemoteFileEntry(path: 'new.txt', isDirectory: false)];
  }

  @override
  Future<RemoteFilePreview> readRemoteFile(
          String directory, String path) async =>
      RemoteFilePreview('void main() {}', truncated: truncated);

  @override
  Future<List<FileChange>> sessionChanges(Session session) async => [
        const FileChange(
            file: 'main.dart',
            patch: '@@ -1 +1 @@\n-old\n+new',
            status: 'modified',
            additions: 1,
            deletions: 1),
      ];
}
