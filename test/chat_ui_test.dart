import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:remote_dev/core/api.dart';
import 'package:remote_dev/core/models.dart';
import 'package:remote_dev/core/store.dart';
import 'package:remote_dev/features/chat.dart';
import 'package:remote_dev/features/question_response.dart';

const testMachine = Machine(
  id: 'desktop',
  name: 'Desktop',
  url: 'https://desktop.example.ts.net',
  password: 'unit-test-password',
);

const testSession = Session(
  id: 'ses_test',
  title: 'Test session',
  directory: '/work/project',
);

Future<AppStore> createTestStore() async {
  FlutterSecureStorage.setMockInitialValues({});
  final store = AppStore();
  await store.load();
  return store;
}

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

  testWidgets('Should show full questions and accept custom answers',
      (tester) async {
    const longQuestion =
        'Qual ambiente específico deve receber esta alteração e existe alguma '
        'restrição de horário ou validação que precisamos respeitar antes da publicação?';
    Json? submittedAnswers;
    final form = <String, dynamic>{
      'title': 'Escolha como continuar a publicação',
      'description': 'Responda às perguntas para o agente continuar.',
      'fields': [
        {
          'key': 'environment',
          'type': 'string',
          'title': longQuestion,
          'description': 'Escolha uma opção ou escreva outra resposta.',
          'required': true,
          'options': [
            {'value': 'staging', 'label': 'Ambiente de testes'},
            {'value': 'production', 'label': 'Produção'},
          ],
        },
        {
          'key': 'reason',
          'type': 'string',
          'title': 'Qual validação deve ser feita primeiro?',
          'required': true,
        },
      ],
    };

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () {
                  showModalBottomSheet<Json>(
                    context: context,
                    isScrollControlled: true,
                    useSafeArea: true,
                    showDragHandle: true,
                    builder: (_) => QuestionResponseSheet(form: form),
                  ).then((answers) => submittedAnswers = answers);
                },
                child: const Text('Abrir formulário'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Abrir formulário'));
    await tester.pumpAndSettle();

    expect(find.text(longQuestion), findsOneWidget);
    expect(find.text('1 de 2'), findsOneWidget);
    expect(find.text('Ou escreva sua própria resposta'), findsOneWidget);

    await tester.enterText(
        find.byType(TextFormField), 'Ambiente de homologação');
    await tester.tap(find.text('Próxima pergunta'));
    await tester.pumpAndSettle();

    expect(
        find.text('Qual validação deve ser feita primeiro?'), findsOneWidget);
    await tester.enterText(
        find.byType(TextFormField), 'Rodar a suíte de regressão');
    await tester.tap(find.text('Enviar resposta'));
    await tester.pumpAndSettle();

    expect(submittedAnswers, {
      'environment': 'Ambiente de homologação',
      'reason': 'Rodar a suíte de regressão',
    });
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

  testWidgets('Should surface pending questions and page older chat history',
      (tester) async {
    const questionTitle =
        'Qual ambiente específico deve receber esta alteração e existe alguma '
        'restrição de horário ou validação antes da publicação?';
    final requests = <http.Request>[];
    Json? submittedReply;
    var formWasAnswered = false;
    final api = OpenCodeApi(
      testMachine,
      client: MockClient((request) async {
        requests.add(request);
        final path = request.url.path;
        if (path == '/api/session/ses_test') {
          return http.Response(
            jsonEncode({
              'data': {
                'id': testSession.id,
                'title': testSession.title,
                'location': {'directory': testSession.directory},
              },
            }),
            200,
          );
        }
        if (path == '/api/session/ses_test/message') {
          if (request.url.queryParameters['cursor'] == 'older-cursor') {
            return http.Response(
              jsonEncode({
                'data': [
                  {
                    'id': 'msg_recent_user',
                    'type': 'user',
                    'text': 'Mensagem recente do usuário',
                  },
                  {
                    'id': 'msg_older',
                    'type': 'user',
                    'text': 'Mensagem mais antiga do histórico',
                  },
                ],
                'cursor': {},
              }),
              200,
            );
          }
          return http.Response(
            jsonEncode({
              'data': [
                {
                  'id': 'msg_latest_assistant',
                  'type': 'assistant',
                  'text': 'Resposta mais recente do agente',
                },
                {
                  'id': 'msg_recent_user',
                  'type': 'user',
                  'text': 'Mensagem recente do usuário',
                },
              ],
              'cursor': {'next': 'older-cursor'},
            }),
            200,
          );
        }
        if (path == '/api/session/active') {
          return http.Response(jsonEncode({'data': {}}), 200);
        }
        if (path == '/api/session/ses_test/permission' ||
            path == '/api/session/ses_test/inbox') {
          return http.Response(jsonEncode({'data': []}), 200);
        }
        if (path == '/api/session/ses_test/form') {
          return http.Response(
            jsonEncode({
              'data': formWasAnswered
                  ? []
                  : [
                      {
                        'id': 'form_test',
                        'title': 'Escolha como continuar a publicação',
                        'fields': [
                          {
                            'key': 'environment',
                            'type': 'string',
                            'title': questionTitle,
                            'required': true,
                            'options': [
                              {
                                'value': 'staging',
                                'label': 'Ambiente de testes'
                              },
                              {'value': 'production', 'label': 'Produção'},
                            ],
                          },
                        ],
                      },
                    ],
            }),
            200,
          );
        }
        if (path == '/api/session/ses_test/form/form_test/reply' &&
            request.method == 'POST') {
          submittedReply = jsonDecode(request.body) as Json;
          formWasAnswered = true;
          return http.Response('', 204);
        }
        if (path == '/api/agent') {
          return http.Response(jsonEncode({'data': []}), 200);
        }
        if (path == '/api/provider' || path == '/api/model') {
          return http.Response(jsonEncode({'data': []}), 200);
        }
        return http.Response('Not found', 404);
      }),
    );
    final store = await createTestStore();

    await tester.pumpWidget(
      MaterialApp(
        home: ChatScreen(
          store: store,
          machine: testMachine,
          session: testSession,
          apiOverride: api,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('PRECISA DA SUA ATENÇÃO'), findsOneWidget);
    expect(find.text('Escolha como continuar a publicação'), findsOneWidget);
    expect(find.text(questionTitle), findsOneWidget);
    await tester.ensureVisible(find.text('Responder agora'));
    await tester.tap(find.text('Responder agora'));
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byType(QuestionResponseSheet),
        matching: find.text(questionTitle),
      ),
      findsOneWidget,
    );
    await tester.enterText(
      find.byType(TextFormField),
      'Ambiente de homologação',
    );
    await tester.tap(find.text('Enviar resposta'));
    await tester.pumpAndSettle();

    expect(submittedReply, {
      'answer': {'environment': 'Ambiente de homologação'},
    });
    await tester.tap(find.text('Carregar mensagens anteriores'));
    await tester.pumpAndSettle();

    expect(find.text('Mensagem mais antiga do histórico'), findsOneWidget);
    expect(find.text('Mensagem recente do usuário'), findsOneWidget);
    expect(
      requests.where(
        (request) => request.url.queryParameters['cursor'] == 'older-cursor',
      ),
      hasLength(1),
    );
    final messageRequests = requests
        .where((request) => request.url.path.endsWith('/message'))
        .toList();
    expect(messageRequests.first.url.queryParameters['limit'], '30');
    expect(
      messageRequests.any(
        (request) => request.url.queryParameters['limit'] == '12',
      ),
      isTrue,
    );

    await tester.tap(find.byTooltip('Ações da sessão'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reconectar agora'));
    await tester.pumpAndSettle();
    expect(find.text('Mensagem mais antiga do histórico'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Should update open model and agent sheets as settings load',
      (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    final agentResponse = Completer<http.Response>();
    final modelResponse = Completer<http.Response>();
    final agentRequestStarted = Completer<void>();
    final modelRequestStarted = Completer<void>();
    final api = OpenCodeApi(
      const Machine(
        id: 'desktop',
        name: 'Desktop',
        url: 'https://desktop.example.ts.net',
        password: 'unit-test-password',
      ),
      client: MockClient((request) async {
        final path = request.url.path;
        if (path == '/api/model') {
          if (!modelRequestStarted.isCompleted) {
            modelRequestStarted.complete();
          }
          return modelResponse.future;
        }
        if (path == '/api/agent' &&
            request.url.queryParameters.containsKey('location[directory]')) {
          if (!agentRequestStarted.isCompleted) {
            agentRequestStarted.complete();
          }
          return agentResponse.future;
        }
        if (path == '/api/session/ses_test') {
          return http.Response(
            jsonEncode({
              'data': {
                'id': 'ses_test',
                'title': 'Test session',
                'location': {'directory': '/work/project'},
              },
            }),
            200,
          );
        }
        if (path == '/api/session/ses_test/message' ||
            path == '/api/session/ses_test/permission' ||
            path == '/api/session/ses_test/form' ||
            path == '/api/session/ses_test/inbox') {
          return http.Response(jsonEncode({'data': [], 'cursor': {}}), 200);
        }
        if (path == '/api/session/active') {
          return http.Response(jsonEncode({'data': {}}), 200);
        }
        if (path == '/api/provider') {
          return http.Response(
            jsonEncode({
              'data': [
                {'id': 'mock', 'name': 'Mock Provider'},
              ],
            }),
            200,
          );
        }
        if (path == '/api/agent') {
          return http.Response(jsonEncode({'data': []}), 200);
        }
        return http.Response('Not found', 404);
      }),
    );
    final store = AppStore();
    await store.load();

    await tester.pumpWidget(
      MaterialApp(
        home: ChatScreen(
          store: store,
          machine: const Machine(
            id: 'desktop',
            name: 'Desktop',
            url: 'https://desktop.example.ts.net',
            password: 'unit-test-password',
          ),
          session: const Session(
            id: 'ses_test',
            title: 'Test session',
            directory: '/work/project',
          ),
          apiOverride: api,
        ),
      ),
    );

    await tester.runAsync(() async {
      await Future.wait([
        agentRequestStarted.future,
        modelRequestStarted.future,
      ]);
    });
    await tester.pump();

    await tester.tap(find.text('Modelo anterior'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('Escolher modelo'), findsOneWidget);

    modelResponse.complete(
      http.Response(
        jsonEncode({
          'data': [
            {
              'providerID': 'mock',
              'modelID': 'model-a',
              'name': 'Model A',
              'enabled': true,
            },
          ],
        }),
        200,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Mock Provider · Model A'), findsOneWidget);

    await tester.tap(find.text('Mock Provider · Model A'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Agente padrão'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('Escolher agente'), findsOneWidget);

    agentResponse.complete(
      http.Response(
        jsonEncode({
          'data': [
            {'id': 'plan', 'name': 'Planning agent'},
          ],
        }),
        200,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Planning agent'), findsOneWidget);
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
