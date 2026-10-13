import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'models.dart';

class ApiException implements Exception {
  final int status;
  final String message;
  const ApiException(this.status, this.message);
  @override
  String toString() => message;
}

class OpenCodeApi {
  final Machine machine;
  final http.Client client;
  OpenCodeApi(this.machine, {http.Client? client})
      : client = client ?? http.Client();

  void close() => client.close();

  Future<dynamic> request(String method, String path,
      {String? directory, Json? query, Object? body}) async {
    final root = Uri.parse(machine.url);
    final params = <String, String>{
      if (directory != null && directory.isNotEmpty) 'directory': directory,
      ...?query?.map((key, value) => MapEntry(key, value.toString())),
    };
    final uri = root.replace(
        path: path, queryParameters: params.isEmpty ? null : params);
    final request = http.Request(method, uri)..followRedirects = false;
    request.headers['accept'] = 'application/json';
    request.headers['authorization'] =
        'Basic ${base64Encode(utf8.encode('${machine.username}:${machine.password}'))}';
    if (body != null) {
      request.headers['content-type'] = 'application/json';
      request.body = jsonEncode(body);
    }

    final http.Response response;
    try {
      response = await http.Response.fromStream(await client.send(request))
          .timeout(const Duration(seconds: 20));
    } on TimeoutException {
      throw const ApiException(
          0, 'Tempo esgotado. Confira Tailscale e servidor.');
    } on http.ClientException {
      throw const ApiException(0,
          'Sem conexão. Confira a VPN Tailscale, a URL e se o PC está ligado.');
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(
          response.statusCode,
          switch (response.statusCode) {
            401 ||
            403 =>
              'Acesso negado. Confira usuário, senha e regras da tailnet.',
            404 =>
              'Sessão ou endpoint não encontrado neste servidor/diretório.',
            409 => 'A sessão já está executando uma tarefa.',
            >= 300 && < 400 =>
              'Redirecionamento recusado. Cadastre a URL final HTTPS.',
            _ => 'OpenCode respondeu HTTP ${response.statusCode}.',
          });
    }

    if (response.body.trim().isEmpty) {
      return null;
    }
    try {
      return jsonDecode(response.body);
    } on FormatException {
      throw const ApiException(
          0, 'Resposta incompatível com a API HTTP do OpenCode v2.');
    }
  }

  dynamic _data(dynamic response) {
    final envelope = object(response);
    if (!envelope.containsKey('data')) {
      throw const ApiException(0, 'Resposta v2 sem o campo data.');
    }
    return envelope['data'];
  }

  Json _dataObject(dynamic response) {
    final data = _data(response);
    if (data is! Map) {
      throw const ApiException(0, 'Resposta v2 incompatível: esperado objeto.');
    }
    return Map<String, dynamic>.from(data);
  }

  List<Json> _dataObjects(dynamic response) {
    final data = _data(response);
    if (data is! List) {
      throw const ApiException(0, 'Resposta v2 incompatível: esperada lista.');
    }
    return objects(data);
  }

  Future<Json> health() async {
    final info = object(await request('GET', '/api/info'));
    final version = info['version'];
    if (version is! String) {
      throw const ApiException(0, 'O servidor não informou a versão.');
    }
    return {'healthy': true, 'version': version};
  }

  Future<List<Json>> projects() async {
    final response = await request('GET', '/api/project');
    if (response is! List) {
      throw const ApiException(0, 'Resposta v2 incompatível: projetos.');
    }
    return objects(response);
  }

  Future<List<Session>> listDirectory(String directory,
      {String search = '', int limit = 200}) async {
    final raw =
        await request('GET', '/api/session', directory: directory, query: {
      'limit': limit,
      'order': 'desc',
      if (search.isNotEmpty) 'search': search,
    });
    return _dataObjects(raw).map(Session.fromJson).toList();
  }

  Future<SessionPage> listAll({String search = '', String? cursor}) async {
    final query = <String, dynamic>{
      'limit': 100,
      if (search.isNotEmpty) 'search': search,
      if (cursor == null) 'order': 'desc' else 'cursor': cursor,
    };
    final raw = object(await request('GET', '/api/session', query: query));
    final rows = raw['data'];
    if (rows is! List) {
      throw const ApiException(0, 'Listagem de sessões v2 incompatível.');
    }
    final next = object(raw['cursor'])['next'];
    if (next != null && next is! String) {
      throw const ApiException(0, 'Cursor de sessões v2 inválido.');
    }
    return SessionPage(objects(rows).map(Session.fromJson).toList(),
        cursor: next as String?);
  }

  Future<Session> getSession(String id) async => Session.fromJson(_dataObject(
      await request('GET', '/api/session/${Uri.encodeComponent(id)}')));

  Future<Session> createSession(String directory, String title) async =>
      Session.fromJson(_dataObject(await request('POST', '/api/session', body: {
        'title': title,
        'location': {'directory': directory},
      })));

  Future<List<Json>> messages(Session session) async {
    final raw = await request(
        'GET', '/api/session/${Uri.encodeComponent(session.id)}/message',
        query: {'limit': 200, 'order': 'desc'});
    final normalized = <Json>[];
    for (final message in _dataObjects(raw)) {
      final displayMessage = _normalizeMessage(message);
      if (displayMessage != null) {
        normalized.add(displayMessage);
      }
    }
    return normalized.reversed.toList();
  }

  Json? _normalizeMessage(Json message) {
    final type = message['type'];
    if (type == 'idle' ||
        type == 'agent-switched' ||
        type == 'model-switched' ||
        type == 'location-switched') {
      return null;
    }

    final parts = <Json>[];
    var hasReasoning = false;
    if (type == 'user') {
      final text = message['text'];
      if (text is String && text.isNotEmpty) {
        parts.add({'type': 'text', 'text': text});
      }
      for (final file in objects(message['files'])) {
        parts.add({
          'type': 'file',
          'filename': file['name'],
          'mime': file['mime'],
        });
      }
    } else if (type == 'assistant') {
      for (final content in objects(message['content'])) {
        final contentType = content['type'];
        if (contentType == 'tool') {
          parts.add({
            'type': 'tool',
            'tool': content['name'] ?? 'Ferramenta',
            'state': object(content['state']),
          });
        } else if (contentType == 'reasoning') {
          hasReasoning = true;
        } else {
          parts.add(content);
        }
      }
      if (hasReasoning) {
        parts.insert(0, {'type': 'reasoning'});
      }
    } else {
      final text = _messageText(message);
      if (text.isNotEmpty) {
        parts.add({'type': 'text', 'text': text});
      }
    }

    if (parts.isEmpty) {
      return null;
    }
    return {
      'info': {
        'role': type == 'user' ? 'user' : 'assistant',
        if (message['error'] != null) 'error': message['error'],
      },
      'parts': parts,
    };
  }

  String _messageText(Json message) {
    final type = message['type'];
    if (type == 'shell') {
      final output = object(message['output'])['output'];
      return '${message['command'] ?? 'Comando'}\n${output ?? ''}';
    }
    if (type == 'compaction') {
      return message['summary'] as String? ?? 'Contexto da sessão compactado.';
    }
    return message['text'] as String? ??
        message['description'] as String? ??
        '';
  }

  Future<Json> statuses() async =>
      _dataObject(await request('GET', '/api/session/active'));

  Future<List<Json>> agents(String directory) async => _listAgents(directory);

  Future<List<Json>> _listAgents(String directory) async {
    final scopedAgents = _dataObjects(await request('GET', '/api/agent',
        query: {'location[directory]': directory}));
    if (scopedAgents.isNotEmpty) {
      return scopedAgents;
    }
    return _dataObjects(await request('GET', '/api/agent'));
  }

  Future<Json> providers(String directory) async {
    final responses = await Future.wait<dynamic>([
      request('GET', '/api/provider',
          query: {'location[directory]': directory}),
      request('GET', '/api/model', query: {'location[directory]': directory}),
    ]);
    return {
      'providers': _dataObjects(responses[0]),
      'models': _dataObjects(responses[1]),
    };
  }

  Future<void> prompt(Session session, String text,
      {String? agent, Json? model, String? delivery}) async {
    final encodedSessionID = Uri.encodeComponent(session.id);
    if (agent != null) {
      await request('POST', '/api/session/$encodedSessionID/agent',
          body: {'agent': agent});
    }
    if (model != null) {
      await request('POST', '/api/session/$encodedSessionID/model',
          body: {'model': model});
    }
    await request('POST', '/api/session/$encodedSessionID/prompt', body: {
      'text': text,
      if (delivery != null) 'delivery': delivery,
    });
  }

  Future<List<Json>> inbox(Session session) async => _dataObjects(await request(
      'GET', '/api/session/${Uri.encodeComponent(session.id)}/inbox'));

  Future<void> updateInboxDelivery(
      Session session, String id, String delivery) async {
    await request(
        'PATCH',
        '/api/session/${Uri.encodeComponent(session.id)}/inbox/'
            '${Uri.encodeComponent(id)}',
        body: {'delivery': delivery});
  }

  Future<void> cancelInbox(Session session, String id) async {
    await request(
        'DELETE',
        '/api/session/${Uri.encodeComponent(session.id)}/inbox/'
            '${Uri.encodeComponent(id)}');
  }

  Future<void> abort(Session session) async {
    await request(
        'POST', '/api/session/${Uri.encodeComponent(session.id)}/interrupt');
  }

  Future<List<Json>> pending(String kind, Session session) async {
    final resource = kind == 'question' ? 'form' : kind;
    if (resource != 'permission' && resource != 'form') {
      throw const ApiException(0, 'Tipo de solicitação v2 desconhecido.');
    }
    final requests = _dataObjects(await request(
        'GET', '/api/session/${Uri.encodeComponent(session.id)}/$resource'));
    if (resource == 'form') {
      return requests;
    }
    return requests
        .map((permission) => {
              ...permission,
              'permission': permission['action'],
              'patterns': permission['resources'] ?? const <String>[],
            })
        .toList();
  }

  Future<void> permission(Session session, String id, String reply) async {
    await request(
        'POST',
        '/api/session/${Uri.encodeComponent(session.id)}/permission/'
            '${Uri.encodeComponent(id)}/reply',
        body: {'reply': reply});
  }

  Future<List<Json>> mcpServers(String directory) async =>
      _dataObjects(await request('GET', '/api/mcp',
          query: {'location[directory]': directory}));

  Future<void> setMcpConnection(String directory, String name,
      {required bool connect}) async {
    final action = connect ? 'connect' : 'disconnect';
    await request('POST', '/api/mcp/${Uri.encodeComponent(name)}/$action',
        query: {'location[directory]': directory});
  }

  Future<List<Json>> skills(String directory) async =>
      _dataObjects(await request('GET', '/api/skill',
          query: {'location[directory]': directory}));

  Future<void> activateSkill(Session session, String skill) async {
    await request(
        'POST', '/api/session/${Uri.encodeComponent(session.id)}/skill',
        body: {'skill': skill, 'resume': true});
  }

  Future<void> replyForm(Session session, String id, Json answers) async {
    await request(
        'POST',
        '/api/session/${Uri.encodeComponent(session.id)}/form/'
            '${Uri.encodeComponent(id)}/reply',
        body: {'answer': answers});
  }

  Future<dynamic> details(Session session, String kind) async {
    final endpoint = kind == 'diff' ? 'diff' : 'context';
    return _data(await request(
        'GET', '/api/session/${Uri.encodeComponent(session.id)}/$endpoint'));
  }
}
