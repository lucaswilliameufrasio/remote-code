import 'package:flutter/material.dart';
import '../core/api.dart';
import '../core/concurrency.dart';
import '../core/models.dart';
import '../core/store.dart';
import 'common.dart';
import 'design.dart';

class ProjectTarget {
  final Machine machine;
  final String directory;
  final String? projectID, name;
  final int recentSessionCount, lastOpened;

  const ProjectTarget({
    required this.machine,
    required this.directory,
    required this.recentSessionCount,
    required this.lastOpened,
    this.projectID,
    this.name,
  });

  String get displayName =>
      name?.trim().isNotEmpty == true ? name! : folderName(directory);

  String get identity => projectID ?? directory;
}

List<ProjectTarget> buildProjectTargets({
  required List<Machine> machines,
  required List<Bookmark> bookmarks,
  required Map<String, List<OpenCodeProject>> serverProjects,
}) {
  final projectTargets = <String, ProjectTarget>{};

  for (final machine in machines) {
    final machineBookmarks = bookmarks
        .where((bookmark) => bookmark.machineID == machine.id)
        .toList();
    final projects = serverProjects[machine.id] ?? const <OpenCodeProject>[];

    for (final project in projects) {
      final matchingBookmarks = machineBookmarks
          .where((bookmark) =>
              bookmark.session.projectID == project.id ||
              (project.worktree != null &&
                  _sameRemoteDirectory(
                    bookmark.session.directory,
                    project.worktree!,
                  )))
          .toList();
      final directory =
          project.worktree ?? _firstNonEmptyDirectory(matchingBookmarks);
      if (directory == null || directory.isEmpty) {
        continue;
      }
      final targetKey = '${machine.id}:project:${project.id}';
      projectTargets[targetKey] = ProjectTarget(
        machine: machine,
        projectID: project.id,
        directory: directory,
        name: project.name,
        recentSessionCount: matchingBookmarks.length,
        lastOpened: _latestBookmarkTime(matchingBookmarks),
      );
    }

    for (final bookmark in machineBookmarks) {
      final directory = bookmark.session.directory;
      if (directory.isEmpty ||
          _hasProjectForBookmark(projects, bookmark, projectTargets, machine)) {
        continue;
      }
      _addDirectoryFallback(
        projectTargets,
        machine: machine,
        directory: directory,
        projectID: bookmark.session.projectID,
        bookmarks: machineBookmarks,
      );
    }

    for (final directory in machine.directories) {
      if (!_hasTargetForDirectory(projectTargets.values, machine, directory)) {
        _addDirectoryFallback(
          projectTargets,
          machine: machine,
          directory: directory,
          bookmarks: machineBookmarks,
        );
      }
    }
  }

  final targets = projectTargets.values.toList();
  targets.sort((first, second) {
    final recentComparison = second.lastOpened.compareTo(first.lastOpened);
    if (recentComparison != 0) {
      return recentComparison;
    }
    final nameComparison = first.displayName
        .toLowerCase()
        .compareTo(second.displayName.toLowerCase());
    if (nameComparison != 0) {
      return nameComparison;
    }
    return first.machine.name.compareTo(second.machine.name);
  });
  return targets;
}

String? _firstNonEmptyDirectory(List<Bookmark> bookmarks) {
  for (final bookmark in bookmarks) {
    if (bookmark.session.directory.isNotEmpty) {
      return bookmark.session.directory;
    }
  }
  return null;
}

int _latestBookmarkTime(List<Bookmark> bookmarks) {
  var latestOpened = 0;
  for (final bookmark in bookmarks) {
    if (bookmark.opened > latestOpened) {
      latestOpened = bookmark.opened;
    }
  }
  return latestOpened;
}

bool _hasProjectForBookmark(
  List<OpenCodeProject> projects,
  Bookmark bookmark,
  Map<String, ProjectTarget> knownTargets,
  Machine machine,
) {
  for (final project in projects) {
    if (project.id == bookmark.session.projectID &&
        knownTargets.containsKey('${machine.id}:project:${project.id}')) {
      return true;
    }
    final worktree = project.worktree;
    if (worktree != null &&
        _sameRemoteDirectory(bookmark.session.directory, worktree) &&
        knownTargets.containsKey('${machine.id}:project:${project.id}')) {
      return true;
    }
  }
  return false;
}

bool _hasTargetForDirectory(
  Iterable<ProjectTarget> targets,
  Machine machine,
  String directory,
) {
  for (final target in targets) {
    if (target.machine.id == machine.id &&
        _sameRemoteDirectory(target.directory, directory)) {
      return true;
    }
  }
  return false;
}

void _addDirectoryFallback(
  Map<String, ProjectTarget> targets, {
  required Machine machine,
  required String directory,
  required List<Bookmark> bookmarks,
  String? projectID,
}) {
  final directoryBookmarks = bookmarks
      .where((bookmark) =>
          (projectID != null && bookmark.session.projectID == projectID) ||
          _sameRemoteDirectory(bookmark.session.directory, directory))
      .toList();
  final targetIdentity = projectID ?? _normalizeRemoteDirectory(directory);
  final targetKey = '${machine.id}:directory:$targetIdentity';
  targets.putIfAbsent(
    targetKey,
    () => ProjectTarget(
      machine: machine,
      projectID: projectID,
      directory: directory,
      recentSessionCount: directoryBookmarks.length,
      lastOpened: _latestBookmarkTime(directoryBookmarks),
    ),
  );
}

bool _sameRemoteDirectory(String first, String second) =>
    _normalizeRemoteDirectory(first) == _normalizeRemoteDirectory(second);

String _normalizeRemoteDirectory(String directory) {
  var normalizedDirectory = directory.trim();
  while (normalizedDirectory.length > 1 && normalizedDirectory.endsWith('/')) {
    normalizedDirectory = normalizedDirectory.substring(
      0,
      normalizedDirectory.length - 1,
    );
  }
  return normalizedDirectory;
}

class ProjectsScreen extends StatefulWidget {
  final AppStore store;
  final OpenCodeApiFactory apiFactory;
  final Future<void> Function(ProjectTarget project) onOpenProject;

  const ProjectsScreen({
    super.key,
    required this.store,
    required this.apiFactory,
    required this.onOpenProject,
  });

  @override
  State<ProjectsScreen> createState() => ProjectsScreenState();
}

class ProjectsScreenState extends State<ProjectsScreen> {
  static const int machineQueryConcurrency = 3;

  List<ProjectTarget> projects = [];
  List<String> errors = [];
  bool loading = false;
  int generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> refresh() => _load();

  Future<void> _load() async {
    if (loading) {
      return;
    }
    final currentGeneration = ++generation;
    if (mounted) {
      setState(() {
        loading = true;
        errors = [];
      });
    }

    final machineResults = await mapConcurrent<Machine, _MachineProjectResult>(
      items: widget.store.machines,
      concurrency: machineQueryConcurrency,
      operation: _loadMachineProjects,
    );
    if (!mounted || currentGeneration != generation) {
      return;
    }

    final projectsByMachine = <String, List<OpenCodeProject>>{};
    final loadErrors = <String>[];
    for (final result in machineResults) {
      projectsByMachine[result.machine.id] = result.projects;
      if (result.error != null) {
        loadErrors.add('${result.machine.name}: ${result.error}');
      }
    }
    setState(() {
      projects = buildProjectTargets(
        machines: widget.store.machines,
        bookmarks: widget.store.bookmarks,
        serverProjects: projectsByMachine,
      );
      errors = loadErrors;
      loading = false;
    });
  }

  Future<_MachineProjectResult> _loadMachineProjects(Machine machine) async {
    final api = widget.apiFactory(machine);
    try {
      return _MachineProjectResult(machine, await api.projects());
    } catch (exception) {
      return _MachineProjectResult(
        machine,
        const [],
        error: exception.toString(),
      );
    } finally {
      api.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: refresh,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(22, 18, 22, 30),
        children: [
          eyebrow('Trabalho organizado por projeto', color: AppColors.accent),
          const SizedBox(height: 8),
          Text(
            'Projetos',
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 7),
          Text(
            'Abra as sessões de um repositório conhecido em cada máquina.',
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: AppColors.muted),
          ),
          if (errors.isNotEmpty) ...[
            const SizedBox(height: 16),
            for (final error in errors) ...[
              InfoBox(error, icon: Icons.cloud_off),
              const SizedBox(height: 8),
            ],
          ],
          if (loading && projects.isEmpty) ...[
            const SizedBox(height: 32),
            const Center(child: CircularProgressIndicator()),
          ] else if (projects.isEmpty) ...[
            const SizedBox(height: 20),
            _emptyProjects(),
          ] else ...[
            const SizedBox(height: 20),
            for (final project in projects) ...[
              _projectCard(project),
              const SizedBox(height: 10),
            ],
          ],
        ],
      ),
    );
  }

  Widget _emptyProjects() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.folder_open_outlined, color: AppColors.accent),
            const SizedBox(height: 12),
            Text(
              'Nenhum projeto conhecido ainda',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              widget.store.machines.isEmpty
                  ? 'Conecte uma máquina para carregar os projetos do OpenCode.'
                  : 'Abra uma sessão ou cadastre um diretório para encontrá-lo aqui.',
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

  Widget _projectCard(ProjectTarget project) {
    return Card(
      child: InkWell(
        borderRadius: appRadius,
        onTap: () => widget.onOpenProject(project),
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
                child: const Icon(
                  Icons.folder_outlined,
                  color: AppColors.accent,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      project.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      project.machine.name,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: AppColors.accent),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      project.directory,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context)
                          .textTheme
                          .labelSmall
                          ?.copyWith(color: AppColors.muted),
                    ),
                    if (project.recentSessionCount > 0) ...[
                      const SizedBox(height: 7),
                      Text(
                        '${project.recentSessionCount} sessões recentes',
                        style: Theme.of(context)
                            .textTheme
                            .labelSmall
                            ?.copyWith(color: AppColors.muted),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right, color: AppColors.muted),
            ],
          ),
        ),
      ),
    );
  }
}

class _MachineProjectResult {
  final Machine machine;
  final List<OpenCodeProject> projects;
  final String? error;

  const _MachineProjectResult(this.machine, this.projects, {this.error});
}
