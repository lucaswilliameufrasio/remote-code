import 'package:flutter/material.dart';
import '../core/api.dart';
import '../core/models.dart';
import '../core/store.dart';
import 'remote_files.dart';

class SessionDirectoryPicker extends StatefulWidget {
  final AppStore store;
  final Machine machine;
  final OpenCodeApiFactory apiFactory;
  final String? initialDirectory;

  const SessionDirectoryPicker({
    super.key,
    required this.store,
    required this.machine,
    required this.apiFactory,
    this.initialDirectory,
  });

  @override
  State<SessionDirectoryPicker> createState() => _SessionDirectoryPickerState();
}

class _SessionDirectoryPickerState extends State<SessionDirectoryPicker> {
  late final TextEditingController directoryController;
  final Map<String, String> suggestions = {};
  final List<String> errors = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    directoryController =
        TextEditingController(text: widget.initialDirectory ?? '');
    final machine = widget.store.machine(widget.machine.id) ?? widget.machine;
    for (final bookmark in widget.store.bookmarks) {
      if (bookmark.machineID == machine.id) {
        _addSuggestion(bookmark.session.directory);
      }
    }
    for (final directory in machine.directories) {
      _addSuggestion(directory);
    }
    _loadSuggestions();
  }

  @override
  void dispose() {
    directoryController.dispose();
    super.dispose();
  }

  void _addSuggestion(String directory, {String? name}) {
    var normalizedDirectory = directory.trim();
    while (
        normalizedDirectory.length > 1 && normalizedDirectory.endsWith('/')) {
      normalizedDirectory =
          normalizedDirectory.substring(0, normalizedDirectory.length - 1);
    }
    if (normalizedDirectory.isNotEmpty) {
      if (name != null && name.trim().isNotEmpty) {
        suggestions[normalizedDirectory] = name;
      } else {
        suggestions.putIfAbsent(normalizedDirectory, () => '');
      }
    }
  }

  Future<void> _loadSuggestions() async {
    final api = widget.apiFactory(widget.machine);
    try {
      try {
        final projects = await api.projects();
        if (!mounted) {
          return;
        }
        for (final project in projects) {
          final directory = project.worktree;
          if (directory != null) {
            _addSuggestion(directory, name: project.name);
          }
        }
      } catch (exception) {
        errors.add('Projetos: $exception');
      }
      try {
        final page = await api.listAll();
        if (!mounted) {
          return;
        }
        for (final session in page.sessions) {
          _addSuggestion(session.directory);
        }
      } catch (exception) {
        errors.add('Sessões recentes: $exception');
      }
    } finally {
      api.close();
      if (mounted) {
        setState(() => loading = false);
      }
    }
  }

  Future<void> _browse(String directory) async {
    final api = widget.apiFactory(widget.machine);
    try {
      final selected = await Navigator.push<String>(
          context,
          MaterialPageRoute(
            builder: (_) => RemoteFilesScreen(
                api: api, directory: directory, chooseDirectory: true),
          ));
      if (selected != null && mounted) {
        Navigator.pop(context, selected);
      }
    } finally {
      api.close();
    }
  }

  Future<void> _loadAllowedRoots() async {
    if (loading) {
      return;
    }
    setState(() => loading = true);
    final api = widget.apiFactory(widget.machine);
    try {
      final roots =
          await api.allowedFileRoots(directory: widget.initialDirectory ?? '');
      if (mounted) {
        for (final root in roots) {
          _addSuggestion(root);
        }
      }
    } catch (exception) {
      if (mounted) {
        errors.add('Raízes autorizadas: $exception');
      }
    } finally {
      api.close();
      if (mounted) {
        setState(() => loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final search = directoryController.text.trim().toLowerCase();
    final filteredSuggestions = suggestions.entries.where((entry) =>
        entry.key.toLowerCase().contains(search) ||
        entry.value.toLowerCase().contains(search));

    return AlertDialog(
      title: Text('Escolher pasta · ${widget.machine.name}'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: directoryController,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Buscar ou digitar caminho',
                hintText: '/workspace/projeto',
              ),
            ),
            const SizedBox(height: 12),
            TextButton.icon(
                onPressed: loading ? null : _loadAllowedRoots,
                icon: const Icon(Icons.folder_shared_outlined),
                label: const Text('Carregar raízes autorizadas do host')),
            if (loading) const LinearProgressIndicator(),
            Flexible(
              child: SizedBox(
                height: 260,
                child: ListView(
                  children: [
                    for (final entry in filteredSuggestions)
                      ListTile(
                        leading: const Icon(Icons.folder_outlined),
                        title:
                            Text(entry.value.isEmpty ? entry.key : entry.value),
                        subtitle: entry.value.isEmpty ? null : Text(entry.key),
                        trailing:
                            widget.machine.backend == AgentBackend.claudeCode
                                ? null
                                : IconButton(
                                    tooltip: 'Explorar ${entry.key}',
                                    icon: const Icon(Icons.folder_open),
                                    onPressed: () => _browse(entry.key),
                                  ),
                        onTap: () => Navigator.pop(context, entry.key),
                      ),
                    if (!loading && filteredSuggestions.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: Text(
                            'Nenhuma pasta sugerida. Você pode digitar um caminho completo.'),
                      ),
                  ],
                ),
              ),
            ),
            if (errors.isNotEmpty)
              Text(
                'Algumas sugestões não puderam ser carregadas. ${errors.join(' ')}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar')),
        FilledButton(
          onPressed: directoryController.text.trim().isEmpty
              ? null
              : () => Navigator.pop(context, directoryController.text.trim()),
          child: const Text('Usar caminho digitado'),
        ),
      ],
    );
  }
}
