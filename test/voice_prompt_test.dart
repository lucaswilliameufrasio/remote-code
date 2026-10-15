import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_dev/features/voice_prompt.dart';

void main() {
  test('Should insert dictated text at the active cursor with spacing', () {
    const currentValue = TextEditingValue(
      text: 'Review the latest change',
      selection: TextSelection.collapsed(offset: 24),
    );

    final updatedValue = insertDictation(currentValue, 'and run the tests');

    expect(updatedValue.text, 'Review the latest change and run the tests');
    expect(updatedValue.selection.baseOffset, updatedValue.text.length);
    expect(updatedValue.selection.extentOffset, updatedValue.text.length);
  });

  test('Should replace selected draft text without adding duplicate spaces',
      () {
    const currentValue = TextEditingValue(
      text: 'Fix old now',
      selection: TextSelection(baseOffset: 4, extentOffset: 7),
    );

    final updatedValue = insertDictation(currentValue, 'the bug');

    expect(updatedValue.text, 'Fix the bug now');
    expect(updatedValue.selection.baseOffset, 11);
  });

  testWidgets('Should require a tap, let the user review, and insert speech',
      (tester) async {
    final recognizer = _FakeVoiceRecognizer();
    String? insertedTranscript;

    await _showSheet(tester, recognizer, (transcript) {
      insertedTranscript = transcript;
    });

    expect(recognizer.initializeCalls, 0);
    expect(find.text('Começar a ditar'), findsOneWidget);

    await tester.tap(find.text('Começar a ditar'));
    await tester.pumpAndSettle();

    expect(recognizer.initializeCalls, 1);
    expect(recognizer.listenCalls, 1);
    expect(find.text('Finalizar'), findsOneWidget);

    recognizer.emit('Revise o diff', false);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Finalizar'));
    await tester.pumpAndSettle();

    expect(find.text('Inserir no rascunho'), findsOneWidget);
    await tester.enterText(
      find.byType(TextField),
      'Revise o diff e execute os testes.',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Inserir no rascunho'));
    await tester.pumpAndSettle();

    expect(insertedTranscript, 'Revise o diff e execute os testes.');
    expect(recognizer.cancelCalls, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Should cancel speech and leave the draft untouched',
      (tester) async {
    final recognizer = _FakeVoiceRecognizer();
    String? insertedTranscript;
    var sheetWasClosed = false;

    await _showSheet(
      tester,
      recognizer,
      (transcript) => insertedTranscript = transcript,
      onClosed: () => sheetWasClosed = true,
    );
    await tester.tap(find.text('Começar a ditar'));
    await tester.pumpAndSettle();
    recognizer.emit('Texto parcial que deve ser descartado', false);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Descartar'));
    await tester.pumpAndSettle();

    expect(insertedTranscript, isNull);
    expect(recognizer.cancelCalls, 1);
    expect(sheetWasClosed, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

Future<void> _showSheet(
  WidgetTester tester,
  _FakeVoiceRecognizer recognizer,
  ValueChanged<String?> onTranscript, {
  VoidCallback? onClosed,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () async {
                final transcript = await showModalBottomSheet<String>(
                  context: context,
                  builder: (_) => VoicePromptSheet(
                    recognizerFactory: () => recognizer,
                  ),
                );
                onTranscript(transcript);
                onClosed?.call();
              },
              child: const Text('Abrir ditado'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Abrir ditado'));
  await tester.pumpAndSettle();
}

class _FakeVoiceRecognizer implements VoiceRecognizer {
  ValueChanged<String>? statusListener;
  ValueChanged<String>? errorListener;
  void Function(String transcript, bool isFinal)? resultListener;
  int initializeCalls = 0;
  int listenCalls = 0;
  int stopCalls = 0;
  int cancelCalls = 0;

  @override
  Future<bool> initialize({
    required ValueChanged<String> onStatus,
    required ValueChanged<String> onError,
  }) async {
    initializeCalls++;
    statusListener = onStatus;
    errorListener = onError;
    return true;
  }

  @override
  Future<void> listen({
    required void Function(String transcript, bool isFinal) onResult,
  }) async {
    listenCalls++;
    resultListener = onResult;
    statusListener?.call('listening');
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    statusListener?.call('done');
  }

  @override
  Future<void> cancel() async {
    cancelCalls++;
  }

  void emit(String transcript, bool isFinal) {
    resultListener?.call(transcript, isFinal);
  }
}
