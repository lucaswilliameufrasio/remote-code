import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'models.dart';
import 'security.dart';

class AppStore extends ChangeNotifier {
  final FlutterSecureStorage storage;
  late final AppSecurity security;

  AppStore({
    FlutterSecureStorage? storage,
    AppSecurity? security,
  }) : storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock_this_device,
              ),
            ) {
    this.security = security ?? AppSecurity(storage: this.storage);
  }

  List<Machine> machines = [];
  List<Bookmark> bookmarks = [];
  String? error;
  Future<void> _pending = Future.value();

  Future<void> load() async {
    await security.load();
    if (security.error != null) {
      return;
    }

    try {
      final raw = await storage.read(key: 'remote_dev_v1');
      if (raw == null) return;
      final j = object(jsonDecode(raw));
      machines = objects(j['machines']).map(Machine.fromJson).toList();
      bookmarks = objects(j['bookmarks']).map(Bookmark.fromJson).toList();
    } catch (_) {
      error =
          'Não foi possível ler o armazenamento seguro. Reinicie o app antes de alterar os cadastros.';
    }
  }

  Future<void> _save() {
    if (error != null) return Future.error(StateError(error!));
    final snapshot = jsonEncode({
      'machines': machines.map((m) => m.toJson()).toList(),
      'bookmarks': bookmarks.map((b) => b.toJson()).toList()
    });
    final operation = _pending
        .catchError((Object _) {})
        .then((_) => storage.write(key: 'remote_dev_v1', value: snapshot));
    _pending = operation;
    notifyListeners();
    return operation;
  }

  Machine? machine(String id) {
    for (final m in machines) {
      if (m.id == id) return m;
    }
    return null;
  }

  Future<void> putMachine(Machine machine) {
    machines = [...machines.where((m) => m.id != machine.id), machine];
    return _save();
  }

  Future<void> removeMachine(String id) {
    machines.removeWhere((m) => m.id == id);
    bookmarks.removeWhere((b) => b.machineID == id);
    return _save();
  }

  Bookmark? bookmark(String machineID, String sessionID) {
    for (final b in bookmarks) {
      if (b.machineID == machineID && b.session.id == sessionID) return b;
    }
    return null;
  }

  Future<void> remember(Machine m, Session s, {String? draft}) {
    final old = bookmark(m.id, s.id);
    bookmarks.removeWhere((b) => b.machineID == m.id && b.session.id == s.id);
    bookmarks.insert(
        0,
        Bookmark(
            machineID: m.id,
            session: s,
            opened: DateTime.now().millisecondsSinceEpoch,
            draft: draft ?? old?.draft ?? ''));
    bookmarks = bookmarks.take(100).toList();
    final index = machines.indexWhere((v) => v.id == m.id);
    if (index >= 0) {
      machines[index] = machines[index].withDirectory(s.directory);
    }
    return _save();
  }
}
