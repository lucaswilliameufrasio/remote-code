import 'package:flutter/material.dart';
import '../core/api.dart';
import '../core/concurrency.dart';
import '../core/models.dart';
import '../core/store.dart';
import 'chat.dart';
import 'brand.dart';
import 'common.dart';
import 'design.dart';
import 'pending_inbox.dart';
import 'projects.dart';
import 'sessions.dart';
import 'pairing.dart';
import 'machine_setup.dart';
import 'connection_diagnostics.dart';

const allowTailnetHttp = bool.fromEnvironment('ALLOW_TAILNET_HTTP');
const allowLocalServerHttp = bool.fromEnvironment('ALLOW_LOCAL_SERVER_HTTP');

class HomeScreen extends StatefulWidget {
  final AppStore store;
  final OpenCodeApiFactory apiFactory;

  const HomeScreen({
    super.key,
    required this.store,
    this.apiFactory = OpenCodeApi.create,
  });
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

enum HomeDestination { activity, inbox, projects, machines }

class _HomeScreenState extends State<HomeScreen> {
  static const int recentSessionsPerMachine = 10;
  static const int sessionQueryConcurrency = 3;

  final Map<String, String> _health = {};
  bool _checking = false;
  bool _loadingRecentSessions = false;
  Map<String, List<Session>> _serverRecentSessions = {};
  Map<String, String> _recentSessionCursors = {};
  List<String> _recentSessionErrors = [];
  final _sessionSearchController = TextEditingController();
  String _sessionSearch = '';
  HomeDestination _destination = HomeDestination.activity;
  final Set<HomeDestination> _visitedDestinations = {
    HomeDestination.activity,
    HomeDestination.machines,
  };
  int _pendingActionCount = 0;
  final GlobalKey<PendingInboxScreenState> _pendingInboxKey =
      GlobalKey<PendingInboxScreenState>();
  final GlobalKey<ProjectsScreenState> _projectsKey =
      GlobalKey<ProjectsScreenState>();
  AppStore get store => widget.store;
  @override
  void initState() {
    super.initState();
    store.addListener(_changed);
    _check();
    _loadRecentSessions();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    store.removeListener(_changed);
    _sessionSearchController.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    if (_checking) {
      return;
    }
    setState(() => _checking = true);
    final checks = <Future<void>>[];
    for (final machine in store.machines) {
      checks.add(_checkMachine(machine));
    }
    await Future.wait(checks);
    if (mounted) {
      setState(() => _checking = false);
    }
  }

  Future<void> _checkMachine(Machine machine) async {
    final api = widget.apiFactory(machine);
    try {
      final health = await api.health();
      _health[machine.id] = health['healthy'] == true
          ? 'Online · ${health['version'] ?? ''}'
          : 'Indisponível';
    } catch (_) {
      _health[machine.id] = 'Sem conexão';
    } finally {
      api.close();
    }
  }

  Future<void> _edit([Machine? machine]) async {
    final saved = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
            builder: (_) => MachineEditor(
                store: store,
                machine: machine,
                apiFactory: widget.apiFactory)));
    if (saved == true && mounted) {
      await Future.wait<void>([_check(), _loadRecentSessions()]);
    }
  }

  Future<void> _open(Bookmark b) async {
    final m = store.machine(b.machineID);
    if (m == null) {
      return;
    }
    await Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => ChatScreen(
                  store: store,
                  machine: m,
                  session: b.session,
                  apiOverride: widget.apiFactory(m),
                )));
    if (mounted) {
      await _loadRecentSessions();
    }
  }

  Future<void> _loadRecentSessions() async {
    if (_loadingRecentSessions) {
      return;
    }
    setState(() {
      _loadingRecentSessions = true;
      _recentSessionErrors = [];
    });

    final results = await mapConcurrent<Machine, _RecentSessionsResult>(
      items: store.machines,
      concurrency: sessionQueryConcurrency,
      operation: _loadMachineRecentSessions,
    );
    if (!mounted) {
      return;
    }

    final sessionsByMachine = <String, List<Session>>{};
    final cursorsByMachine = <String, String>{};
    final errors = <String>[];
    for (final result in results) {
      if (result.error != null) {
        final previousSessions = _serverRecentSessions[result.machine.id];
        if (previousSessions != null) {
          sessionsByMachine[result.machine.id] = previousSessions;
        }
        final previousCursor = _recentSessionCursors[result.machine.id];
        if (previousCursor != null) {
          cursorsByMachine[result.machine.id] = previousCursor;
        }
        errors.add('${result.machine.name}: ${result.error}');
        continue;
      }
      sessionsByMachine[result.machine.id] = result.sessions;
      final cursor = result.cursor;
      if (cursor != null) {
        cursorsByMachine[result.machine.id] = cursor;
      }
    }

    setState(() {
      _serverRecentSessions = sessionsByMachine;
      _recentSessionCursors = cursorsByMachine;
      _recentSessionErrors = errors;
      _loadingRecentSessions = false;
    });
  }

  Future<_RecentSessionsResult> _loadMachineRecentSessions(
    Machine machine,
  ) async {
    final api = widget.apiFactory(machine);
    try {
      final page = await api.listAll(
        limit: recentSessionsPerMachine,
        search: _sessionSearch,
      );
      return _RecentSessionsResult(machine, page.sessions, cursor: page.cursor);
    } catch (exception) {
      return _RecentSessionsResult(
        machine,
        const [],
        error: exception.toString(),
      );
    } finally {
      api.close();
    }
  }

  Future<void> _loadMoreRecentSessions(Machine machine) async {
    final cursor = _recentSessionCursors[machine.id];
    if (_loadingRecentSessions || cursor == null) {
      return;
    }
    setState(() {
      _loadingRecentSessions = true;
      _recentSessionErrors = [];
    });
    final api = widget.apiFactory(machine);
    try {
      final page = await api.listAll(
        limit: recentSessionsPerMachine,
        cursor: cursor,
        search: _sessionSearch,
      );
      if (!mounted) {
        return;
      }
      final sessionsByID = <String, Session>{
        for (final session in _serverRecentSessions[machine.id] ?? <Session>[])
          session.id: session,
        for (final session in page.sessions) session.id: session,
      };
      setState(() {
        _serverRecentSessions[machine.id] = sessionsByID.values.toList();
        final nextCursor = page.cursor;
        if (nextCursor == null || nextCursor == cursor) {
          _recentSessionCursors.remove(machine.id);
        } else {
          _recentSessionCursors[machine.id] = nextCursor;
        }
      });
    } catch (exception) {
      if (mounted) {
        setState(() {
          _recentSessionErrors = ['${machine.name}: $exception'];
        });
      }
    } finally {
      api.close();
      if (mounted) {
        setState(() => _loadingRecentSessions = false);
      }
    }
  }

  Future<void> _refreshActivity() async {
    await Future.wait<void>([_check(), _loadRecentSessions()]);
  }

  Future<void> _searchSessions() async {
    if (_loadingRecentSessions) {
      return;
    }
    setState(() => _sessionSearch = _sessionSearchController.text.trim());
    await _loadRecentSessions();
  }

  List<Bookmark> _activitySessions() {
    final sessionsByKey = <String, Bookmark>{
      for (final bookmark in store.bookmarks) bookmark.key: bookmark,
    };
    for (final machine in store.machines) {
      final sessions = _serverRecentSessions[machine.id] ?? const <Session>[];
      for (final session in sessions) {
        final key = '${machine.id}:${session.id}';
        final bookmark = sessionsByKey[key];
        if (bookmark == null) {
          sessionsByKey[key] = Bookmark(
            machineID: machine.id,
            session: session,
            opened: session.updated,
          );
          continue;
        }
        final opened = bookmark.opened > session.updated
            ? bookmark.opened
            : session.updated;
        sessionsByKey[key] = Bookmark(
          machineID: machine.id,
          session: session,
          opened: opened,
          draft: bookmark.draft,
        );
      }
    }

    final activitySessions = sessionsByKey.values
        .where((bookmark) => bookmark.session.title
            .toLowerCase()
            .contains(_sessionSearch.toLowerCase()))
        .toList();
    activitySessions.sort((first, second) {
      final openedComparison = second.opened.compareTo(first.opened);
      if (openedComparison != 0) {
        return openedComparison;
      }
      final machineComparison = first.machineID.compareTo(second.machineID);
      if (machineComparison != 0) {
        return machineComparison;
      }
      return first.session.id.compareTo(second.session.id);
    });
    return activitySessions;
  }

  Future<void> _openProject(ProjectTarget project) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SessionsScreen(
          store: store,
          machine: project.machine,
          initialDirectory: project.directory,
          apiFactory: widget.apiFactory,
        ),
      ),
    );
  }

  Future<void> _openPendingAction(PendingAction action) async {
    await store.remember(action.machine, action.session);
    if (!mounted) {
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          store: store,
          machine: action.machine,
          session: action.session,
          apiOverride: widget.apiFactory(action.machine),
        ),
      ),
    );
  }

  void _updatePendingActionCount(int count) {
    if (mounted && count != _pendingActionCount) {
      setState(() => _pendingActionCount = count);
    }
  }

  void _selectDestination(HomeDestination destination) {
    final wasAlreadyVisited = _visitedDestinations.contains(destination);
    setState(() {
      _destination = destination;
      _visitedDestinations.add(destination);
    });
    if (destination == HomeDestination.inbox && wasAlreadyVisited) {
      _pendingInboxKey.currentState?.refresh();
    }
    if (destination == HomeDestination.activity && wasAlreadyVisited) {
      _loadRecentSessions();
    }
  }

  @override
  Widget build(BuildContext context) {
    final onlineCount =
        _health.values.where((status) => status.startsWith('Online')).length;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const BrandMark(size: 38),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'CodeRelay',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.7,
                      ),
                ),
                Text(
                  'Agentes de código no celular',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: AppColors.muted,
                      ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Atualizar conexões e sessões',
            onPressed:
                _checking || _loadingRecentSessions ? null : _refreshActivity,
            icon: const Icon(Icons.sync),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: SafeArea(
        top: false,
        child: IndexedStack(
          index: _destination.index,
          children: [
            _activity(onlineCount),
            if (_visitedDestinations.contains(HomeDestination.inbox))
              PendingInboxScreen(
                key: _pendingInboxKey,
                store: store,
                apiFactory: widget.apiFactory,
                onOpenAction: _openPendingAction,
                onCountChanged: _updatePendingActionCount,
              )
            else
              const SizedBox.shrink(),
            if (_visitedDestinations.contains(HomeDestination.projects))
              ProjectsScreen(
                key: _projectsKey,
                store: store,
                apiFactory: widget.apiFactory,
                onOpenProject: _openProject,
              )
            else
              const SizedBox.shrink(),
            _machines(onlineCount),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _destination.index,
        onDestinationSelected: (index) =>
            _selectDestination(HomeDestination.values[index]),
        destinations: [
          NavigationDestination(
            icon: Icon(Icons.work_outline),
            selectedIcon: Icon(Icons.work),
            label: 'Trabalho',
          ),
          NavigationDestination(
            icon: Badge(
              label: Text(_pendingActionCount.toString()),
              isLabelVisible: _pendingActionCount > 0,
              child: const Icon(Icons.notifications_outlined),
            ),
            selectedIcon: Badge(
              label: Text(_pendingActionCount.toString()),
              isLabelVisible: _pendingActionCount > 0,
              child: const Icon(Icons.notifications),
            ),
            label: 'Pendências',
          ),
          NavigationDestination(
            icon: Icon(Icons.folder_outlined),
            selectedIcon: Icon(Icons.folder),
            label: 'Projetos',
          ),
          NavigationDestination(
            icon: Icon(Icons.dns_outlined),
            selectedIcon: Icon(Icons.dns),
            label: 'Máquinas',
          ),
        ],
      ),
      floatingActionButton:
          _destination == HomeDestination.machines && store.error == null
              ? FloatingActionButton.extended(
                  onPressed: () => _edit(),
                  icon: const Icon(Icons.add),
                  label: const Text('Conectar máquina'),
                )
              : null,
    );
  }

  Widget _activity(int onlineCount) {
    final activitySessions = _activitySessions();
    return RefreshIndicator(
      onRefresh: _refreshActivity,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(22, 18, 22, 32),
        children: [
          Row(
            children: [
              eyebrow('Seu espaço de trabalho'),
              const Spacer(),
              StatusPill(
                label: store.machines.isEmpty
                    ? 'Sem máquinas'
                    : '$onlineCount/${store.machines.length} online',
                active: onlineCount > 0,
                icon: Icons.circle,
              ),
            ],
          ),
          const SizedBox(height: 18),
          Text(
            'Seu trabalho,\nsem interrupções.',
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  height: 1.08,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -1.1,
                ),
          ),
          const SizedBox(height: 10),
          Text(
            'Retome uma sessão exatamente de onde parou.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppColors.muted,
                  height: 1.45,
                ),
          ),
          if (store.error != null) ...[
            const SizedBox(height: 16),
            InfoBox(store.error!, icon: Icons.error_outline),
          ],
          if (_recentSessionErrors.isNotEmpty) ...[
            const SizedBox(height: 12),
            for (final sessionError in _recentSessionErrors) ...[
              InfoBox(sessionError, icon: Icons.cloud_off),
              const SizedBox(height: 8),
            ],
          ],
          if (_checking || _loadingRecentSessions) ...[
            const SizedBox(height: 18),
            const LinearProgressIndicator(),
          ],
          const SizedBox(height: 30),
          Row(
            children: [
              eyebrow('Retomar trabalho', color: AppColors.accent),
              const Spacer(),
              Text(
                '${activitySessions.length} recentes',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: AppColors.muted,
                    ),
              ),
            ],
          ),
          const SizedBox(height: 13),
          if (store.machines.isNotEmpty) ...[
            TextField(
              controller: _sessionSearchController,
              enabled: !_loadingRecentSessions,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _searchSessions(),
              decoration: InputDecoration(
                labelText: 'Buscar em todas as sessões',
                hintText: 'Título da sessão no servidor',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: IconButton(
                  tooltip: 'Buscar sessões',
                  onPressed: _loadingRecentSessions ? null : _searchSessions,
                  icon: const Icon(Icons.arrow_forward),
                ),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Até 10 por máquina em cada página. Busque pelo título ou carregue mais sessões abaixo.',
            ),
            const SizedBox(height: 13),
          ],
          if (activitySessions.isEmpty) _emptyActivity(),
          for (final bookmark in activitySessions) ...[
            _bookmarkCard(bookmark),
            const SizedBox(height: 10),
          ],
          for (final machine in store.machines)
            if (_recentSessionCursors.containsKey(machine.id)) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: ValueKey('load-more-sessions-${machine.id}'),
                onPressed: _loadingRecentSessions
                    ? null
                    : () => _loadMoreRecentSessions(machine),
                icon: const Icon(Icons.expand_more),
                label: Text('Carregar mais 10 sessões · ${machine.name}'),
              ),
            ],
          if (activitySessions.isNotEmpty) ...[
            const SizedBox(height: 20),
            _browseMachinesCard(),
          ],
        ],
      ),
    );
  }

  Widget _emptyActivity() {
    final hasMachines = store.machines.isNotEmpty;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 22, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: AppColors.surfaceHighest,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(
                hasMachines ? Icons.history : Icons.link,
                color: AppColors.accent,
              ),
            ),
            const SizedBox(height: 17),
            Text(
              hasMachines
                  ? _sessionSearch.isNotEmpty
                      ? 'Nenhuma sessão com esse título'
                      : 'Tudo pronto para continuar'
                  : 'Conecte seu ambiente',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 7),
            Text(
              hasMachines
                  ? _sessionSearch.isNotEmpty
                      ? 'Tente outro título ou apague a busca e toque na seta para ver as recentes.'
                      : 'As sessões recentes das máquinas aparecerão aqui. Abrir uma também a salva como atalho no celular.'
                  : 'Adicione seu Mac, PC ou servidor para acessar sessões do OpenCode ou Claude Code.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppColors.muted,
                    height: 1.4,
                  ),
            ),
            const SizedBox(height: 17),
            FilledButton.tonalIcon(
              onPressed: () => setState(
                () => _destination = HomeDestination.machines,
              ),
              icon: Icon(hasMachines ? Icons.dns_outlined : Icons.add),
              label: Text(
                hasMachines ? 'Explorar máquinas' : 'Configurar máquina',
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bookmarkCard(Bookmark bookmark) {
    final machine = store.machine(bookmark.machineID);
    return Card(
      child: InkWell(
        borderRadius: appRadius,
        onTap: store.error != null ? null : () => _open(bookmark),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: AppColors.accentSoft,
                  borderRadius: BorderRadius.circular(15),
                ),
                child: const Icon(Icons.terminal, color: AppColors.accent),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      bookmark.session.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      '${machine?.name ?? 'Máquina'}  ·  ${folderName(bookmark.session.directory)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: AppColors.muted,
                          ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      relativeAge(bookmark.opened),
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: AppColors.accent,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(
                Icons.arrow_forward,
                color: AppColors.muted,
                size: 19,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _browseMachinesCard() {
    return Card(
      color: AppColors.surfaceRaised,
      child: InkWell(
        borderRadius: appRadius,
        onTap: () => setState(
          () => _destination = HomeDestination.machines,
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              const Icon(Icons.devices_other, color: AppColors.accent),
              const SizedBox(width: 12),
              const Expanded(child: Text('Abrir sessões de outra máquina')),
              const Icon(Icons.chevron_right, color: AppColors.muted),
            ],
          ),
        ),
      ),
    );
  }

  Widget _machines(int onlineCount) {
    return RefreshIndicator(
      onRefresh: _check,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(22, 18, 22, 112),
        children: [
          Row(
            children: [
              eyebrow('Seus ambientes'),
              const Spacer(),
              StatusPill(
                label: '$onlineCount/${store.machines.length} online',
                active: onlineCount > 0,
                icon: Icons.circle,
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            'Máquinas',
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: -.8,
                ),
          ),
          const SizedBox(height: 7),
          Text(
            'Abra sessões do OpenCode ou Claude Code em cada ambiente.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppColors.muted,
                  height: 1.4,
                ),
          ),
          if (_checking) ...[
            const SizedBox(height: 18),
            const LinearProgressIndicator(),
          ],
          if (store.error != null) ...[
            const SizedBox(height: 16),
            InfoBox(store.error!, icon: Icons.error_outline),
          ],
          if (store.machines.isEmpty) ...[
            const SizedBox(height: 22),
            _emptyActivity(),
            const SizedBox(height: 14),
            const InfoBox(
              'No celular, ative o Tailscale e cadastre a URL HTTPS do Tailscale Serve.',
              icon: Icons.shield_outlined,
            ),
          ],
          if (store.machines.isNotEmpty) ...[
            const SizedBox(height: 24),
            for (final machine in store.machines) ...[
              _machineCard(machine),
              const SizedBox(height: 12),
            ],
          ],
        ],
      ),
    );
  }

  Widget _machineCard(Machine machine) {
    final state = _health[machine.id] ?? 'Toque para verificar';
    final online = state.startsWith('Online');
    return Card(
      child: InkWell(
        borderRadius: appRadius,
        onTap: store.error != null
            ? null
            : () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => SessionsScreen(
                      store: store,
                      machine: machine,
                      apiFactory: widget.apiFactory,
                    ),
                  ),
                ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 10, 16),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color:
                      online ? AppColors.accentSoft : AppColors.surfaceHighest,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(
                  Icons.computer_outlined,
                  color: online ? AppColors.accent : AppColors.muted,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      machine.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      state,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: online ? AppColors.accent : AppColors.muted,
                          ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      machine.url,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: AppColors.muted,
                          ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Editar máquina',
                onPressed: store.error != null ? null : () => _edit(machine),
                icon: const Icon(Icons.tune),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecentSessionsResult {
  final Machine machine;
  final List<Session> sessions;
  final String? error, cursor;

  const _RecentSessionsResult(
    this.machine,
    this.sessions, {
    this.error,
    this.cursor,
  });
}

class MachineEditor extends StatefulWidget {
  final AppStore store;
  final Machine? machine;
  final OpenCodeApiFactory apiFactory;
  const MachineEditor(
      {super.key,
      required this.store,
      this.machine,
      this.apiFactory = OpenCodeApi.create});
  @override
  State<MachineEditor> createState() => _MachineEditorState();
}

class _MachineEditorState extends State<MachineEditor> {
  final form = GlobalKey<FormState>();
  late final TextEditingController name, url, user, password, directories;
  late AgentBackend backend;
  bool saving = false, obscure = true;
  @override
  void initState() {
    super.initState();
    final m = widget.machine;
    backend = m?.backend ?? AgentBackend.openCode;
    name = TextEditingController(text: m?.name ?? '');
    url = TextEditingController(text: m?.url ?? '');
    user = TextEditingController(text: m?.username ?? 'opencode');
    password = TextEditingController(text: m?.password ?? '');
    directories = TextEditingController(text: m?.directories.join('\n') ?? '');
  }

  @override
  void dispose() {
    for (final c in [name, url, user, password, directories]) {
      c.dispose();
    }
    super.dispose();
  }

  Machine _value() => Machine(
      id: widget.machine?.id ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      name: name.text.trim(),
      url: url.text.trim().replaceFirst(RegExp(r'/$'), ''),
      username: user.text.trim(),
      password: password.text,
      backend: backend,
      directories: directories.text
          .split('\n')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toSet()
          .toList());
  Future<void> _save(bool testOnly) async {
    if (!form.currentState!.validate()) return;
    setState(() => saving = true);
    try {
      final m = _value();
      if (testOnly) {
        final api = widget.apiFactory(m);
        try {
          final h = await api.health();
          if (h['healthy'] != true) {
            throw const ApiException(0, 'Servidor não está saudável.');
          }
          if (mounted) {
            notice(context,
                'Conectado ao ${backend.label} ${h['version'] ?? ''}.');
          }
        } finally {
          api.close();
        }
      } else {
        await widget.store.putMachine(m);
        if (mounted) Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) notice(context, e);
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> _delete() async {
    final yes = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
                title: const Text('Remover máquina?'),
                content: const Text(
                    'Remove o cadastro e os atalhos locais. As sessões no PC permanecem.'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(c, false),
                      child: const Text('Cancelar')),
                  FilledButton(
                      onPressed: () => Navigator.pop(c, true),
                      child: const Text('Remover'))
                ]));
    if (yes == true) {
      try {
        await widget.store.removeMachine(widget.machine!.id);
        if (mounted) Navigator.pop(context, true);
      } catch (e) {
        if (mounted) notice(context, e);
      }
    }
  }

  Future<void> _pair() async {
    if (backend != AgentBackend.openCode) {
      notice(context, 'Claude Code usa a senha dedicada do adaptador no host.');
      return;
    }
    final address = url.text.trim();
    if (validateServerUrl(address) != null || !address.startsWith('https://')) {
      notice(context, 'Informe primeiro a URL HTTPS da máquina.');
      return;
    }
    final token = await Navigator.push<String>(
        context,
        MaterialPageRoute(
          builder: (_) =>
              PairingScreen(machine: _value(), apiFactory: widget.apiFactory),
        ));
    if (token != null && mounted) {
      setState(() {
        password.text = token;
        obscure = true;
      });
      notice(context,
          'Pareamento confirmado com OpenCode v2. Salve a máquina para guardar a credencial.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.machine == null ? 'Conectar máquina' : 'Máquina'),
      ),
      body: Form(
        key: form,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(22, 10, 22, 28),
          children: [
            Text(
              widget.machine == null
                  ? 'Seu ambiente,\nsempre por perto.'
                  : 'Ajuste a conexão\ndo seu ambiente.',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    height: 1.1,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -.7,
                  ),
            ),
            const SizedBox(height: 9),
            Text(
              backend == AgentBackend.openCode
                  ? 'Use a URL HTTPS do Tailscale Serve e as credenciais do OpenCode.'
                  : 'Use a URL HTTPS do adaptador CodeRelay no computador. A senha é do adaptador, nunca a senha ou chave da Anthropic.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppColors.muted,
                    height: 1.4,
                  ),
            ),
            const SizedBox(height: 26),
            eyebrow('Identificação', color: AppColors.accent),
            const SizedBox(height: 12),
            DropdownButtonFormField<AgentBackend>(
              initialValue: backend,
              decoration: InputDecoration(
                labelText: 'Agente no computador',
                helperText: widget.machine == null
                    ? null
                    : 'Para outro agente, adicione um cadastro separado.',
              ),
              items: [
                for (final choice in AgentBackend.values)
                  DropdownMenuItem(value: choice, child: Text(choice.label)),
              ],
              onChanged: saving || widget.machine != null
                  ? null
                  : (choice) {
                      if (choice == null || choice == backend) {
                        return;
                      }
                      setState(() {
                        backend = choice;
                        password.clear();
                        user.text = choice == AgentBackend.openCode
                            ? 'opencode'
                            : 'coderelay';
                      });
                    },
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: saving
                  ? null
                  : () => Navigator.push<void>(
                        context,
                        MaterialPageRoute(
                            builder: (_) =>
                                MachineSetupScreen(backend: backend)),
                      ),
              icon: const Icon(Icons.help_outline),
              label: const Text('Como configurar no computador'),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: name,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Nome da máquina',
                hintText: 'Mac de casa',
                prefixIcon: Icon(Icons.computer_outlined),
              ),
              validator: (value) => value == null || value.trim().isEmpty
                  ? 'Informe um nome.'
                  : null,
            ),
            const SizedBox(height: 22),
            eyebrow('Conexão segura', color: AppColors.accent),
            const SizedBox(height: 12),
            TextFormField(
              controller: url,
              autocorrect: false,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: backend == AgentBackend.openCode
                    ? 'URL do OpenCode'
                    : 'URL do adaptador Claude Code',
                hintText: 'https://mac.tailnet.ts.net',
                prefixIcon: const Icon(Icons.link),
              ),
              validator: (value) {
                final address = value ?? '';
                final invalid = validateServerUrl(
                  address,
                  allowLoopbackHttp: allowLocalServerHttp,
                );
                if (invalid != null) {
                  return invalid;
                }
                if (address.startsWith('http:') && !allowTailnetHttp) {
                  return 'Este build exige HTTPS. Use a URL do Tailscale Serve.';
                }
                return null;
              },
            ),
            const SizedBox(height: 22),
            eyebrow('Autenticação', color: AppColors.accent),
            if (backend == AgentBackend.openCode)
              TextButton.icon(
                  onPressed: saving ? null : _pair,
                  icon: const Icon(Icons.link),
                  label: const Text('Usar código temporário de pareamento')),
            const SizedBox(height: 12),
            TextFormField(
              controller: user,
              autocorrect: false,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Usuário',
                prefixIcon: Icon(Icons.person_outline),
              ),
              validator: (value) =>
                  value == null || value.trim().isEmpty || value.contains(':')
                      ? 'Usuário obrigatório e sem dois-pontos.'
                      : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: password,
              obscureText: obscure,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: 'Senha do servidor',
                prefixIcon: const Icon(Icons.key_outlined),
                suffixIcon: IconButton(
                  tooltip: obscure ? 'Mostrar senha' : 'Ocultar senha',
                  onPressed: () => setState(() => obscure = !obscure),
                  icon: Icon(
                    obscure
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                ),
              ),
              validator: (value) => value == null || value.isEmpty
                  ? backend == AgentBackend.openCode
                      ? 'Defina OPENCODE_SERVER_PASSWORD na máquina.'
                      : 'Defina CODERELAY_ADAPTER_PASSWORD no adaptador.'
                  : null,
            ),
            const SizedBox(height: 12),
            const InfoBox(
              'A senha fica no armazenamento seguro do celular. Nunca compartilhe a URL do servidor fora da sua tailnet.',
              icon: Icons.shield_outlined,
            ),
            const SizedBox(height: 24),
            eyebrow('Acesso rápido', color: AppColors.accent),
            const SizedBox(height: 8),
            Text(
              'Opcional · um caminho remoto por linha',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.muted,
                  ),
            ),
            const SizedBox(height: 11),
            TextFormField(
              controller: directories,
              minLines: 2,
              maxLines: 5,
              autocorrect: false,
              textCapitalization: TextCapitalization.none,
              decoration: const InputDecoration(
                hintText: '/workspace/project-1',
                prefixIcon: Padding(
                  padding: EdgeInsets.only(bottom: 36),
                  child: Icon(Icons.folder_open_outlined),
                ),
              ),
            ),
            const SizedBox(height: 18),
            OutlinedButton.icon(
              onPressed: saving
                  ? null
                  : () {
                      if (!form.currentState!.validate()) {
                        return;
                      }
                      Navigator.push<void>(
                        context,
                        MaterialPageRoute(
                          builder: (_) => ConnectionDiagnosticsScreen(
                            machine: _value(),
                            apiFactory: widget.apiFactory,
                          ),
                        ),
                      );
                    },
              icon: const Icon(Icons.network_check),
              label: const Text('Diagnóstico de conexão'),
            ),
            if (widget.machine != null) ...[
              const SizedBox(height: 18),
              OutlinedButton.icon(
                onPressed: saving ? null : _delete,
                icon: const Icon(Icons.delete_outline),
                label: const Text('Remover cadastro desta máquina'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.danger,
                ),
              ),
            ],
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (saving) ...[
                const LinearProgressIndicator(),
                const SizedBox(height: 10),
              ],
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: saving ? null : () => _save(true),
                      icon: const Icon(Icons.wifi_tethering),
                      label: const Text('Testar'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: FilledButton.icon(
                      onPressed: saving ? null : () => _save(false),
                      icon: const Icon(Icons.check),
                      label: Text(
                        widget.machine == null
                            ? 'Salvar máquina'
                            : 'Salvar alterações',
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
