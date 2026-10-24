import 'package:flutter/material.dart';
import '../core/api.dart';
import '../core/file_changes.dart';
import '../core/models.dart';
import 'common.dart';

class FileChangesScreen extends StatefulWidget {
  final OpenCodeApi api;
  final Session session;
  const FileChangesScreen(
      {super.key, required this.api, required this.session});

  @override
  State<FileChangesScreen> createState() => _FileChangesScreenState();
}

class _FileChangesScreenState extends State<FileChangesScreen> {
  late Future<List<FileChange>> changes;
  @override
  void initState() {
    super.initState();
    changes = widget.api.sessionChanges(widget.session);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Alterações da sessão'), actions: [
          IconButton(
              tooltip: 'Atualizar alterações',
              icon: const Icon(Icons.refresh),
              onPressed: () => setState(
                  () => changes = widget.api.sessionChanges(widget.session))),
        ]),
        body: Column(children: [
          const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                  'Comparação dos snapshots do turno mais recente da sessão; durante execução, pode incluir o estado atual. Não é o diff completo do Git. Somente leitura.')),
          Expanded(
              child: FutureBuilder<List<FileChange>>(
                  future: changes,
                  builder: (context, snapshot) {
                    if (snapshot.hasError) {
                      return Center(
                          child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    InfoBox(snapshot.error.toString(),
                                        icon: Icons.error_outline),
                                    TextButton(
                                        onPressed: () => setState(() =>
                                            changes = widget.api.sessionChanges(
                                                widget.session)),
                                        child: const Text('Tentar novamente')),
                                  ])));
                    }
                    final files = snapshot.data;
                    if (files == null) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (files.isEmpty) {
                      return const Center(
                          child: Text('Nenhuma alteração neste turno.'));
                    }
                    var additions = 0;
                    var deletions = 0;
                    for (final file in files) {
                      additions += file.additions;
                      deletions += file.deletions;
                    }
                    return Column(children: [
                      Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(
                              '${files.length} arquivos · +$additions / −$deletions')),
                      Expanded(
                          child: ListView.builder(
                              itemCount: files.length,
                              itemBuilder: (context, index) {
                                final file = files[index];
                                return ListTile(
                                  leading: Icon(switch (file.status) {
                                    'added' => Icons.add_box_outlined,
                                    'deleted' => Icons.delete_outline,
                                    _ => Icons.edit_outlined,
                                  }),
                                  title: Text(file.file),
                                  subtitle: Text(
                                      '+${file.additions} / −${file.deletions}'),
                                  trailing: const Icon(Icons.chevron_right),
                                  onTap: () => Navigator.push<void>(
                                      context,
                                      MaterialPageRoute(
                                          builder: (_) =>
                                              FilePatchScreen(change: file))),
                                );
                              })),
                    ]);
                  })),
        ]),
      );
}

class FilePatchScreen extends StatelessWidget {
  static const maxCharacters = 128 * 1024;
  static const maxLines = 2000;
  final FileChange change;
  const FilePatchScreen({super.key, required this.change});

  @override
  Widget build(BuildContext context) {
    final patch = change.patch.length > maxCharacters
        ? change.patch.substring(0, maxCharacters)
        : change.patch;
    final lines = patch.split('\n');
    final truncated =
        change.patch.length > maxCharacters || lines.length > maxLines;
    return Scaffold(
      appBar: AppBar(title: Text(change.file)),
      body: Column(children: [
        if (truncated)
          const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                  'Prévia limitada: este diff não está sendo exibido por completo.')),
        if (patch.isEmpty)
          const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Sem patch textual disponível para este arquivo.')),
        Expanded(
            child: SelectionArea(
                child: ListView.builder(
          itemCount: lines.length > maxLines ? maxLines : lines.length,
          itemBuilder: (context, index) {
            final line = lines[index];
            final color = line.startsWith('+') && !line.startsWith('+++')
                ? Colors.green
                : line.startsWith('-') && !line.startsWith('---')
                    ? Colors.red
                    : line.startsWith('@@')
                        ? Colors.blue
                        : null;
            return Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
              color: color?.withValues(alpha: .12),
              child: Text(line,
                  style: TextStyle(
                      fontFamily: 'monospace', fontSize: 13, color: color)),
            );
          },
        ))),
      ]),
    );
  }
}
