import 'dart:async';
import 'package:flutter/material.dart';
import '../core/api.dart';
import '../core/models.dart';
import '../core/store.dart';
import 'chat.dart';
import 'common.dart';
import 'design.dart';

class SessionsScreen extends StatefulWidget {
  final AppStore store;
  final Machine machine;
  final String? initialDirectory;
  final OpenCodeApiFactory apiFactory;

  const SessionsScreen({
    super.key,
    required this.store,
    required this.machine,
    this.initialDirectory,
    this.apiFactory = OpenCodeApi.new,
  });
  @override
  State<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends State<SessionsScreen> {
  late OpenCodeApi api;
  final search = TextEditingController();
  List<Session> sessions = [];
  String? directory, error, warning;
  String? cursor;
  bool loading = false, resolving = false;
  Timer? debounce;
  int generation = 0;
  @override
  void initState() {
    super.initState();
    api = widget.apiFactory(widget.machine);
    directory = widget.initialDirectory;
    _load();
  }

  @override
  void dispose() {
    generation++;
    debounce?.cancel();
    search.dispose();
    api.close();
    super.dispose();
  }

  Future<void> _load({bool more = false}) async {
    final run = ++generation;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final SessionPage page;
      if (directory == null) {
        page = await api.listAll(
            search: search.text.trim(), cursor: more ? cursor : null);
      } else {
        page = SessionPage(
            await api.listDirectory(directory!,
                search: search.text.trim(), limit: 500),
            warning:
                'Até 500 sessões deste diretório. Use a busca no servidor ou abra pelo ID para sessões mais antigas.');
      }
      if (!mounted || run != generation) return;
      final unique = <String, Session>{
        if (more)
          for (final s in sessions) s.id: s,
        for (final s in page.sessions) s.id: s
      };
      setState(() {
        sessions = unique.values.toList();
        cursor = page.cursor;
        warning = page.warning;
      });
    } catch (e) {
      if (mounted && run == generation) setState(() => error = e.toString());
    } finally {
      if (mounted && run == generation) setState(() => loading = false);
    }
  }

  Future<void> _open(Session s) async {
    await widget.store.remember(widget.machine, s);
    if (!mounted) return;
    await Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => ChatScreen(
                store: widget.store, machine: widget.machine, session: s)));
    if (mounted) _load();
  }

  Future<void> _directory() async {
    final path = await askText(context, 'Diretório remoto',
        hint: '/workspace/project-1', value: directory ?? '');
    if (path == null || !mounted) return;
    try {
      await widget.store.putMachine(
          (widget.store.machine(widget.machine.id) ?? widget.machine)
              .withDirectory(path));
      if (mounted) {
        setState(() => directory = path);
        _load();
      }
    } catch (e) {
      if (mounted) notice(context, e);
    }
  }

  Future<void> _restore() async {
    final id =
        await askText(context, 'Restaurar sessão pelo ID', hint: 'ses_…');
    if (id == null || !mounted) return;
    setState(() => resolving = true);
    try {
      final s = await api.getSession(id);
      if (s.directory.isEmpty) {
        throw const ApiException(
            0, 'Servidor não retornou o diretório da sessão.');
      }
      await _open(s);
    } catch (e) {
      if (mounted) notice(context, e);
    } finally {
      if (mounted) setState(() => resolving = false);
    }
  }

  Future<void> _create() async {
    final path = directory ??
        await askText(context, 'Diretório para nova sessão',
            hint: '/workspace/project-1');
    if (path == null || !mounted) return;
    final title =
        await askText(context, 'Nome da sessão', hint: 'Implementar checkout');
    if (title == null || !mounted) return;
    setState(() => resolving = true);
    try {
      await _open(await api.createSession(path, title));
    } catch (e) {
      if (mounted) notice(context, e);
    } finally {
      if (mounted) setState(() => resolving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final paths =
        (widget.store.machine(widget.machine.id) ?? widget.machine).directories;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.machine.name),
            Text(
              'Sessões OpenCode',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: AppColors.muted,
                  ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Abrir sessão por ID',
            onPressed: resolving ? null : _restore,
            icon: const Icon(Icons.key_outlined),
          ),
          IconButton(
            tooltip: 'Atualizar sessões',
            onPressed: loading ? null : () => _load(),
            icon: const Icon(Icons.sync),
          ),
          const SizedBox(width: 4),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: resolving ? null : _create,
        icon: const Icon(Icons.add),
        label: const Text('Nova sessão'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: search,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search),
                    hintText: 'Buscar sessões',
                    suffixIcon: search.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Limpar busca',
                            onPressed: () {
                              search.clear();
                              setState(() {});
                              _load();
                            },
                            icon: const Icon(Icons.close),
                          ),
                  ),
                  onChanged: (_) {
                    setState(() {});
                    debounce?.cancel();
                    debounce = Timer(
                      const Duration(milliseconds: 450),
                      () => _load(),
                    );
                  },
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    eyebrow('Filtrar por projeto'),
                    const Spacer(),
                    Text(
                      '${sessions.length} carregadas',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: AppColors.muted,
                          ),
                    ),
                  ],
                ),
                const SizedBox(height: 9),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      ChoiceChip(
                        label: const Text('Tudo'),
                        selected: directory == null,
                        onSelected: (_) {
                          setState(() => directory = null);
                          _load();
                        },
                      ),
                      const SizedBox(width: 8),
                      for (final path in paths)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: Text(folderName(path)),
                            tooltip: path,
                            selected: directory == path,
                            onSelected: (_) {
                              setState(() => directory = path);
                              _load();
                            },
                          ),
                        ),
                      ActionChip(
                        label: const Text('Outro'),
                        avatar: const Icon(Icons.create_new_folder_outlined,
                            size: 17),
                        onPressed: _directory,
                      ),
                    ],
                  ),
                ),
                if (directory != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    directory!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: AppColors.muted,
                        ),
                  ),
                ],
              ],
            ),
          ),
          if (loading || resolving) const LinearProgressIndicator(),
          if (error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: InfoBox(error!, icon: Icons.cloud_off),
            ),
          if (warning != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: InfoBox(warning!),
            ),
          Expanded(
            child: sessions.isEmpty && loading
                ? const Center(child: CircularProgressIndicator())
                : sessions.isEmpty
                    ? RefreshIndicator(
                        onRefresh: () => _load(),
                        child: ListView(
                          padding: const EdgeInsets.fromLTRB(20, 18, 20, 120),
                          children: [_emptyState()],
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: () => _load(),
                        child: ListView.builder(
                          padding: const EdgeInsets.fromLTRB(20, 4, 20, 120),
                          itemCount: sessions.length + 1,
                          itemBuilder: (context, index) {
                            if (index == sessions.length) {
                              return _listFooter();
                            }
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: _sessionCard(sessions[index]),
                            );
                          },
                        ),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _emptyState() {
    final hasQuery = search.text.trim().isNotEmpty;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 22, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.forum_outlined, color: AppColors.accent, size: 28),
            const SizedBox(height: 15),
            Text(
              hasQuery
                  ? 'Nenhuma sessão com esse nome'
                  : 'Nenhuma sessão por aqui',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 7),
            Text(
              hasQuery
                  ? 'Tente outro termo ou limpe a busca para ver todas.'
                  : 'Crie uma sessão nova ou abra uma existente pelo ID.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppColors.muted,
                    height: 1.4,
                  ),
            ),
            const SizedBox(height: 14),
            if (hasQuery)
              TextButton.icon(
                onPressed: () {
                  search.clear();
                  setState(() {});
                  _load();
                },
                icon: const Icon(Icons.close),
                label: const Text('Limpar busca'),
              )
            else
              const Text(
                'As sessões precisam estar no armazenamento do mesmo usuário que executa o servidor.',
                style: TextStyle(color: AppColors.muted, fontSize: 12),
              ),
          ],
        ),
      ),
    );
  }

  Widget _sessionCard(Session session) {
    return Card(
      child: InkWell(
        borderRadius: appRadius,
        onTap: resolving
            ? null
            : () async {
                try {
                  await _open(session);
                } catch (error) {
                  if (!mounted) {
                    return;
                  }
                  notice(context, error);
                }
              },
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: AppColors.surfaceHighest,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  session.parentID == null
                      ? Icons.chat_bubble_outline
                      : Icons.subdirectory_arrow_right,
                  color: AppColors.accent,
                  size: 20,
                ),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      session.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      folderName(session.directory),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: AppColors.muted,
                          ),
                    ),
                    const SizedBox(height: 9),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        StatusPill(
                          label: relativeAge(session.updated),
                          icon: Icons.schedule,
                        ),
                        Text(
                          session.id,
                          style:
                              Theme.of(context).textTheme.labelSmall?.copyWith(
                                    color: AppColors.muted,
                                    fontFamily: 'monospace',
                                  ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              const Padding(
                padding: EdgeInsets.only(top: 11),
                child: Icon(
                  Icons.arrow_forward,
                  color: AppColors.muted,
                  size: 18,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _listFooter() {
    if (cursor != null) {
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: OutlinedButton.icon(
          onPressed: loading ? null : () => _load(more: true),
          icon: const Icon(Icons.expand_more),
          label: const Text('Carregar sessões anteriores'),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 22),
      child: Center(
        child: Text(
          '${sessions.length} sessões nesta lista',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: AppColors.muted,
              ),
        ),
      ),
    );
  }
}
