import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'design.dart';

enum VoicePromptState { ready, starting, listening, reviewing, failed }

abstract interface class VoiceRecognizer {
  Future<bool> initialize({
    required ValueChanged<String> onStatus,
    required ValueChanged<String> onError,
  });

  Future<void> listen({
    required void Function(String transcript, bool isFinal) onResult,
  });

  Future<void> stop();

  Future<void> cancel();
}

class PlatformVoiceRecognizer implements VoiceRecognizer {
  final SpeechToText speech;

  PlatformVoiceRecognizer({SpeechToText? speech})
      : speech = speech ?? SpeechToText();

  @override
  Future<bool> initialize({
    required ValueChanged<String> onStatus,
    required ValueChanged<String> onError,
  }) {
    return speech.initialize(
      onStatus: onStatus,
      onError: (error) => onError(error.errorMsg),
    );
  }

  @override
  Future<void> listen({
    required void Function(String transcript, bool isFinal) onResult,
  }) async {
    await speech.listen(
      onResult: (result) =>
          onResult(result.recognizedWords, result.finalResult),
      listenOptions: SpeechListenOptions(
        cancelOnError: true,
        partialResults: true,
        listenMode: ListenMode.dictation,
        pauseFor: const Duration(seconds: 4),
        listenFor: const Duration(seconds: 60),
        autoPunctuation: true,
      ),
    );
  }

  @override
  Future<void> stop() => speech.stop();

  @override
  Future<void> cancel() => speech.cancel();
}

class VoicePromptSheet extends StatefulWidget {
  final VoiceRecognizer Function() recognizerFactory;

  const VoicePromptSheet({
    super.key,
    this.recognizerFactory = PlatformVoiceRecognizer.new,
  });

  @override
  State<VoicePromptSheet> createState() => _VoicePromptSheetState();
}

class _VoicePromptSheetState extends State<VoicePromptSheet> {
  late final VoiceRecognizer recognizer;
  late final TextEditingController transcriptController;
  VoicePromptState state = VoicePromptState.ready;
  String? errorMessage;
  bool recognitionStarted = false;

  @override
  void initState() {
    super.initState();
    recognizer = widget.recognizerFactory();
    transcriptController = TextEditingController();
    transcriptController.addListener(_transcriptChanged);
  }

  @override
  void dispose() {
    transcriptController.removeListener(_transcriptChanged);
    transcriptController.dispose();
    if (recognitionStarted) {
      recognizer.cancel();
    }
    super.dispose();
  }

  Future<void> _startRecognition() async {
    setState(() {
      state = VoicePromptState.starting;
      errorMessage = null;
    });

    try {
      final initialized = await recognizer.initialize(
        onStatus: _onRecognitionStatus,
        onError: _onRecognitionError,
      );
      if (!mounted) {
        return;
      }
      if (!initialized) {
        setState(() {
          state = VoicePromptState.failed;
          errorMessage =
              'O reconhecimento de voz não está disponível. Confira as permissões e tente novamente.';
        });
        return;
      }

      recognitionStarted = true;
      await recognizer.listen(onResult: _onRecognitionResult);
      if (!mounted) {
        await recognizer.cancel();
        recognitionStarted = false;
        return;
      }
      if (mounted && state == VoicePromptState.starting) {
        setState(() => state = VoicePromptState.listening);
      }
    } catch (_) {
      var couldNotCancel = false;
      if (recognitionStarted) {
        try {
          await recognizer.cancel();
        } catch (_) {
          couldNotCancel = true;
        }
      }
      recognitionStarted = false;
      if (mounted) {
        setState(() {
          state = VoicePromptState.failed;
          errorMessage = couldNotCancel
              ? 'O reconhecimento não pôde ser encerrado. Feche esta janela e verifique as permissões do dispositivo.'
              : errorMessage ??
                  'Não foi possível iniciar o reconhecimento de voz. Verifique a conexão e as permissões do dispositivo.';
        });
      }
    }
  }

  void _onRecognitionStatus(String status) {
    if (!mounted) {
      return;
    }
    if (status == 'listening') {
      setState(() => state = VoicePromptState.listening);
    } else if (status == 'done' || status == 'notListening') {
      recognitionStarted = false;
      if (state == VoicePromptState.listening) {
        setState(() => state = VoicePromptState.reviewing);
      }
    }
  }

  void _onRecognitionError(String error) {
    if (!mounted) {
      return;
    }
    final lowerCaseError = error.toLowerCase();
    final message = lowerCaseError.contains('permission')
        ? 'Permita o acesso ao microfone e ao reconhecimento de voz nas configurações do dispositivo.'
        : lowerCaseError.contains('no_match')
            ? 'Nenhuma fala foi reconhecida. Tente novamente ou descarte o ditado.'
            : 'O reconhecimento de voz foi interrompido. Revise o texto ou tente novamente.';
    setState(() {
      state = VoicePromptState.failed;
      errorMessage = message;
    });
    recognitionStarted = false;
  }

  void _onRecognitionResult(String recognizedWords, bool isFinal) {
    if (!mounted) {
      return;
    }
    transcriptController.value = TextEditingValue(
      text: recognizedWords,
      selection: TextSelection.collapsed(offset: recognizedWords.length),
    );
    if (isFinal) {
      setState(() => state = VoicePromptState.reviewing);
    }
  }

  void _transcriptChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _stopRecognition() async {
    if (!recognitionStarted) {
      setState(() => state = VoicePromptState.reviewing);
      return;
    }
    await recognizer.stop();
    recognitionStarted = false;
    if (mounted) {
      setState(() => state = VoicePromptState.reviewing);
    }
  }

  Future<void> _cancelAndClose() async {
    if (recognitionStarted) {
      await recognizer.cancel();
      recognitionStarted = false;
    }
    if (mounted) {
      Navigator.pop(context);
    }
  }

  void _insertTranscript() {
    final transcript = transcriptController.text.trim();
    if (transcript.isNotEmpty) {
      Navigator.pop(context, transcript);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          22,
          18,
          22,
          MediaQuery.viewInsetsOf(context).bottom + 20,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.mic_none, color: AppColors.accent),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Ditar prompt',
                    style: Theme.of(context)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  tooltip: 'Descartar ditado',
                  onPressed: _cancelAndClose,
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'O reconhecimento do dispositivo pode usar serviços de rede. O CodeRelay não envia gravações ao OpenCode: você revisa o texto e só então escolhe enviá-lo.',
            ),
            if (errorMessage != null) ...[
              const SizedBox(height: 14),
              Text(
                errorMessage!,
                style: const TextStyle(color: AppColors.warning),
              ),
            ],
            if (state == VoicePromptState.listening ||
                state == VoicePromptState.reviewing ||
                state == VoicePromptState.failed) ...[
              const SizedBox(height: 16),
              TextField(
                controller: transcriptController,
                autofocus: true,
                minLines: 3,
                maxLines: 7,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Revise o texto reconhecido',
                  alignLabelWithHint: true,
                ),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                OutlinedButton(
                  onPressed: _cancelAndClose,
                  child: const Text('Descartar'),
                ),
                const Spacer(),
                if (state == VoicePromptState.failed &&
                    transcriptController.text.trim().isNotEmpty) ...[
                  TextButton(
                    onPressed: _startRecognition,
                    child: const Text('Tentar novamente'),
                  ),
                  const SizedBox(width: 6),
                  FilledButton.icon(
                    onPressed: _insertTranscript,
                    icon: const Icon(Icons.edit_note),
                    label: const Text('Inserir texto'),
                  ),
                ] else if (state == VoicePromptState.ready ||
                    state == VoicePromptState.failed) ...[
                  FilledButton.icon(
                    onPressed: _startRecognition,
                    icon: const Icon(Icons.mic),
                    label: Text(
                      state == VoicePromptState.failed
                          ? 'Tentar novamente'
                          : 'Começar a ditar',
                    ),
                  ),
                ] else if (state == VoicePromptState.starting) ...[
                  const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ] else if (state == VoicePromptState.listening) ...[
                  FilledButton.icon(
                    onPressed: _stopRecognition,
                    icon: const Icon(Icons.stop),
                    label: const Text('Finalizar'),
                  ),
                ] else ...[
                  FilledButton.icon(
                    onPressed: transcriptController.text.trim().isEmpty
                        ? null
                        : _insertTranscript,
                    icon: const Icon(Icons.edit_note),
                    label: const Text('Inserir no rascunho'),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

TextEditingValue insertDictation(
  TextEditingValue currentValue,
  String transcript,
) {
  final recognizedText = transcript.trim();
  if (recognizedText.isEmpty) {
    return currentValue;
  }

  final currentText = currentValue.text;
  final selection = currentValue.selection;
  final validSelection = selection.isValid &&
      selection.start >= 0 &&
      selection.end >= 0 &&
      selection.start <= currentText.length &&
      selection.end <= currentText.length;
  final start = validSelection ? selection.start : currentText.length;
  final end = validSelection ? selection.end : currentText.length;
  final before = currentText.substring(0, start);
  final after = currentText.substring(end);
  final leadingSpace = before.isNotEmpty && !RegExp(r'\s$').hasMatch(before);
  final trailingSpace = after.isNotEmpty && !RegExp(r'^\s').hasMatch(after);
  final insertedText =
      '${leadingSpace ? ' ' : ''}$recognizedText${trailingSpace ? ' ' : ''}';
  final updatedText = '$before$insertedText$after';
  final cursor = before.length + insertedText.length;
  return TextEditingValue(
    text: updatedText,
    selection: TextSelection.collapsed(offset: cursor),
  );
}
