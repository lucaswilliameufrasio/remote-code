import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_dev/core/pairing_qr.dart';
import 'package:remote_dev/features/pairing_qr.dart';

void main() {
  group('Pairing QR safety', () {
    test(
        'Should accept only an HTTPS pairing link on the already confirmed origin',
        () {
      expect(
          pairingCodeFromQr('https://host.example/auth/connect/test_code',
              'https://host.example'),
          'test_code');
      for (final value in [
        'https://other.example/auth/connect/test_code',
        'http://host.example/auth/connect/test_code',
        'https://host.example:444/auth/connect/test_code',
        'https://user:password@host.example/auth/connect/test_code',
        'https://host.example/auth/connect/code?next=other',
        'https://host.example/auth/connect/code#fragment',
        'https://host.example/auth/connect/%2Fsecret',
        'https://host.example/other/test_code',
        'javascript:alert(1)',
        'not-a-url',
      ]) {
        expect(() => pairingCodeFromQr(value, 'https://host.example'),
            throwsFormatException);
      }
    });

    testWidgets(
        'Should return a scanned code once without making any network request',
        (tester) async {
      String? result;
      await tester.pumpWidget(MaterialApp(
          home: Builder(
              builder: (context) => Scaffold(
                    body: TextButton(
                        onPressed: () async {
                          result = await Navigator.push<String>(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => PairingQrScreen(
                                        serverUrl: 'https://host.example',
                                        scannerBuilder: (context, onScan) =>
                                            TextButton(
                                                onPressed: () {
                                                  onScan(
                                                      'https://host.example/auth/connect/test_code');
                                                  onScan(
                                                      'https://host.example/auth/connect/second_code');
                                                },
                                                child:
                                                    const Text('Scan fixture')),
                                      )));
                        },
                        child: const Text('Open scanner')),
                  ))));
      await tester.tap(find.text('Open scanner'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Ler o QR não conecta'), findsOneWidget);
      await tester.tap(find.text('Scan fixture'));
      await tester.pumpAndSettle();
      expect(result, 'test_code');
    });

    testWidgets(
        'Should reject another host without exposing its code and keep manual fallback',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
          home: PairingQrScreen(
              serverUrl: 'https://host.example',
              scannerBuilder: (context, onScan) => TextButton(
                  onPressed: () =>
                      onScan('https://other.example/auth/connect/private_code'),
                  child: const Text('Scan fixture')))));
      await tester.tap(find.text('Scan fixture'));
      await tester.pump();
      expect(find.textContaining('máquina indicada'), findsOneWidget);
      expect(find.textContaining('private_code'), findsNothing);
      expect(find.text('Voltar para entrada manual'), findsOneWidget);
    });
  });
}
