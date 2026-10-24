import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../core/pairing_qr.dart';

typedef PairingScannerBuilder = Widget Function(
    BuildContext context, ValueChanged<String> onScan);

class PairingQrScreen extends StatefulWidget {
  final String serverUrl;
  final PairingScannerBuilder? scannerBuilder;
  const PairingQrScreen(
      {super.key, required this.serverUrl, this.scannerBuilder});
  @override
  State<PairingQrScreen> createState() => _PairingQrScreenState();
}

class _PairingQrScreenState extends State<PairingQrScreen> {
  bool accepted = false;
  String? error;

  void _scan(String value) {
    if (accepted || !mounted) {
      return;
    }
    try {
      final code = pairingCodeFromQr(value, widget.serverUrl);
      accepted = true;
      Navigator.pop(context, code);
    } on FormatException catch (exception) {
      setState(() => error = exception.message);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Ler QR de pareamento')),
        body: Column(children: [
          Padding(
              padding: const EdgeInsets.all(16),
              child: Column(children: [
                Text('Destino: ${widget.serverUrl}'),
                const SizedBox(height: 8),
                const Text(
                    'A câmera lê o código localmente. Ler o QR não conecta nem envia credenciais; você confirma na próxima tela.'),
                if (error != null)
                  Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(error!)),
              ])),
          Expanded(
              child: widget.scannerBuilder?.call(context, _scan) ??
                  MobileScanner(
                    onDetect: (capture) {
                      for (final barcode in capture.barcodes) {
                        final value = barcode.rawValue;
                        if (barcode.format == BarcodeFormat.qrCode &&
                            value != null) {
                          _scan(value);
                        }
                      }
                    },
                    errorBuilder: (context, exception) => const Center(
                        child: Padding(
                      padding: EdgeInsets.all(20),
                      child: Text(
                          'Câmera indisponível ou sem permissão. Volte e digite o código temporário manualmente.'),
                    )),
                  )),
          SafeArea(
              top: false,
              child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Voltar para entrada manual'))),
        ]),
      );
}
