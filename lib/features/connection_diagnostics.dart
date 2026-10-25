import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../core/api.dart';
import '../core/connection_diagnostics.dart';
import '../core/models.dart';
import 'common.dart';

sealed class DiagnosticView {
  const DiagnosticView();
}

class DiagnosticReady extends DiagnosticView {
  const DiagnosticReady();
}

class DiagnosticChecking extends DiagnosticView {
  const DiagnosticChecking();
}

class DiagnosticComplete extends DiagnosticView {
  final ConnectionDiagnosticReport report;
  const DiagnosticComplete(this.report);
}

class ConnectionDiagnosticsScreen extends StatefulWidget {
  final Machine machine;
  final OpenCodeApiFactory apiFactory;
  const ConnectionDiagnosticsScreen({
    super.key,
    required this.machine,
    this.apiFactory = OpenCodeApi.create,
  });

  @override
  State<ConnectionDiagnosticsScreen> createState() =>
      _ConnectionDiagnosticsScreenState();
}

class _ConnectionDiagnosticsScreenState
    extends State<ConnectionDiagnosticsScreen> {
  DiagnosticView _view = const DiagnosticReady();
  String _appVersion = 'indisponível';

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final version = diagnosticVersion('${info.version}+${info.buildNumber}');
      if (mounted && version != null) {
        setState(() => _appVersion = version);
      }
    } catch (_) {
      // Missing platform metadata remains explicitly unavailable, never guessed.
    }
  }

  Future<void> _run() async {
    if (_view is DiagnosticChecking) {
      return;
    }
    setState(() {
      _view = const DiagnosticChecking();
    });
    final report = await ConnectionDiagnostics(
      apiFactory: widget.apiFactory,
    ).run(widget.machine);
    if (mounted) {
      setState(() {
        _view = DiagnosticComplete(report);
      });
    }
  }

  Future<void> _copy() async {
    final view = _view;
    if (view is! DiagnosticComplete) {
      return;
    }
    try {
      await Clipboard.setData(
        ClipboardData(text: view.report.shareText(appVersion: _appVersion)),
      );
      if (mounted) {
        notice(context, 'Relatório sem dados da máquina copiado.');
      }
    } catch (_) {
      if (mounted) {
        notice(context, 'Não foi possível copiar o relatório.');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final report = switch (_view) {
      DiagnosticComplete(:final report) => report,
      _ => null,
    };
    return Scaffold(
      appBar: AppBar(title: const Text('Diagnóstico de conexão')),
      body: ListView(
        padding: const EdgeInsets.all(22),
        children: [
          const InfoBox(
            'Verificação sob demanda, sem enviar prompts nem alterar o servidor. Não confirma saldo do provedor ou disponibilidade dos modelos.',
            icon: Icons.health_and_safety_outlined,
          ),
          const SizedBox(height: 20),
          Text('App: $_appVersion'),
          Text('Agente: ${widget.machine.backend.label}'),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _view is DiagnosticChecking ? null : _run,
            icon: const Icon(Icons.network_check),
            label: const Text('Executar diagnóstico'),
          ),
          if (_view is DiagnosticChecking) ...[
            const SizedBox(height: 16),
            const LinearProgressIndicator(),
            const Text('Consultando conexão e recursos. Até 40 segundos.'),
          ],
          if (report != null) ...[
            const SizedBox(height: 20),
            Text('Conexão: ${report.connection.outcome.description}'),
            if (report.serverVersion case final version?)
              Text('Servidor: $version'),
            if (report.files case final check?) ...[
              const SizedBox(height: 12),
              Text('Arquivos: ${check.outcome.description}'),
            ],
            const SizedBox(height: 20),
            SelectableText(report.shareText(appVersion: _appVersion)),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _copy,
              icon: const Icon(Icons.copy_outlined),
              label: const Text('Copiar relatório seguro'),
            ),
          ],
        ],
      ),
    );
  }
}
