import 'api.dart';
import 'models.dart';

enum DiagnosticOutcome {
  available,
  authenticationDenied,
  accessDenied,
  tlsFailure,
  timeout,
  unreachable,
  incompatible,
  pluginMissing,
  rootsMissing,
  unavailable,
  notApplicable;

  String get description => switch (this) {
        available => 'Disponível',
        authenticationDenied =>
          'Autenticação recusada. Confira usuário e senha.',
        accessDenied =>
          'Acesso recusado. Confira as regras do servidor e da tailnet.',
        tlsFailure => 'Falha TLS. Confira certificado, relógio e URL HTTPS.',
        timeout => 'Tempo esgotado. Confira Tailscale, servidor e porta.',
        unreachable => 'Sem conexão. Confira rede, VPN, DNS e servidor.',
        incompatible =>
          'Versão ou resposta incompatível com o agente selecionado.',
        pluginMissing => 'Extensão File Browser ausente. Instale-a no host.',
        rootsMissing =>
          'Nenhuma raiz autorizada. Configure a extensão no host.',
        unavailable =>
          'Serviço indisponível. Confira o processo no computador.',
        notApplicable => 'Não se aplica ao adaptador Claude Code.',
      };
}

class DiagnosticCheck {
  final DiagnosticOutcome outcome;
  final int? httpStatus;
  const DiagnosticCheck(this.outcome, {this.httpStatus});
}

// Only strict version identifiers may cross the report boundary.
String? diagnosticVersion(Object? value) {
  if (value is String &&
      RegExp(
        r'^\d{1,4}\.\d{1,4}\.\d{1,4}(?:[-+][A-Za-z0-9.-]{1,32})?$',
      ).hasMatch(value)) {
    return value;
  }
  return null;
}

String? _serverVersion(Object? value) {
  final version = diagnosticVersion(value);
  if (version == null) {
    return null;
  }
  // Server-controlled prerelease/build labels may contain private host metadata.
  return version.split(RegExp('[-+]')).first;
}

class ConnectionDiagnosticReport {
  final AgentBackend backend;
  final DiagnosticCheck connection;
  final DiagnosticCheck? files;
  final String? serverVersion;

  const ConnectionDiagnosticReport({
    required this.backend,
    required this.connection,
    this.files,
    this.serverVersion,
  });

  String shareText({required String appVersion}) {
    final version = diagnosticVersion(appVersion) ?? 'indisponível';
    final server = _serverVersion(serverVersion) ?? 'indisponível';
    return [
      'CodeRelay · diagnóstico',
      'App: $version',
      'Agente: ${backend.label}',
      'Servidor: $server',
      'Conexão: ${connection.outcome.description}',
      if (connection.httpStatus case final status?
          when status >= 100 && status <= 599)
        'HTTP: $status',
      if (files case final check?) 'Arquivos: ${check.outcome.description}',
      'Sem URL, credenciais, caminhos ou conteúdo de sessões.',
    ].join('\n');
  }
}

class ConnectionDiagnostics {
  final OpenCodeApiFactory apiFactory;
  const ConnectionDiagnostics({this.apiFactory = OpenCodeApi.create});

  Future<ConnectionDiagnosticReport> run(Machine machine) async {
    final api = apiFactory(machine);
    try {
      final health = await api.health();
      final version = _serverVersion(health['version']);
      if (health['healthy'] != true ||
          version == null ||
          (machine.backend == AgentBackend.openCode &&
              !version.startsWith('2.'))) {
        return ConnectionDiagnosticReport(
          backend: machine.backend,
          connection: const DiagnosticCheck(DiagnosticOutcome.incompatible),
          serverVersion: version,
        );
      }
      DiagnosticCheck files;
      if (machine.backend == AgentBackend.claudeCode) {
        files = const DiagnosticCheck(DiagnosticOutcome.notApplicable);
      } else {
        try {
          final roots = await api.allowedFileRoots();
          files = DiagnosticCheck(
            roots.isEmpty
                ? DiagnosticOutcome.rootsMissing
                : DiagnosticOutcome.available,
          );
        } catch (exception) {
          files = _failure(exception, checkingFiles: true);
        }
      }
      return ConnectionDiagnosticReport(
        backend: machine.backend,
        connection: const DiagnosticCheck(DiagnosticOutcome.available),
        files: files,
        serverVersion: version,
      );
    } catch (exception) {
      return ConnectionDiagnosticReport(
        backend: machine.backend,
        connection: _failure(exception),
      );
    } finally {
      api.close();
    }
  }

  DiagnosticCheck _failure(Object exception, {bool checkingFiles = false}) {
    if (exception is! ApiException) {
      return const DiagnosticCheck(DiagnosticOutcome.unavailable);
    }
    final outcome = switch ((exception.status, exception.code)) {
      (401, _) => DiagnosticOutcome.authenticationDenied,
      (403, _) => DiagnosticOutcome.accessDenied,
      (_, 'TLS_FAILURE') => DiagnosticOutcome.tlsFailure,
      (_, 'TIMEOUT') => DiagnosticOutcome.timeout,
      (_, 'NETWORK_UNREACHABLE' || 'NETWORK_FAILURE') =>
        DiagnosticOutcome.unreachable,
      (_, 'INCOMPATIBLE_RESPONSE') => DiagnosticOutcome.incompatible,
      (404, _) when checkingFiles => DiagnosticOutcome.pluginMissing,
      (404, _) || (>= 300 && < 400, _) => DiagnosticOutcome.incompatible,
      _ => DiagnosticOutcome.unavailable,
    };
    return DiagnosticCheck(outcome, httpStatus: exception.status);
  }
}
