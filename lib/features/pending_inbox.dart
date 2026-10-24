import 'package:flutter/material.dart';
import '../core/api.dart';
import '../core/concurrency.dart';
import '../core/models.dart';
import '../core/store.dart';
import 'common.dart';
import 'design.dart';

enum PendingActionKind { question, permission }

class PendingAction {
  final Machine machine;
  final Session session;
  final PendingActionKind kind;
  final Json request;

  const PendingAction({
    required this.machine,
    required this.session,
    required this.kind,
    required this.request,
  });

  String get title {
    if (kind == PendingActionKind.question) {
      final formTitle = request['title'] as String?;
      if (formTitle != null && formTitle.trim().isNotEmpty) {
        return formTitle;
      }
      final fields = objects(request['fields']);
      if (fields.isNotEmpty && fields.first['title'] is String) {
        return fields.first['title'] as String;
      }
      return 'O agente aguarda sua resposta';
    }
    return 'Aprovação necessária';
  }

  String get detail {
    if (kind == PendingActionKind.question) {
      final fields = objects(request['fields']);
      if (fields.isNotEmpty && fields.first['title'] is String) {
        return fields.first['title'] as String;
      }
      return 'Formulário pendente';
    }

    final permission = request['permission'] as String? ?? 'ferramenta';
    final patterns = request['patterns'];
    final resources =
        patterns is List ? patterns.whereType<String>().join(' · ') : '';
    return resources.isEmpty ? 'Permissão: $permission' : resources;
  }
}

class PendingInboxSnapshot {
  final List<PendingAction> actions;
  final int checkedLocations, totalLocations, failures;
  final bool truncated;
  final List<String> machineErrors;

  const PendingInboxSnapshot({
    required this.actions,
    required this.checkedLocations,
    required this.totalLocations,
    required this.failures,
    required this.truncated,
    required this.machineErrors,
  });
}

class PendingInboxScanner {
  static const int machineConcurrency = 3;
  static const int requestConcurrency = 4;
  static const int maxBookmarkedSessions = 100;
  static const int maxRecentSessionsPerMachine = 100;
  static const int maxUnbookmarkedActiveSessions = 20;
  static const int maxDirectoriesPerMachine = 100;
  static const int maxPendingActions = 200;
  static const int maxPendingSessions = 100;

  final OpenCodeApiFactory apiFactory;

  const PendingInboxScanner({required this.apiFactory});

  Future<PendingInboxSnapshot> scan({
    required List<Machine> machines,
    required List<Bookmark> bookmarks,
    void Function(int checked, int total)? onProgress,
  }) async {
    final machineContexts = await mapConcurrent<Machine, _MachineScanContext>(
      items: machines,
      concurrency: machineConcurrency,
      operation: _loadMachineContext,
    );
    final machineErrors = <String>[
      for (final context in machineContexts)
        if (context.healthError != null)
          '${context.machine.name}: ${context.healthError}',
      for (final context in machineContexts)
        if (context.statusError != null)
          '${context.machine.name}: ${context.statusError}',
      for (final context in machineContexts)
        if (context.projectsError != null)
          '${context.machine.name}: ${context.projectsError}',
      for (final context in machineContexts)
        if (context.sessionsError != null)
          '${context.machine.name}: ${context.sessionsError}',
    ];

    final locationsByMachine = <String, _MachineLocations>{};
    final sessionsByKey = <String, Session>{};
    for (final context in machineContexts) {
      if (context.healthError != null) {
        continue;
      }
      final machineLocations = _MachineLocations();
      locationsByMachine[context.machine.id] = machineLocations;
      for (final directory in context.machine.directories) {
        machineLocations.add(directory);
      }
      for (final project in context.projects) {
        final worktree = project.worktree;
        if (worktree != null) {
          machineLocations.add(worktree);
        }
      }
      for (final session in context.recentSessions) {
        sessionsByKey[_sessionKey(context.machine.id, session.id)] = session;
        machineLocations.add(session.directory);
      }
    }

    final bookmarkedSessions = bookmarks.take(maxBookmarkedSessions).toList();
    var truncated = bookmarks.length > maxBookmarkedSessions ||
        machineContexts.any((context) => context.hasMoreRecentSessions);
    for (final bookmark in bookmarkedSessions) {
      final machineLocations = locationsByMachine[bookmark.machineID];
      if (machineLocations == null) {
        continue;
      }
      sessionsByKey[_sessionKey(bookmark.machineID, bookmark.session.id)] =
          bookmark.session;
      machineLocations.add(bookmark.session.directory);
    }

    final activeSessionReferences = <_PendingCandidate>[];
    for (final context in machineContexts) {
      if (context.healthError != null) {
        continue;
      }
      for (final sessionID in context.activeStatuses.keys) {
        if (sessionID.isEmpty) {
          continue;
        }
        final candidateKey = _sessionKey(context.machine.id, sessionID);
        if (sessionsByKey.containsKey(candidateKey)) {
          continue;
        }
        final candidate = _PendingCandidate(
          context.machine,
          Session(id: sessionID, title: 'Sessão ativa', directory: ''),
        );
        activeSessionReferences.add(candidate);
      }
    }
    activeSessionReferences.sort((first, second) {
      final machineComparison = first.machine.id.compareTo(second.machine.id);
      if (machineComparison != 0) {
        return machineComparison;
      }
      return first.session.id.compareTo(second.session.id);
    });
    final selectedActiveReferences =
        activeSessionReferences.take(maxUnbookmarkedActiveSessions).toList();
    if (activeSessionReferences.length > maxUnbookmarkedActiveSessions) {
      truncated = true;
    }

    final activeSessionResults =
        await mapConcurrent<_PendingCandidate, _SessionLookup>(
      items: selectedActiveReferences,
      concurrency: requestConcurrency,
      operation: (candidate) async {
        final api = apiFactory(candidate.machine);
        try {
          final session = await api.getSession(candidate.session.id);
          return _SessionLookup(
            machine: candidate.machine,
            sessionID: candidate.session.id,
            session: session,
          );
        } catch (exception) {
          return _SessionLookup(
            machine: candidate.machine,
            sessionID: candidate.session.id,
            error: '${candidate.machine.name}: ${exception.toString()}',
          );
        } finally {
          api.close();
        }
      },
    );

    for (final result in activeSessionResults) {
      if (result.session != null) {
        sessionsByKey[_sessionKey(result.machine.id, result.sessionID)] =
            result.session!;
        locationsByMachine[result.machine.id]?.add(
          result.session!.directory,
        );
      } else if (result.error != null) {
        machineErrors.add(result.error!);
      }
    }

    final locationsToCheck = <_LocationScan>[];
    for (final context in machineContexts) {
      if (context.healthError != null) {
        continue;
      }
      locationsToCheck.add(_LocationScan(context.machine));
      final directories =
          locationsByMachine[context.machine.id]?.directories ?? const [];
      if (directories.length > maxDirectoriesPerMachine) {
        truncated = true;
      }
      for (final directory in directories.take(maxDirectoriesPerMachine)) {
        locationsToCheck.add(_LocationScan(context.machine, directory));
      }
    }

    var checkedLocations = 0;
    final locationResults = await mapConcurrent<_LocationScan, _LocationResult>(
      items: locationsToCheck,
      concurrency: machineConcurrency,
      operation: (location) async {
        final result = await _readLocation(location);
        checkedLocations++;
        onProgress?.call(checkedLocations, locationsToCheck.length);
        return result;
      },
    );

    var failures = 0;
    final pendingByKey = <String, _PendingReference>{};
    for (final result in locationResults) {
      for (final error in result.errors) {
        machineErrors.add(error);
        failures++;
      }
      _addPendingReferences(
        pendingByKey,
        result.location.machine,
        PendingActionKind.question,
        result.questions,
      );
      _addPendingReferences(
        pendingByKey,
        result.location.machine,
        PendingActionKind.permission,
        result.permissions,
      );
    }

    final pendingReferences = pendingByKey.values.toList();
    pendingReferences.sort((first, second) {
      final machineComparison = first.machine.id.compareTo(second.machine.id);
      if (machineComparison != 0) {
        return machineComparison;
      }
      final sessionComparison = first.sessionID.compareTo(second.sessionID);
      if (sessionComparison != 0) {
        return sessionComparison;
      }
      final kindComparison = first.kind.index.compareTo(second.kind.index);
      if (kindComparison != 0) {
        return kindComparison;
      }
      return first.requestID.compareTo(second.requestID);
    });
    if (pendingReferences.length > maxPendingActions) {
      truncated = true;
    }
    final limitedPendingReferences =
        pendingReferences.take(maxPendingActions).toList();

    final sessionsToLoadByKey = <String, _PendingSessionReference>{};
    for (final reference in limitedPendingReferences) {
      final key = _sessionKey(reference.machine.id, reference.sessionID);
      if (!sessionsByKey.containsKey(key)) {
        sessionsToLoadByKey.putIfAbsent(
          key,
          () =>
              _PendingSessionReference(reference.machine, reference.sessionID),
        );
      }
    }
    final sessionsToLoad = sessionsToLoadByKey.values.toList();
    if (sessionsToLoad.length > maxPendingSessions) {
      truncated = true;
    }
    final limitedSessionsToLoad =
        sessionsToLoad.take(maxPendingSessions).toList();
    final pendingSessionLookups =
        await mapConcurrent<_PendingSessionReference, _SessionLookup>(
      items: limitedSessionsToLoad,
      concurrency: requestConcurrency,
      operation: (reference) async {
        final api = apiFactory(reference.machine);
        try {
          final session = await api.getSession(reference.sessionID);
          return _SessionLookup(
            machine: reference.machine,
            sessionID: reference.sessionID,
            session: session,
          );
        } catch (exception) {
          return _SessionLookup(
            machine: reference.machine,
            sessionID: reference.sessionID,
            error:
                '${reference.machine.name}: não foi possível abrir a sessão ${reference.sessionID}: $exception',
          );
        } finally {
          api.close();
        }
      },
    );

    for (final lookup in pendingSessionLookups) {
      if (lookup.session != null) {
        sessionsByKey[_sessionKey(lookup.machine.id, lookup.sessionID)] =
            lookup.session!;
      } else if (lookup.error != null) {
        failures++;
        machineErrors.add(lookup.error!);
      }
    }

    final actions = <PendingAction>[];
    for (final reference in limitedPendingReferences) {
      final key = _sessionKey(reference.machine.id, reference.sessionID);
      final session = sessionsByKey[key];
      if (session == null) {
        continue;
      }
      actions.add(
        PendingAction(
          machine: reference.machine,
          session: session,
          kind: reference.kind,
          request: reference.request,
        ),
      );
    }
    actions.sort((first, second) {
      final updatedComparison =
          second.session.updated.compareTo(first.session.updated);
      if (updatedComparison != 0) {
        return updatedComparison;
      }
      final kindComparison = first.kind.index.compareTo(second.kind.index);
      if (kindComparison != 0) {
        return kindComparison;
      }
      final machineComparison = first.machine.id.compareTo(second.machine.id);
      if (machineComparison != 0) {
        return machineComparison;
      }
      final sessionComparison = first.session.id.compareTo(second.session.id);
      if (sessionComparison != 0) {
        return sessionComparison;
      }
      return (first.request['id'] as String)
          .compareTo(second.request['id'] as String);
    });

    return PendingInboxSnapshot(
      actions: actions,
      checkedLocations: checkedLocations,
      totalLocations: locationsToCheck.length,
      failures: failures,
      truncated: truncated,
      machineErrors: machineErrors,
    );
  }

  Future<_MachineScanContext> _loadMachineContext(Machine machine) async {
    final api = apiFactory(machine);
    try {
      try {
        await api.health();
      } catch (exception) {
        return _MachineScanContext(
          machine: machine,
          activeStatuses: const {},
          projects: const [],
          healthError: exception.toString(),
        );
      }

      Json activeStatuses = {};
      List<OpenCodeProject> projects = [];
      List<Session> recentSessions = [];
      var hasMoreRecentSessions = false;
      String? statusError;
      String? projectsError;
      String? sessionsError;
      try {
        activeStatuses = await api.statuses();
      } catch (exception) {
        statusError = exception.toString();
      }
      try {
        projects = await api.projects();
      } catch (exception) {
        projectsError = exception.toString();
      }
      try {
        final page = await api.listAll();
        recentSessions =
            page.sessions.take(maxRecentSessionsPerMachine).toList();
        hasMoreRecentSessions = page.cursor != null ||
            page.sessions.length > maxRecentSessionsPerMachine;
      } catch (exception) {
        sessionsError = exception.toString();
      }
      return _MachineScanContext(
        machine: machine,
        activeStatuses: activeStatuses,
        projects: projects,
        recentSessions: recentSessions,
        hasMoreRecentSessions: hasMoreRecentSessions,
        statusError: statusError,
        projectsError: projectsError,
        sessionsError: sessionsError,
      );
    } finally {
      api.close();
    }
  }

  Future<_LocationResult> _readLocation(_LocationScan location) async {
    final api = apiFactory(location.machine);
    try {
      final results = await Future.wait([
        _readPendingForLocation(api, 'question', location.directory),
        _readPendingForLocation(api, 'permission', location.directory),
      ]);
      return _LocationResult(
        location: location,
        questions: results[0].requests,
        permissions: results[1].requests,
        errors: [
          for (final result in results)
            if (result.error != null)
              '${location.machine.name}${location.directory == null ? '' : ' · ${location.directory}'}: ${result.error}',
        ],
      );
    } finally {
      api.close();
    }
  }

  Future<_PendingEndpointResult> _readPendingForLocation(
    OpenCodeApi api,
    String kind,
    String? directory,
  ) async {
    try {
      return _PendingEndpointResult(
        await api.pendingForLocation(kind, directory: directory),
      );
    } catch (exception) {
      return _PendingEndpointResult([], error: exception.toString());
    }
  }

  void _addPendingReferences(
    Map<String, _PendingReference> pendingByKey,
    Machine machine,
    PendingActionKind kind,
    List<Json> requests,
  ) {
    for (final request in requests) {
      final requestID = request['id'];
      final sessionID = request['sessionID'];
      if (requestID is! String ||
          requestID.isEmpty ||
          sessionID is! String ||
          sessionID.isEmpty) {
        continue;
      }
      final key = '${machine.id}:${kind.index}:$sessionID:$requestID';
      pendingByKey.putIfAbsent(
        key,
        () => _PendingReference(
          machine: machine,
          sessionID: sessionID,
          kind: kind,
          requestID: requestID,
          request: request,
        ),
      );
    }
  }

  static String _sessionKey(String machineID, String sessionID) =>
      '$machineID:$sessionID';
}

class PendingInboxScreen extends StatefulWidget {
  final AppStore store;
  final OpenCodeApiFactory apiFactory;
  final Future<void> Function(PendingAction action) onOpenAction;
  final ValueChanged<int> onCountChanged;

  const PendingInboxScreen({
    super.key,
    required this.store,
    required this.apiFactory,
    required this.onOpenAction,
    required this.onCountChanged,
  });

  @override
  State<PendingInboxScreen> createState() => PendingInboxScreenState();
}

class PendingInboxScreenState extends State<PendingInboxScreen> {
  PendingInboxSnapshot? snapshot;
  int checkedLocations = 0, totalLocations = 0, generation = 0;
  bool loading = false;
  String? error;

  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<void> refresh() async {
    if (loading) {
      return;
    }
    final currentGeneration = ++generation;
    setState(() {
      loading = true;
      checkedLocations = 0;
      totalLocations = 0;
      error = null;
    });

    try {
      final loadedSnapshot = await PendingInboxScanner(
        apiFactory: widget.apiFactory,
      ).scan(
        machines: widget.store.machines,
        bookmarks: widget.store.bookmarks,
        onProgress: (checked, total) {
          if (mounted && currentGeneration == generation) {
            setState(() {
              checkedLocations = checked;
              totalLocations = total;
            });
          }
        },
      );
      if (!mounted || currentGeneration != generation) {
        return;
      }
      setState(() {
        snapshot = loadedSnapshot;
        checkedLocations = loadedSnapshot.checkedLocations;
        totalLocations = loadedSnapshot.totalLocations;
        loading = false;
      });
      widget.onCountChanged(loadedSnapshot.actions.length);
    } catch (exception) {
      if (!mounted || currentGeneration != generation) {
        return;
      }
      setState(() {
        error = exception.toString();
        loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final pendingActions = snapshot?.actions ?? const <PendingAction>[];
    final scanProgress = totalLocations == 0
        ? 'Consultando localizações dos agentes…'
        : 'Verificando $checkedLocations de $totalLocations localizações…';

    return RefreshIndicator(
      onRefresh: refresh,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(22, 18, 22, 32),
        children: [
          eyebrow('Aguardando você', color: AppColors.warning),
          const SizedBox(height: 8),
          Text(
            'Pendências',
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 7),
          Text(
            'Perguntas e permissões que podem desbloquear uma sessão.',
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: AppColors.muted),
          ),
          if (loading) ...[
            const SizedBox(height: 18),
            const LinearProgressIndicator(),
            const SizedBox(height: 8),
            Text(
              scanProgress,
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: AppColors.muted),
            ),
          ],
          if (error != null) ...[
            const SizedBox(height: 16),
            InfoBox(error!, icon: Icons.error_outline),
          ],
          if (snapshot != null) ...[
            const SizedBox(height: 16),
            _scanSummary(snapshot!),
            if (snapshot!.machineErrors.isNotEmpty) ...[
              const SizedBox(height: 10),
              for (final machineError in snapshot!.machineErrors) ...[
                InfoBox(machineError, icon: Icons.cloud_off),
                const SizedBox(height: 8),
              ],
            ],
            if (snapshot!.failures > 0) ...[
              const SizedBox(height: 8),
              InfoBox(
                'Não foi possível consultar todas as solicitações. Atualize para tentar de novo.',
                icon: Icons.error_outline,
              ),
            ],
            if (snapshot!.truncated) ...[
              const SizedBox(height: 8),
              const InfoBox(
                'A verificação atingiu um limite de segurança para atalhos, sessões ativas, diretórios ou ações pendentes.',
              ),
            ],
          ],
          if (!loading && snapshot != null && pendingActions.isEmpty) ...[
            const SizedBox(height: 14),
            _emptyState(),
          ],
          if (pendingActions.isNotEmpty) ...[
            const SizedBox(height: 18),
            for (final action in pendingActions) ...[
              _actionCard(action),
              const SizedBox(height: 10),
            ],
          ],
          if (!loading && snapshot == null && error == null) ...[
            const SizedBox(height: 20),
            _emptyState(),
          ],
        ],
      ),
    );
  }

  Widget _scanSummary(PendingInboxSnapshot currentSnapshot) {
    return Card(
      color: AppColors.surfaceRaised,
      child: Padding(
        padding: const EdgeInsets.all(15),
        child: Row(
          children: [
            Icon(
              currentSnapshot.actions.isEmpty
                  ? Icons.check_circle_outline
                  : Icons.notification_important_outlined,
              color: currentSnapshot.actions.isEmpty
                  ? AppColors.accent
                  : AppColors.warning,
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Text(
                currentSnapshot.actions.isEmpty
                    ? 'Nenhuma ação pendente nas localizações verificadas.'
                    : '${currentSnapshot.actions.length} ações precisam da sua atenção.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ),
            IconButton(
              tooltip: 'Atualizar pendências',
              onPressed: loading ? null : refresh,
              icon: const Icon(Icons.sync),
            ),
          ],
        ),
      ),
    );
  }

  Widget _emptyState() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.done_all, color: AppColors.accent),
            const SizedBox(height: 12),
            Text(
              'Tudo em dia',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              'Puxe para atualizar. O CodeRelay consulta as solicitações das localizações conhecidas deste servidor.',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: AppColors.muted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _actionCard(PendingAction action) {
    final isQuestion = action.kind == PendingActionKind.question;
    return Card(
      color: AppColors.surfaceRaised,
      shape: RoundedRectangleBorder(
        borderRadius: appRadius,
        side: BorderSide(color: AppColors.warning.withValues(alpha: .35)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  isQuestion ? Icons.help_outline : Icons.shield_outlined,
                  color: AppColors.warning,
                  size: 19,
                ),
                const SizedBox(width: 8),
                Text(
                  isQuestion ? 'PERGUNTA' : 'PERMISSÃO',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: AppColors.warning,
                        fontWeight: FontWeight.w800,
                        letterSpacing: .8,
                      ),
                ),
              ],
            ),
            const SizedBox(height: 9),
            Text(
              action.title,
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 5),
            Text(
              action.detail,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: AppColors.muted),
            ),
            const SizedBox(height: 9),
            Text(
              '${action.session.title} · ${action.machine.name} · ${folderName(action.session.directory)}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: AppColors.muted),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonalIcon(
                onPressed: () async {
                  await widget.onOpenAction(action);
                  if (mounted) {
                    await refresh();
                  }
                },
                icon: const Icon(Icons.open_in_new, size: 17),
                label: const Text('Abrir sessão'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MachineScanContext {
  final Machine machine;
  final Json activeStatuses;
  final List<OpenCodeProject> projects;
  final List<Session> recentSessions;
  final bool hasMoreRecentSessions;
  final String? healthError, statusError, projectsError, sessionsError;

  const _MachineScanContext({
    required this.machine,
    required this.activeStatuses,
    required this.projects,
    this.recentSessions = const [],
    this.hasMoreRecentSessions = false,
    this.healthError,
    this.statusError,
    this.projectsError,
    this.sessionsError,
  });
}

class _MachineLocations {
  final List<String> directories = [];
  final Set<String> normalizedDirectories = {};

  void add(String directory) {
    final normalizedDirectory = _normalizeDirectory(directory);
    if (normalizedDirectory.isEmpty ||
        !normalizedDirectories.add(normalizedDirectory)) {
      return;
    }
    directories.add(normalizedDirectory);
  }
}

class _PendingCandidate {
  final Machine machine;
  final Session session;

  const _PendingCandidate(this.machine, this.session);

  String get key => '${machine.id}:${session.id}';
}

class _SessionLookup {
  final Machine machine;
  final String sessionID;
  final Session? session;
  final String? error;

  const _SessionLookup({
    required this.machine,
    required this.sessionID,
    this.session,
    this.error,
  });
}

class _LocationScan {
  final Machine machine;
  final String? directory;

  const _LocationScan(this.machine, [this.directory]);
}

class _LocationResult {
  final _LocationScan location;
  final List<Json> questions, permissions;
  final List<String> errors;

  const _LocationResult({
    required this.location,
    required this.questions,
    required this.permissions,
    required this.errors,
  });
}

class _PendingEndpointResult {
  final List<Json> requests;
  final String? error;

  const _PendingEndpointResult(this.requests, {this.error});
}

class _PendingReference {
  final Machine machine;
  final String sessionID, requestID;
  final PendingActionKind kind;
  final Json request;

  const _PendingReference({
    required this.machine,
    required this.sessionID,
    required this.requestID,
    required this.kind,
    required this.request,
  });
}

class _PendingSessionReference {
  final Machine machine;
  final String sessionID;

  const _PendingSessionReference(this.machine, this.sessionID);
}

String _normalizeDirectory(String directory) {
  var normalizedDirectory = directory.trim();
  while (normalizedDirectory.length > 1 && normalizedDirectory.endsWith('/')) {
    normalizedDirectory = normalizedDirectory.substring(
      0,
      normalizedDirectory.length - 1,
    );
  }
  return normalizedDirectory;
}
