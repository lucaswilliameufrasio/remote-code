import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'models.dart';
import 'attachments.dart';
import 'remote_files.dart';
import 'file_changes.dart';
import 'claude_api.dart';

class ApiException implements Exception {
  final int status;
  final String message;
  final String? code;
  const ApiException(this.status, this.message, {this.code});
  @override
  String toString() => message;
}

typedef OpenCodeApiFactory = OpenCodeApi Function(Machine machine);

class OpenCodeApi {
  final Machine machine;
  final http.Client client;
  OpenCodeApi(this.machine, {http.Client? client})
      : client = client ?? http.Client();

  static OpenCodeApi create(Machine machine, {http.Client? client}) {
    if (machine.backend == AgentBackend.claudeCode) {
      return ClaudeCodeApi(machine, client: client);
    }
    return OpenCodeApi(machine, client: client);
  }

  Future<Session> forkSession(Session session) async {
    throw const ApiException(
        0, 'Continuação separada não disponível neste agente.');
  }

  void close() => client.close();

  Future<List<String>> allowedFileRoots({String directory = ''}) async {
    final output = await _restrictedFiles('roots', directory, {});
    final roots = output['data'];
    if (roots is! List ||
        roots.length > 16 ||
        roots.any((root) =>
            root is! String ||
            !root.startsWith('/') ||
            root.split('/').contains('..') ||
            root.contains('\\'))) {
      throw const ApiException(
          0, 'O host não informou uma lista válida de raízes autorizadas.',
          code: 'INCOMPATIBLE_RESPONSE');
    }
    return roots.whereType<String>().toList();
  }

  Future<List<RemoteFileEntry>> listRemoteFiles(String directory,
      {String path = ''}) async {
    _checkFilePath(path, allowRoot: true);
    return _remoteEntries(
        await _restrictedFiles('list', directory, {'path': path}));
  }

  Future<List<RemoteFileEntry>> findRemoteFiles(String directory, String query,
          {bool directoriesOnly = false}) async =>
      _remoteEntries(await _restrictedFiles('find', directory,
          {'query': query, 'directories_only': directoriesOnly}));

  Future<RemoteFilePreview> readRemoteFile(
      String directory, String path) async {
    _checkFilePath(path);
    final output = await _restrictedFiles('read', directory, {'path': path});
    final text = output['text'];
    final truncated = output['truncated'];
    if (text is! String ||
        truncated is! bool ||
        utf8.encode(text).length > filePreviewLimit) {
      throw const ApiException(
          0, 'Prévia inválida recebida do explorador restrito.');
    }
    return RemoteFilePreview(text, truncated: truncated);
  }

  Future<Json> _restrictedFiles(
      String method, String directory, Json input) async {
    try {
      final result = object(await request(
          'POST', '/api/rpc/remote-code-files-v1/$method',
          query: {if (directory.isNotEmpty) 'location[directory]': directory},
          body: {'input': input}));
      final output = result['output'];
      if (output is! Map) {
        throw const ApiException(
            0, 'Explorador restrito respondeu com formato incompatível.',
            code: 'INCOMPATIBLE_RESPONSE');
      }
      return Map<String, dynamic>.from(output);
    } on ApiException catch (exception) {
      if (exception.code == 'FILES_PLUGIN_UNAVAILABLE' ||
          exception.status == 404) {
        throw const ApiException(404,
            'Instale a extensão Remote Code File Browser e configure as raízes no host. Não há fallback para navegação irrestrita.');
      }
      final fileMessage = switch (exception.code) {
        'FILES_BINARY' => 'Visualização disponível somente para texto UTF-8.',
        'FILES_LIMIT' =>
          'Limite do explorador atingido. Use uma pasta menor ou uma busca mais específica.',
        'FILES_NOT_FOUND' => 'Arquivo ou pasta não encontrado no host.',
        'FILES_BUSY' ||
        'FILES_UNAVAILABLE' =>
          'Explorador do host ocupado ou indisponível. Tente novamente.',
        _ => null,
      };
      if (fileMessage != null) {
        throw ApiException(exception.status, fileMessage, code: exception.code);
      }
      if (exception.status == 400 || exception.status == 403) {
        throw ApiException(exception.status,
            'O host recusou a operação. Confira as raízes autorizadas, links simbólicos, tipo e limites do arquivo.');
      }
      rethrow;
    }
  }

  Future<String> redeemPairingCode(String code) async {
    final root = Uri.tryParse(machine.url);
    if (root == null ||
        root.scheme != 'https' ||
        root.host.isEmpty ||
        root.userInfo.isNotEmpty ||
        root.hasQuery ||
        root.hasFragment ||
        (root.path.isNotEmpty && root.path != '/')) {
      throw const ApiException(0,
          'O pareamento exige a URL HTTPS da máquina, sem caminho ou credenciais.');
    }
    if (code.isEmpty ||
        code.length > 256 ||
        code.contains(RegExp(r'[^A-Za-z0-9_-]'))) {
      throw const ApiException(
          0, 'Cole somente o código temporário informado pelo OpenCode.');
    }
    final pairRequest = http.Request(
        'GET', root.replace(pathSegments: ['auth', 'connect', code]))
      ..followRedirects = false;
    pairRequest.headers['accept'] = 'application/json';
    final http.Response response;
    try {
      response = await http.Response.fromStream(await client.send(pairRequest))
          .timeout(const Duration(seconds: 20));
    } on TimeoutException {
      throw const ApiException(0,
          'Pareamento sem confirmação. O código pode ter sido consumido; gere outro no PC antes de tentar novamente.');
    } on http.ClientException {
      throw const ApiException(0,
          'Conexão interrompida no pareamento. Gere outro código no PC se necessário.');
    }
    if (response.statusCode != 200) {
      throw ApiException(response.statusCode,
          'Pareamento recusado ou indisponível. Confira o servidor e gere outro código temporário no PC.');
    }
    String token;
    try {
      final value = object(jsonDecode(response.body))['token'];
      if (value is! String || value.isEmpty) {
        throw const FormatException();
      }
      token = value;
    } on FormatException {
      throw const ApiException(0,
          'Resposta de pareamento incompatível. Nenhuma credencial foi salva.');
    }
    final pairedApi = OpenCodeApi(
        Machine(
            id: machine.id,
            name: machine.name,
            url: machine.url,
            username: machine.username,
            password: token),
        client: client);
    final info = await pairedApi.health();
    final version = info['version'];
    if (version is! String || !version.startsWith('2.')) {
      throw const ApiException(
          0, 'Pareamento recebido, mas o servidor não confirmou OpenCode v2.');
    }
    return token;
  }

  Future<List<RemoteFileEntry>> listNativeRemoteFiles(String directory,
      {String path = ''}) async {
    _checkFilePath(path, allowRoot: true);
    return _remoteEntries(await request('GET', '/api/fs/list', query: {
      'location[directory]': directory,
      if (path.isNotEmpty) 'path': path,
    }));
  }

  Future<List<RemoteFileEntry>> findNativeRemoteFiles(
      String directory, String query,
      {bool directoriesOnly = false}) async {
    return _remoteEntries(await request('GET', '/api/fs/find', query: {
      'location[directory]': directory,
      'query': query,
      'limit': '100',
      if (directoriesOnly) 'type': 'directory',
    }));
  }

  List<RemoteFileEntry> _remoteEntries(dynamic response) {
    final entries = <RemoteFileEntry>[];
    for (final entry in _dataObjects(response)) {
      final path = entry['path'];
      final type = entry['type'];
      if (path is! String || (type != 'file' && type != 'directory')) {
        throw const ApiException(
            0, 'Lista de arquivos incompatível com a API v2.');
      }
      if (isProjectRelativePath(path)) {
        entries
            .add(RemoteFileEntry(path: path, isDirectory: type == 'directory'));
      }
    }
    entries.sort((first, second) {
      if (first.isDirectory != second.isDirectory) {
        return first.isDirectory ? -1 : 1;
      }
      return first.path.toLowerCase().compareTo(second.path.toLowerCase());
    });
    return entries;
  }

  void _checkFilePath(String path, {bool allowRoot = false}) {
    if (!isProjectRelativePath(path, allowRoot: allowRoot)) {
      throw const ApiException(
          0, 'Escolha um caminho relativo dentro do projeto.');
    }
  }

  static const filePreviewLimit = 256 * 1024;

  Future<RemoteFilePreview> readNativeRemoteFile(
      String directory, String path) async {
    _checkFilePath(path);
    final uri = Uri.parse(machine.url).replace(
      pathSegments: ['api', 'fs', 'read', ...path.split('/')],
      queryParameters: {'location[directory]': directory},
    );
    final fileRequest = http.Request('GET', uri)..followRedirects = false;
    fileRequest.headers.addAll({
      'authorization':
          'Basic ${base64Encode(utf8.encode('${machine.username}:${machine.password}'))}',
      'accept': 'application/octet-stream',
      'range': 'bytes=0-$filePreviewLimit',
    });
    try {
      final response =
          await client.send(fileRequest).timeout(const Duration(seconds: 20));
      if (response.statusCode != 200 && response.statusCode != 206) {
        await response.stream.listen((_) {}).cancel();
        throw ApiException(
            response.statusCode,
            switch (response.statusCode) {
              401 || 403 => 'Acesso ao arquivo negado pelo servidor.',
              404 =>
                'Arquivo ou recurso de leitura não encontrado neste servidor.',
              _ =>
                'Não foi possível ler o arquivo (HTTP ${response.statusCode}).',
            });
      }
      final bytes = BytesBuilder(copy: false);
      var truncated = false;
      final chunks = StreamIterator<List<int>>(response.stream);
      final elapsed = Stopwatch()..start();
      try {
        while (true) {
          final remainingTime = const Duration(seconds: 20) - elapsed.elapsed;
          if (remainingTime <= Duration.zero) {
            throw TimeoutException('File preview deadline exceeded');
          }
          if (!await chunks.moveNext().timeout(remainingTime)) {
            break;
          }
          final chunk = chunks.current;
          final remaining = filePreviewLimit - bytes.length;
          if (chunk.length > remaining) {
            bytes.add(chunk.sublist(0, remaining));
            truncated = true;
            break;
          }
          bytes.add(chunk);
        }
      } finally {
        await chunks.cancel();
      }
      final range = response.headers['content-range'];
      final totalBytes =
          range == null ? null : int.tryParse(range.split('/').last);
      truncated =
          truncated || (totalBytes != null && totalBytes > bytes.length);
      final content = bytes.takeBytes();
      if (content.contains(0)) {
        throw const ApiException(
            0, 'Arquivo binário: visualização de texto indisponível.');
      }
      String? text;
      for (var trim = 0;
          trim <= (truncated ? 3 : 0) && trim <= content.length;
          trim++) {
        try {
          text = utf8.decode(content.sublist(0, content.length - trim));
          break;
        } on FormatException {
          continue;
        }
      }
      if (text == null ||
          text.runes.any((character) =>
              character < 9 || (character > 13 && character < 32))) {
        throw const ApiException(
            0, 'Visualização disponível somente para texto UTF-8.');
      }
      return RemoteFilePreview(text, truncated: truncated);
    } on TimeoutException {
      throw const ApiException(
          0, 'Tempo esgotado ao ler o arquivo. Tente novamente.');
    } on http.ClientException {
      throw const ApiException(
          0, 'Conexão interrompida durante a leitura do arquivo.');
    }
  }

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
          0, 'Tempo esgotado. Confira Tailscale e servidor.',
          code: 'TIMEOUT');
    } on HandshakeException {
      throw const ApiException(
          0, 'Falha na conexão TLS. Confira o certificado e a URL HTTPS.',
          code: 'TLS_FAILURE');
    } on http.ClientException catch (exception) {
      if (exception is SocketException) {
        throw const ApiException(
            0, 'Servidor inacessível. Confira rede, VPN, DNS e porta.',
            code: 'NETWORK_UNREACHABLE');
      }
      throw const ApiException(0,
          'Sem conexão. Confira a VPN Tailscale, a URL e se o PC está ligado.',
          code: 'NETWORK_FAILURE');
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
            _ =>
              '${machine.backend.label} respondeu HTTP ${response.statusCode}.',
          },
          code: _fileErrorCode(response.body));
    }

    if (response.body.trim().isEmpty) {
      return null;
    }
    try {
      return jsonDecode(response.body);
    } on FormatException {
      throw const ApiException(
          0, 'Resposta incompatível com a API do agente selecionado.',
          code: 'INCOMPATIBLE_RESPONSE');
    }
  }

  String? _fileErrorCode(String body) {
    try {
      final error = object(jsonDecode(body));
      if (error['_tag'] != 'RpcError') {
        return null;
      }
      if (error['type'] == 'rpc.unavailable') {
        return 'FILES_PLUGIN_UNAVAILABLE';
      }
      final code = object(error['data'])['code'];
      return code is String &&
              const {
                'FILES_DENIED',
                'FILES_BINARY',
                'FILES_NOT_FOUND',
                'FILES_LIMIT',
                'FILES_INVALID',
                'FILES_BUSY',
                'FILES_UNAVAILABLE',
                'FILES_CANCELLED',
              }.contains(code)
          ? code
          : null;
    } on FormatException {
      return null;
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
      throw const ApiException(0, 'O servidor não informou a versão.',
          code: 'INCOMPATIBLE_RESPONSE');
    }
    return {'healthy': true, 'version': version};
  }

  Future<List<OpenCodeProject>> projects() async {
    final response = await request('GET', '/api/project');
    if (response is! List) {
      throw const ApiException(0, 'Resposta v2 incompatível: projetos.');
    }
    final projects = <OpenCodeProject>[];
    for (final project in objects(response)) {
      if (project['id'] is String && (project['id'] as String).isNotEmpty) {
        projects.add(OpenCodeProject.fromJson(project));
      }
    }
    return projects;
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

  Future<SessionPage> listAll({
    String search = '',
    String? cursor,
    int limit = 100,
  }) async {
    final query = <String, dynamic>{
      'limit': limit,
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

  Future<MessagePage> messages(Session session,
      {int limit = 30, String? cursor}) async {
    final raw = object(await request(
        'GET', '/api/session/${Uri.encodeComponent(session.id)}/message',
        query: {
          'limit': limit,
          if (cursor == null) 'order': 'desc',
          if (cursor != null) 'cursor': cursor,
        }));
    final normalized = <Json>[];
    for (final message in _dataObjects(raw)) {
      final displayMessage = _normalizeMessage(message);
      if (displayMessage != null) {
        normalized.add(displayMessage);
      }
    }
    final nextCursor = object(raw['cursor'])['next'];
    if (nextCursor != null && nextCursor is! String) {
      throw const ApiException(0, 'Cursor de mensagens v2 inválido.');
    }
    return MessagePage(normalized.reversed.toList(),
        cursor: nextCursor as String?);
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
        if (message['id'] is String) 'id': message['id'],
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
      {String? agent,
      Json? model,
      String? delivery,
      List<PromptAttachment> attachments = const [],
      String? messageID}) async {
    PromptAttachment.validateBatch(attachments);
    final encodedSessionID = Uri.encodeComponent(session.id);
    if (agent != null) {
      await request('POST', '/api/session/$encodedSessionID/agent',
          body: {'agent': agent});
    }
    if (model != null) {
      await request('POST', '/api/session/$encodedSessionID/model',
          body: {'model': model});
    }
    final acknowledgement =
        await request('POST', '/api/session/$encodedSessionID/prompt', body: {
      'text': text,
      if (messageID != null) 'id': messageID,
      if (attachments.isNotEmpty)
        'files': attachments.map((attachment) => attachment.toJson()).toList(),
      if (delivery != null) 'delivery': delivery,
    });
    if (messageID != null) {
      final admitted = _dataObject(acknowledgement);
      if (admitted['id'] != messageID || admitted['type'] != 'user') {
        throw const ApiException(0,
            'O servidor não confirmou o ID do prompt. Confira o recebimento antes de reenviar.');
      }
    }
  }

  Future<bool> promptReceived(Session session, String messageID) async {
    try {
      final message = _dataObject(await request('GET',
          '/api/session/${Uri.encodeComponent(session.id)}/message/${Uri.encodeComponent(messageID)}'));
      if (message['id'] == messageID && message['type'] == 'user') {
        return true;
      }
      throw const ApiException(
          0, 'O servidor não confirmou o identificador da mensagem enviada.');
    } on ApiException catch (exception) {
      if (exception.status != 404) {
        rethrow;
      }
    }
    final pending = await inbox(session);
    return pending
        .any((entry) => entry['id'] == messageID && entry['type'] == 'user');
  }

  Future<Json> attachmentModel(Session session, {Json? selectedModel}) async {
    Json reference;
    if (selectedModel != null) {
      reference = selectedModel;
    } else {
      final currentSession = _dataObject(await request(
        'GET',
        '/api/session/${Uri.encodeComponent(session.id)}',
      ));
      reference = object(currentSession['model']);
    }
    if (reference.isEmpty) {
      final data = _data(await request('GET', '/api/model/default', query: {
        'location[directory]': session.directory,
      }));
      if (data is Map) {
        return Map<String, dynamic>.from(data);
      }
    } else {
      final availableModels =
          _dataObjects(await request('GET', '/api/model', query: {
        'location[directory]': session.directory,
      }));
      for (final model in availableModels) {
        if (model['modelID'] == reference['id'] &&
            model['providerID'] == reference['providerID']) {
          return model;
        }
      }
    }
    throw const ApiException(0,
        'Não foi possível confirmar a compatibilidade do modelo com os anexos. Escolha um modelo e tente novamente.');
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

  Future<List<Json>> pendingForLocation(
    String kind, {
    String? directory,
  }) async {
    final resource = switch (kind) {
      'question' => 'form',
      'permission' => 'permission/request',
      _ => throw const ApiException(0, 'Tipo de solicitação v2 desconhecido.'),
    };
    final requests = _dataObjects(
      await request(
        'GET',
        '/api/$resource',
        query: {
          if (directory != null && directory.isNotEmpty)
            'location[directory]': directory,
        },
      ),
    );
    if (kind == 'question') {
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

  Future<List<FileChange>> sessionChanges(Session session) async {
    final entries = _dataObjects(await request(
        'GET', '/api/session/${Uri.encodeComponent(session.id)}/diff',
        query: {'context': '3'}));
    final changes = <FileChange>[];
    for (final entry in entries) {
      final file = entry['file'];
      final patch = entry['patch'];
      final status = entry['status'];
      final additions = entry['additions'];
      final deletions = entry['deletions'];
      if (file is! String ||
          patch is! String ||
          (status != 'added' && status != 'deleted' && status != 'modified') ||
          additions is! int ||
          deletions is! int ||
          additions < 0 ||
          deletions < 0) {
        throw const ApiException(0, 'Diff incompatível com a API OpenCode v2.');
      }
      changes.add(FileChange(
          file: file,
          patch: patch,
          status: status as String,
          additions: additions,
          deletions: deletions));
    }
    return changes;
  }
}
