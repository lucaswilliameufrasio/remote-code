import 'dart:async';
import 'package:flutter/material.dart';
import '../core/api.dart';
import '../core/remote_files.dart';
import 'common.dart';

enum _FilesStage { loading, ready, failed }

class RemoteFilesScreen extends StatefulWidget {
  final OpenCodeApi api;
  final String directory;
  final bool chooseDirectory;

  const RemoteFilesScreen(
      {super.key,
      required this.api,
      required this.directory,
      this.chooseDirectory = false});

  @override
  State<RemoteFilesScreen> createState() => _RemoteFilesScreenState();
}

class _RemoteFilesScreenState extends State<RemoteFilesScreen> {
  final search = TextEditingController();
  _FilesStage stage = _FilesStage.loading;
  List<RemoteFileEntry> entries = [];
  String path = '', error = '';
  int generation = 0;
  Timer? debounce;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    generation++;
    debounce?.cancel();
    search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final run = ++generation;
    final query = search.text.trim();
    setState(() => stage = _FilesStage.loading);
    try {
      final result = query.isEmpty
          ? await widget.api.listRemoteFiles(widget.directory, path: path)
          : await widget.api.findRemoteFiles(widget.directory, query,
              directoriesOnly: widget.chooseDirectory);
      if (!mounted || run != generation) {
        return;
      }
      setState(() {
        entries = result
            .where((entry) =>
                (!widget.chooseDirectory || entry.isDirectory) &&
                (query.isNotEmpty ||
                    (entry.path.contains('/')
                            ? entry.path
                                .substring(0, entry.path.lastIndexOf('/'))
                            : '') ==
                        path))
            .toList();
        stage = _FilesStage.ready;
      });
    } catch (exception) {
      if (mounted && run == generation) {
        setState(() {
          error = exception.toString();
          stage = _FilesStage.failed;
        });
      }
    }
  }

  void _navigate(String nextPath) {
    debounce?.cancel();
    search.clear();
    path = nextPath;
    _load();
  }

  Future<void> _open(RemoteFileEntry entry) async {
    if (entry.isDirectory) {
      _navigate(entry.path);
      return;
    }
    final selected = await Navigator.push<String>(
        context,
        MaterialPageRoute(
          builder: (_) => _RemoteFileScreen(
              api: widget.api, directory: widget.directory, path: entry.path),
        ));
    if (selected != null && mounted) {
      Navigator.pop(context, selected);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title: Text(widget.chooseDirectory
              ? 'Escolher subpasta'
              : 'Arquivos do projeto')),
      body: Column(children: [
        Padding(
            padding: const EdgeInsets.all(12),
            child: Column(children: [
              SelectableText(
                  '${widget.directory}${path.isEmpty ? '' : '/$path'}'),
              const SizedBox(height: 8),
              const Text(
                  'Explorador restrito do host: somente leitura, com raízes configuradas e links simbólicos recusados. Isso não limita as ferramentas do agente.',
                  style: TextStyle(fontSize: 12)),
              const SizedBox(height: 8),
              TextField(
                  controller: search,
                  decoration: const InputDecoration(
                      labelText: 'Buscar no projeto (até 100 resultados)',
                      prefixIcon: Icon(Icons.search)),
                  onChanged: (_) {
                    debounce?.cancel();
                    generation++;
                    setState(() => stage = _FilesStage.loading);
                    debounce = Timer(const Duration(milliseconds: 350), _load);
                  }),
              if (path.isNotEmpty || search.text.isNotEmpty)
                Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () => _navigate(search.text.isNotEmpty
                          ? path
                          : (path.contains('/')
                              ? path.substring(0, path.lastIndexOf('/'))
                              : '')),
                      icon: const Icon(Icons.arrow_upward),
                      label: Text(search.text.isNotEmpty
                          ? 'Limpar busca'
                          : 'Pasta anterior'),
                    )),
            ])),
        Expanded(
            child: switch (stage) {
          _FilesStage.loading =>
            const Center(child: CircularProgressIndicator()),
          _FilesStage.failed => Center(
              child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    InfoBox(error, icon: Icons.error_outline),
                    TextButton(
                        onPressed: _load,
                        child: const Text('Tentar novamente')),
                  ]))),
          _FilesStage.ready => RefreshIndicator(
              onRefresh: _load,
              child: ListView.builder(
                physics: const AlwaysScrollableScrollPhysics(),
                itemCount: entries.isEmpty ? 1 : entries.length,
                itemBuilder: (context, index) {
                  if (entries.isEmpty) {
                    return const Padding(
                        padding: EdgeInsets.all(20),
                        child: Text('Nenhum arquivo ou pasta encontrado.'));
                  }
                  final entry = entries[index];
                  return ListTile(
                    leading: Icon(entry.isDirectory
                        ? Icons.folder_outlined
                        : Icons.description_outlined),
                    title: Text(entry.name),
                    subtitle: search.text.isEmpty || entry.path == entry.name
                        ? null
                        : Text(entry.path),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _open(entry),
                  );
                },
              )),
        }),
        if (widget.chooseDirectory)
          SafeArea(
              top: false,
              child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: FilledButton.icon(
                    onPressed: stage == _FilesStage.ready && search.text.isEmpty
                        ? () => Navigator.pop(context,
                            '${widget.directory}${path.isEmpty ? '' : '/$path'}')
                        : null,
                    icon: const Icon(Icons.check),
                    label: const Text('Usar esta pasta'),
                  ))),
      ]),
    );
  }
}

class _RemoteFileScreen extends StatefulWidget {
  final OpenCodeApi api;
  final String directory, path;
  const _RemoteFileScreen(
      {required this.api, required this.directory, required this.path});
  @override
  State<_RemoteFileScreen> createState() => _RemoteFileScreenState();
}

class _RemoteFileScreenState extends State<_RemoteFileScreen> {
  late Future<RemoteFilePreview> preview;
  @override
  void initState() {
    super.initState();
    preview = widget.api.readRemoteFile(widget.directory, widget.path);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(widget.path)),
        body: FutureBuilder<RemoteFilePreview>(
            future: preview,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Center(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Padding(
                      padding: const EdgeInsets.all(16),
                      child: InfoBox(snapshot.error.toString(),
                          icon: Icons.error_outline)),
                  TextButton(
                      onPressed: () => setState(() {
                            preview = widget.api
                                .readRemoteFile(widget.directory, widget.path);
                          }),
                      child: const Text('Tentar novamente')),
                ]));
              }
              final data = snapshot.data;
              if (data == null) {
                return const Center(child: CircularProgressIndicator());
              }
              return Column(children: [
                if (data.truncated)
                  const Padding(
                      padding: EdgeInsets.all(12),
                      child: Text(
                          'Prévia limitada a 256 KiB. O arquivo não foi carregado por completo.')),
                Expanded(
                    child: SingleChildScrollView(
                        padding: const EdgeInsets.all(16),
                        child: SelectableText(data.text,
                            style: const TextStyle(
                                fontFamily: 'monospace', fontSize: 13)))),
                SafeArea(
                    top: false,
                    child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: FilledButton.icon(
                          onPressed: () => Navigator.pop(context, widget.path),
                          icon: const Icon(Icons.edit_note),
                          label: const Text('Inserir caminho no rascunho'),
                        ))),
              ]);
            }),
      );
}
