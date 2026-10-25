import 'api.dart';
import 'attachments.dart';
import 'models.dart';

/// Adapter for CodeRelay's own Claude protocol, never OpenCode wire endpoints.
class ClaudeCodeApi extends OpenCodeApi {
  ClaudeCodeApi(super.machine, {super.client});

  @override
  Future<String> redeemPairingCode(String code) async {
    throw const ApiException(
        0, 'Pareamento OpenCode não se aplica ao adaptador Claude Code.');
  }

  @override
  Future<dynamic> request(String method, String path,
      {String? directory, Json? query, Object? body}) async {
    if (!path.startsWith('/relay/v1/')) {
      throw const ApiException(
          0, 'Este recurso do OpenCode não está disponível para Claude Code.');
    }
    return super.request(method, path, query: query, body: body);
  }

  Future<dynamic> _relay(String method, String path,
          {Json? query, Object? body}) =>
      request(method, '/relay/v1$path', query: query, body: body);

  Session _session(dynamic value) {
    final data = object(value);
    final id = data['id'];
    final title = data['title'];
    final directory = data['directory'];
    final updated = data['updated'];
    if (id is! String ||
        title is! String ||
        directory is! String ||
        updated is! int ||
        data['external'] is! bool) {
      throw const ApiException(0, 'Sessão Claude Code incompatível.');
    }
    return Session(
        id: id,
        title: title,
        directory: directory,
        updated: updated,
        external: data['external'] == true);
  }

  List<Json> _rows(dynamic value) {
    final data = object(value)['data'];
    if (data is! List || data.any((item) => item is! Map)) {
      throw const ApiException(0, 'Lista Claude Code incompatível.');
    }
    return objects(data);
  }

  @override
  Future<Json> health() async {
    final info = object(await _relay('GET', '/info'));
    if (info['agent'] != 'claude_code' ||
        info['protocol_version'] != 1 ||
        info['healthy'] != true ||
        info['adapter_version'] is! String) {
      throw const ApiException(0,
          'O destino não confirmou um adaptador CodeRelay para Claude Code v1.',
          code: 'INCOMPATIBLE_RESPONSE');
    }
    return {'healthy': true, 'version': info['adapter_version']};
  }

  @override
  Future<SessionPage> listAll(
      {String search = '', String? cursor, int limit = 100}) async {
    final value = object(await _relay('GET', '/sessions', query: {
      'limit': limit.clamp(1, 100),
      if (search.isNotEmpty) 'search': search,
      if (cursor != null) 'cursor': cursor,
    }));
    return SessionPage(_rows(value).map(_session).toList(),
        cursor: value['next_cursor'] as String?,
        warning:
            'Catálogo limitado às 5000 sessões locais mais recentes e às raízes autorizadas.');
  }

  @override
  Future<List<Session>> listDirectory(String directory,
      {String search = '', int limit = 200}) async {
    final value = await _relay('GET', '/sessions', query: {
      'directory': directory,
      'search': search,
      'limit': limit.clamp(1, 100),
    });
    return _rows(value).map(_session).toList();
  }

  @override
  Future<Session> getSession(String id) async =>
      _session(await _relay('GET', '/sessions/${Uri.encodeComponent(id)}'));

  @override
  Future<Session> createSession(String directory, String title) async =>
      _session(await _relay('POST', '/sessions',
          body: {'directory': directory, 'title': title}));

  @override
  Future<Session> forkSession(Session session) async => _session(await _relay(
      'POST', '/sessions/${Uri.encodeComponent(session.id)}/fork',
      body: {'confirm_shared_files': true}));

  @override
  Future<List<OpenCodeProject>> projects() async =>
      _rows(await _relay('GET', '/projects'))
          .map((entry) => OpenCodeProject(
              id: entry['id'] as String,
              worktree: entry['directory'] as String))
          .toList();

  @override
  Future<List<String>> allowedFileRoots({String directory = ''}) async =>
      (await projects())
          .map((project) => project.worktree)
          .whereType<String>()
          .toList();

  @override
  Future<MessagePage> messages(Session session,
      {int limit = 30, String? cursor}) async {
    final response = object(await _relay(
        'GET', '/sessions/${Uri.encodeComponent(session.id)}/messages',
        query: {
          'limit': limit.clamp(1, 100),
          if (cursor != null) 'cursor': cursor,
        }));
    return MessagePage([
      for (final message in _rows(response))
        {
          'info': {'id': message['id'], 'role': message['role']},
          'parts': message['parts'],
        }
    ], cursor: response['next_cursor'] as String?);
  }

  @override
  Future<Json> statuses() async {
    final active = object(object(await _relay('GET', '/active'))['data']);
    return {
      for (final entry in active.entries) entry.key: {'type': entry.value}
    };
  }

  @override
  Future<List<Json>> agents(String directory) async => [];

  @override
  Future<Json> providers(String directory) async => {
        'providers': [
          {'id': 'claude_code', 'name': 'Claude Code'}
        ],
        'models': [
          for (final model in ['sonnet', 'opus', 'haiku'])
            {
              'providerID': 'claude_code',
              'modelID': model,
              'name': model,
              'enabled': true,
            }
        ],
      };

  @override
  Future<void> prompt(Session session, String text,
      {String? agent,
      Json? model,
      String? delivery,
      List<PromptAttachment> attachments = const [],
      String? messageID}) async {
    if (session.external ||
        agent != null ||
        delivery != null ||
        attachments.isNotEmpty ||
        messageID == null) {
      throw const ApiException(0,
          'Claude Code exige uma continuação gerenciada e um ID de envio; fila, agentes e anexos não são suportados.');
    }
    final receipt = object(await _relay(
        'POST', '/sessions/${Uri.encodeComponent(session.id)}/prompts',
        body: {
          'id': messageID,
          'text': text,
          if (model != null) 'model': model['id'],
        }));
    if (receipt['id'] != messageID) {
      throw const ApiException(0, 'O adaptador não confirmou o ID do prompt.');
    }
  }

  @override
  Future<bool> promptReceived(Session session, String messageID) async {
    try {
      final receipt = object(await _relay('GET',
          '/sessions/${Uri.encodeComponent(session.id)}/receipts/${Uri.encodeComponent(messageID)}'));
      return receipt['id'] == messageID;
    } on ApiException catch (exception) {
      if (exception.status == 404) {
        return false;
      }
      rethrow;
    }
  }

  @override
  Future<List<Json>> inbox(Session session) async => [];

  List<Json> _requests(dynamic response) => [
        for (final entry in _rows(response))
          {...entry, 'sessionID': entry['session_id']}
      ];

  @override
  Future<List<Json>> pending(String kind, Session session) async =>
      _requests(await _relay(
          'GET', '/sessions/${Uri.encodeComponent(session.id)}/requests',
          query: {'kind': kind}));

  @override
  Future<List<Json>> pendingForLocation(String kind,
          {String? directory}) async =>
      _requests(await _relay('GET', '/requests', query: {
        'kind': kind,
        if (directory != null) 'directory': directory,
      }));

  @override
  Future<void> permission(Session session, String id, String reply) async {
    if (reply != 'once' && reply != 'reject') {
      throw const ApiException(
          0, 'Claude Code aceita apenas aprovações por uso.');
    }
    await _relay('POST',
        '/sessions/${Uri.encodeComponent(session.id)}/requests/${Uri.encodeComponent(id)}/reply',
        body: {'reply': reply});
  }

  @override
  Future<void> replyForm(Session session, String id, Json answers) async {
    await _relay('POST',
        '/sessions/${Uri.encodeComponent(session.id)}/requests/${Uri.encodeComponent(id)}/reply',
        body: {'answers': answers});
  }

  @override
  Future<void> abort(Session session) async {
    await _relay(
        'POST', '/sessions/${Uri.encodeComponent(session.id)}/interrupt');
  }
}
