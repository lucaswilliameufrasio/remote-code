import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_dev/core/models.dart';
import 'package:remote_dev/features/chat.dart';

void main() {
  testWidgets('Should distinguish user messages from assistant output',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              const MessageCard(
                message: {
                  'info': {'role': 'user'},
                  'parts': [
                    {'type': 'text', 'text': 'Revise o fluxo de conexão.'},
                  ],
                },
              ),
              const MessageCard(
                message: {
                  'info': {'role': 'assistant'},
                  'parts': [
                    {'type': 'text', 'text': 'Vou revisar o fluxo.'},
                    {'type': 'reasoning', 'text': 'Private reasoning payload'},
                    {
                      'type': 'tool',
                      'tool': 'Read',
                      'state': {
                        'status': 'completed',
                        'title': 'Leu machine_editor.dart',
                        'output': 'Conteúdo consultado',
                      },
                    },
                  ],
                },
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('VOCÊ'), findsOneWidget);
    expect(find.text('OPENCODE'), findsOneWidget);
    expect(find.text('Revise o fluxo de conexão.'), findsOneWidget);
    expect(find.text('Vou revisar o fluxo.'), findsOneWidget);
    expect(find.text('Private reasoning payload'), findsNothing);
    expect(find.text('Análise do modelo'), findsOneWidget);
    expect(find.text('Leu machine_editor.dart'), findsOneWidget);

    await tester.tap(find.text('Read'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Conteúdo consultado'), findsOneWidget);
  });

  testWidgets('Should filter searchable model choices by their identifiers',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SearchableChoiceSheet(
            title: 'Escolher modelo',
            selectedValue: null,
            defaultLabel: 'Padrão',
            isLoading: false,
            emptyMessage: 'Nenhum modelo disponível.',
            searchHint: 'Buscar modelo',
            optionIcon: Icons.auto_awesome_outlined,
            options: const [
              SearchableOption(
                value: 'openai/gpt-5',
                label: 'OpenAI · GPT-5',
                searchTerms: 'openai/gpt-5',
              ),
              SearchableOption(
                value: 'anthropic/sonnet',
                label: 'Anthropic · Sonnet',
                searchTerms: 'anthropic/sonnet',
              ),
            ],
          ),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), 'gpt-5');
    await tester.pumpAndSettle();

    expect(find.text('OpenAI · GPT-5'), findsOneWidget);
    expect(find.text('Anthropic · Sonnet'), findsNothing);
  });

  testWidgets('Should start at the latest message and show its jump action',
      (tester) async {
    final controller = ScrollController();
    var didJumpToLatest = false;
    final messages = List<Json>.generate(
      12,
      (index) => {
        'info': {'role': 'user'},
        'parts': [
          {'type': 'text', 'text': 'Message $index'},
        ],
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConversationTimeline(
            messages: messages,
            controller: controller,
            showJumpToLatest: true,
            onJumpToLatest: () => didJumpToLatest = true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final list = tester.widget<ListView>(find.byType(ListView));
    expect(list.reverse, isTrue);
    expect(controller.offset, 0);
    expect(find.text('Message 11'), findsOneWidget);
    expect(find.text('Mais recentes'), findsOneWidget);

    await tester.tap(find.text('Mais recentes'));
    await tester.pump();

    expect(didJumpToLatest, isTrue);
    controller.dispose();
  });
}
