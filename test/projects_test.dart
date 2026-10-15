import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:remote_dev/core/api.dart';
import 'package:remote_dev/core/models.dart';
import 'package:remote_dev/core/store.dart';
import 'package:remote_dev/features/projects.dart';

const firstMachine = Machine(
  id: 'desktop-a',
  name: 'Desktop A',
  url: 'https://desktop-a.example.ts.net',
  password: 'unit-test-password',
  directories: ['/work/alpha'],
);

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('Should group sessions by server project identity within each machine',
      () {
    const secondMachine = Machine(
      id: 'desktop-b',
      name: 'Desktop B',
      url: 'https://desktop-b.example.ts.net',
      password: 'unit-test-password',
    );
    final bookmarks = [
      Bookmark(
        machineID: firstMachine.id,
        session: const Session(
          id: 'ses_one',
          title: 'One',
          directory: '/work/alpha',
          projectID: 'prj_alpha',
        ),
        opened: 300,
      ),
      Bookmark(
        machineID: firstMachine.id,
        session: const Session(
          id: 'ses_two',
          title: 'Two',
          directory: '/work/alpha/packages/mobile',
          projectID: 'prj_alpha',
        ),
        opened: 500,
      ),
      Bookmark(
        machineID: secondMachine.id,
        session: const Session(
          id: 'ses_three',
          title: 'Three',
          directory: '/work/alpha',
          projectID: 'prj_alpha',
        ),
        opened: 400,
      ),
    ];

    final targets = buildProjectTargets(
      machines: [firstMachine, secondMachine],
      bookmarks: bookmarks,
      serverProjects: {
        firstMachine.id: const [
          OpenCodeProject(
            id: 'prj_alpha',
            worktree: '/work/alpha',
            name: 'Alpha project',
          ),
        ],
        secondMachine.id: const [
          OpenCodeProject(
            id: 'prj_alpha',
            worktree: '/work/alpha',
            name: 'Alpha project',
          ),
        ],
      },
    );

    expect(targets, hasLength(2));
    expect(targets.first.machine.id, firstMachine.id);
    expect(targets.first.recentSessionCount, 2);
    expect(targets.first.lastOpened, 500);
    expect(targets.last.machine.id, secondMachine.id);
    expect(targets.last.recentSessionCount, 1);
  });

  test('Should use local directories when a server has no project record', () {
    final bookmark = Bookmark(
      machineID: firstMachine.id,
      session: const Session(
        id: 'ses_local',
        title: 'Local session',
        directory: '/work/alpha/',
      ),
      opened: 100,
    );

    final targets = buildProjectTargets(
      machines: [firstMachine],
      bookmarks: [bookmark],
      serverProjects: const {},
    );

    expect(targets, hasLength(1));
    expect(targets.single.directory, '/work/alpha/');
    expect(targets.single.recentSessionCount, 1);
  });

  testWidgets('Should open sessions filtered to the selected project',
      (tester) async {
    final store = AppStore();
    await store.load();
    await store.putMachine(firstMachine);
    ProjectTarget? selectedProject;
    final screenKey = GlobalKey<ProjectsScreenState>();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProjectsScreen(
            key: screenKey,
            store: store,
            apiFactory: (machine) => OpenCodeApi(
              machine,
              client: MockClient((request) async {
                expect(request.url.path, '/api/project');
                return http.Response(
                  jsonEncode([
                    {
                      'id': 'prj_alpha',
                      'worktree': '/work/alpha',
                      'name': 'Alpha project',
                    },
                  ]),
                  200,
                );
              }),
            ),
            onOpenProject: (project) async {
              selectedProject = project;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Alpha project'), findsOneWidget);
    expect(find.text('Desktop A'), findsOneWidget);
    await tester.tap(find.text('Alpha project'));
    await tester.pumpAndSettle();

    expect(selectedProject?.projectID, 'prj_alpha');
    expect(selectedProject?.directory, '/work/alpha');
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
