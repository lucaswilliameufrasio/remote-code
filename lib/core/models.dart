import 'dart:convert';

typedef Json = Map<String, dynamic>;
Json object(dynamic value) =>
    value is Map ? Map<String, dynamic>.from(value) : {};
List<Json> objects(dynamic value) => (value is List ? value : const [])
    .whereType<Map>()
    .map((v) => Map<String, dynamic>.from(v))
    .toList();

class Machine {
  final String id, name, url, username, password;
  final List<String> directories;
  const Machine(
      {required this.id,
      required this.name,
      required this.url,
      this.username = 'opencode',
      required this.password,
      this.directories = const []});
  factory Machine.fromJson(Json j) => Machine(
      id: j['id'],
      name: j['name'],
      url: j['url'],
      username: j['username'] ?? 'opencode',
      password: j['password'] ?? '',
      directories: List<String>.from(j['directories'] ?? []));
  Json toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'username': username,
        'password': password,
        'directories': directories
      };
  Machine withDirectory(String directory) => Machine(
      id: id,
      name: name,
      url: url,
      username: username,
      password: password,
      directories:
          {...directories, directory}.where((d) => d.isNotEmpty).toList());
}

class Session {
  final String id, title, directory;
  final int updated;
  final String? parentID;
  const Session(
      {required this.id,
      required this.title,
      required this.directory,
      this.updated = 0,
      this.parentID});
  factory Session.fromJson(Json j) => Session(
      id: j['id'] as String,
      title: (j['title'] as String?) ?? 'Sessão sem título',
      directory: (object(j['location'])['directory'] as String?) ??
          (j['directory'] as String?) ??
          '',
      updated: (object(j['time'])['updated'] as num?)?.toInt() ?? 0,
      parentID: j['parentID'] as String?);
  Json toJson() => {
        'id': id,
        'title': title,
        'directory': directory,
        'time': {'updated': updated},
        'parentID': parentID
      };
}

class Bookmark {
  final String machineID;
  final Session session;
  final int opened;
  final String draft;
  const Bookmark(
      {required this.machineID,
      required this.session,
      required this.opened,
      this.draft = ''});
  String get key => '$machineID:${session.id}';
  factory Bookmark.fromJson(Json j) => Bookmark(
      machineID: j['machineID'],
      session: Session.fromJson(object(j['session'])),
      opened: j['opened'] ?? 0,
      draft: j['draft'] ?? '');
  Json toJson() => {
        'machineID': machineID,
        'session': session.toJson(),
        'opened': opened,
        'draft': draft
      };
}

class SessionPage {
  final List<Session> sessions;
  final String? cursor;
  final String? warning;
  const SessionPage(this.sessions, {this.cursor, this.warning});
}

/// HTTP is only accepted on a tailnet address or explicit local preview.
String? validateServerUrl(String value, {bool allowLoopbackHttp = false}) {
  final u = Uri.tryParse(value.trim());
  if (u == null ||
      !u.hasAuthority ||
      u.host.isEmpty ||
      u.userInfo.isNotEmpty ||
      u.hasQuery ||
      u.hasFragment ||
      (u.path != '' && u.path != '/')) {
    return 'Informe a URL raiz, sem credenciais ou caminho.';
  }
  if (u.scheme == 'https') return null;
  if (u.scheme != 'http') return 'Use https:// ou http://.';
  final host = u.host.toLowerCase();
  final ipv4 = host.split('.').map(int.tryParse).toList();
  final tailnetIP = ipv4.length == 4 &&
      ipv4.every((n) => n != null && n >= 0 && n <= 255) &&
      ipv4[0] == 100 &&
      ipv4[1]! >= 64 &&
      ipv4[1]! <= 127;
  final magicDNS = host.endsWith('.ts.net') ||
      (!host.contains('.') && RegExp(r'^[a-z][a-z0-9-]*$').hasMatch(host));
  final ipv6 = host.startsWith('fd7a:115c:a1e0:');
  final loopback = host == 'localhost' || host == '127.0.0.1' || host == '::1';
  return tailnetIP || magicDNS || ipv6 || (allowLoopbackHttp && loopback)
      ? null
      : 'HTTP permitido apenas para endereço Tailscale. Prefira HTTPS do Tailscale Serve.';
}

String pretty(dynamic value) =>
    const JsonEncoder.withIndent('  ').convert(value);
