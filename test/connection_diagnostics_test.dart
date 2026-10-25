import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:remote_dev/core/api.dart';
import 'package:remote_dev/core/connection_diagnostics.dart';
import 'package:remote_dev/core/models.dart';

const machine = Machine(
    id: 'private-id',
    name: 'private-machine',
    url: 'https://private-host.example',
    username: 'private-user',
    password: 'private-password');

void main() {
  test(
      'Should check health and restricted roots through the production HTTP client',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final requests = <String>[];
    server.listen((request) async {
      requests.add('${request.method} ${request.uri.path}');
      expect(request.headers.value('authorization'), startsWith('Basic '));
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(request.uri.path == '/api/info'
          ? {'version': '2.0.29'}
          : {
              'output': {
                'data': ['/private/authorized-root']
              }
            }));
      await request.response.close();
    });
    final report = await const ConnectionDiagnostics().run(Machine(
      id: machine.id,
      name: machine.name,
      password: machine.password,
      url: 'http://127.0.0.1:${server.port}',
    ));
    expect(report.connection.outcome, DiagnosticOutcome.available);
    expect(report.files?.outcome, DiagnosticOutcome.available);
    expect(requests,
        ['GET /api/info', 'POST /api/rpc/remote-code-files-v1/roots']);
    expect(
        report.shareText(appVersion: '0.1.0+1'), isNot(contains('/private/')));
  });

  for (final status in [301, 401, 403, 404, 503]) {
    test('Should classify HTTP $status without leaking response content',
        () async {
      var count = 0;
      final report = await ConnectionDiagnostics(
          apiFactory: (value) =>
              OpenCodeApi(value, client: MockClient((_) async {
                count++;
                return http.Response(
                    'private-password private-host.example', status);
              }))).run(machine);
      expect(count, 1);
      expect(
          report.connection.outcome,
          switch (status) {
            401 => DiagnosticOutcome.authenticationDenied,
            403 => DiagnosticOutcome.accessDenied,
            503 => DiagnosticOutcome.unavailable,
            _ => DiagnosticOutcome.incompatible,
          });
      final text = report.shareText(appVersion: '0.1.0+1');
      expect(text, isNot(contains('private-')));
    });
  }

  test('Should distinguish missing roots from a missing extension', () async {
    for (final missing in [true, false]) {
      final report = await ConnectionDiagnostics(
          apiFactory: (value) =>
              OpenCodeApi(value, client: MockClient((request) async {
                if (request.url.path == '/api/info') {
                  return http.Response('{"version":"2.0.29"}', 200);
                }
                return missing
                    ? http.Response('{}', 404)
                    : http.Response('{"output":{"data":[]}}', 200);
              }))).run(machine);
      expect(
          report.files?.outcome,
          missing
              ? DiagnosticOutcome.pluginMissing
              : DiagnosticOutcome.rootsMissing);
    }
  });

  test('Should classify typed TLS errors without inspecting exception messages',
      () async {
    final report = await ConnectionDiagnostics(
        apiFactory: (value) => OpenCodeApi(value, client: MockClient((_) async {
              throw const HandshakeException('private-password');
            }))).run(machine);
    expect(report.connection.outcome, DiagnosticOutcome.tlsFailure);
    expect(report.shareText(appVersion: '0.1.0+1'),
        isNot(contains('private-password')));
  });

  test('Should reject old OpenCode versions before probing files', () async {
    var count = 0;
    final report = await ConnectionDiagnostics(
        apiFactory: (value) => OpenCodeApi(value, client: MockClient((_) async {
              count++;
              return http.Response('{"version":"1.0.0"}', 200);
            }))).run(machine);
    expect(count, 1);
    expect(report.connection.outcome, DiagnosticOutcome.incompatible);
  });

  test('Should reject malformed health without using arbitrary response text',
      () async {
    for (final body in ['<html>private-password</html>', '{}']) {
      final report = await ConnectionDiagnostics(
              apiFactory: (value) => OpenCodeApi(value,
                  client: MockClient((_) async => http.Response(body, 200))))
          .run(machine);
      expect(report.connection.outcome, DiagnosticOutcome.incompatible);
      expect(report.files, isNull);
    }
  });

  test('Should distinguish timeout from other transport failures', () async {
    for (final timeout in [true, false]) {
      final report = await ConnectionDiagnostics(
          apiFactory: (value) =>
              OpenCodeApi(value, client: MockClient((_) async {
                if (timeout) {
                  throw TimeoutException('private-host.example');
                }
                throw http.ClientException('private-password');
              }))).run(machine);
      expect(report.connection.outcome,
          timeout ? DiagnosticOutcome.timeout : DiagnosticOutcome.unreachable);
      expect(
          report.shareText(appVersion: '0.1.0+1'), isNot(contains('private-')));
    }
  });

  test('Should classify refused local sockets through the real HTTP transport',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;
    await server.close(force: true);
    final report = await const ConnectionDiagnostics().run(Machine(
      id: 'local',
      name: 'Local',
      url: 'http://127.0.0.1:$port',
      password: 'synthetic',
    ));
    expect(report.connection.outcome, DiagnosticOutcome.unreachable);
  });

  test('Should use only Claude routes and not probe unsupported file APIs',
      () async {
    final paths = <String>[];
    final report = await ConnectionDiagnostics(
        apiFactory: (value) =>
            OpenCodeApi.create(value, client: MockClient((request) async {
              paths.add(request.url.path);
              return http.Response(
                  '{"healthy":true,"agent":"claude_code","protocol_version":1,"adapter_version":"0.1.0"}',
                  200);
            }))).run(const Machine(
        id: 'claude',
        name: 'Claude',
        url: 'https://claude.example',
        password: 'synthetic',
        backend: AgentBackend.claudeCode));
    expect(paths, ['/relay/v1/info']);
    expect(report.files?.outcome, DiagnosticOutcome.notApplicable);
  });

  test('Should exclude arbitrary server and app metadata from reports', () {
    final report = ConnectionDiagnosticReport(
        backend: AgentBackend.openCode,
        connection: const DiagnosticCheck(DiagnosticOutcome.unavailable,
            httpStatus: 9000),
        serverVersion: 'private-password\n/private/path');
    final text = report.shareText(appVersion: 'private-host.example');
    expect(text, isNot(contains('private-')));
    expect(text, isNot(contains('HTTP:')));
    final metadataReport = ConnectionDiagnosticReport(
      backend: AgentBackend.openCode,
      connection: const DiagnosticCheck(DiagnosticOutcome.available),
      serverVersion: '2.0.29+private-host.example',
    );
    expect(metadataReport.shareText(appVersion: '0.1.0+1'),
        isNot(contains('private-host')));
  });
}
