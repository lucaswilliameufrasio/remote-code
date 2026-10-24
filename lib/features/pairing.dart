import 'package:flutter/material.dart';
import '../core/api.dart';
import '../core/models.dart';
import 'common.dart';
import 'pairing_qr.dart';

enum _PairingStage { ready, redeeming, failed }

class PairingScreen extends StatefulWidget {
  final Machine machine;
  final OpenCodeApiFactory apiFactory;
  final PairingScannerBuilder? scannerBuilder;
  const PairingScreen(
      {super.key,
      required this.machine,
      this.apiFactory = OpenCodeApi.create,
      this.scannerBuilder});
  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  final code = TextEditingController();
  _PairingStage stage = _PairingStage.ready;
  String error = '';

  Future<void> _scanQr() async {
    final scanned = await Navigator.push<String>(
        context,
        MaterialPageRoute(
          builder: (_) => PairingQrScreen(
              serverUrl: widget.machine.url,
              scannerBuilder: widget.scannerBuilder),
        ));
    if (scanned != null && mounted) {
      setState(() {
        code.text = scanned;
        stage = _PairingStage.ready;
      });
    }
  }

  @override
  void dispose() {
    code.dispose();
    super.dispose();
  }

  Future<void> _redeem() async {
    if (stage == _PairingStage.redeeming) {
      return;
    }
    setState(() => stage = _PairingStage.redeeming);
    final api = widget.apiFactory(widget.machine);
    try {
      final token = await api.redeemPairingCode(code.text.trim());
      if (mounted) {
        code.clear();
        Navigator.pop(context, token);
      }
    } catch (exception) {
      if (mounted) {
        code.clear();
        setState(() {
          error = exception.toString();
          stage = _PairingStage.failed;
        });
      }
    } finally {
      api.close();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Parear com a máquina')),
        body: ListView(padding: const EdgeInsets.all(20), children: [
          const Text('Confira o destino antes de enviar o código:'),
          const SizedBox(height: 8),
          SelectableText(widget.machine.url,
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 16),
          const Text(
              'No computador confiável, gere um código de uso único com o OpenCode v2. Não envie sua senha principal nem compartilhe o código.'),
          const SizedBox(height: 8),
          const SelectableText('opencode api post /api/pair',
              style: TextStyle(fontFamily: 'monospace')),
          const SizedBox(height: 16),
          TextField(
            controller: code,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            enabled: stage != _PairingStage.redeeming,
            decoration: const InputDecoration(
                labelText: 'Código temporário (campo code)'),
          ),
          TextButton.icon(
              onPressed: stage == _PairingStage.redeeming ? null : _scanQr,
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Ler QR da mesma máquina')),
          const SizedBox(height: 12),
          const Text(
              'O código será enviado somente para a URL acima. A credencial recebida só será persistida quando você salvar a máquina.'),
          if (stage == _PairingStage.failed)
            Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: InfoBox(error, icon: Icons.error_outline)),
          const SizedBox(height: 16),
          FilledButton(
              onPressed: stage == _PairingStage.redeeming ? null : _redeem,
              child: Text(stage == _PairingStage.redeeming
                  ? 'Pareando…'
                  : 'Confirmar destino e parear')),
        ]),
      );
}
