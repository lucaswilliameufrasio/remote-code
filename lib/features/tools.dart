import 'package:flutter/material.dart';
import '../core/api.dart';
import '../core/models.dart';
import 'common.dart';
import 'design.dart';

class SessionToolsScreen extends StatefulWidget {
  final Machine machine;
  final Session session;
  final OpenCodeApi? api;

  const SessionToolsScreen({
    super.key,
    required this.machine,
    required this.session,
    this.api,
  });

  @override
  State<SessionToolsScreen> createState() => _SessionToolsScreenState();
}

class _SessionToolsScreenState extends State<SessionToolsScreen> {
  late final OpenCodeApi api;
  late final bool ownsApi;
  List<Json> servers = [];
  List<Json> skills = [];
  final Set<String> mcpMutations = {};
  String? mcpError;
  String? skillsError;
  String? sessionStatusError;
  String sessionStatus = 'unknown';
  String? activatingSkill;
  bool loading = true;
  bool refreshing = false;

  bool get sessionBusy =>
      sessionStatus == 'running' ||
      sessionStatus == 'busy' ||
      sessionStatus == 'retry';

  bool get canActivateSkill =>
      sessionStatusError == null && sessionStatus == 'idle';

  @override
  void initState() {
    super.initState();
    ownsApi = widget.api == null;
    api = widget.api ?? OpenCodeApi(widget.machine);
    _loadCapabilities();
  }

  @override
  void dispose() {
    if (ownsApi) {
      api.close();
    }
    super.dispose();
  }

  Future<(List<Json>?, String?)> _loadServers() async {
    try {
      return (await api.mcpServers(widget.session.directory), null);
    } catch (exception) {
      return (null, exception.toString());
    }
  }

  Future<(List<Json>?, String?)> _loadSkills() async {
    try {
      return (await api.skills(widget.session.directory), null);
    } catch (exception) {
      return (null, exception.toString());
    }
  }

  Future<(String?, String?)> _loadSessionStatus() async {
    try {
      final statuses = await api.statuses();
      final status = object(object(statuses[widget.session.id]))['type'];
      return (status is String ? status : 'idle', null);
    } catch (exception) {
      return (null, exception.toString());
    }
  }

  Future<void> _loadCapabilities() async {
    if (refreshing) {
      return;
    }
    refreshing = true;
    if (!loading && mounted) {
      setState(() => loading = true);
    }
    final results = await Future.wait<dynamic>([
      _loadServers(),
      _loadSkills(),
      _loadSessionStatus(),
    ]);
    if (mounted) {
      final serverResult = results[0] as (List<Json>?, String?);
      final skillResult = results[1] as (List<Json>?, String?);
      final statusResult = results[2] as (String?, String?);
      setState(() {
        servers = serverResult.$1 ?? [];
        mcpError = serverResult.$2;
        skills = skillResult.$1 ?? [];
        skillsError = skillResult.$2;
        sessionStatus = statusResult.$1 ?? 'unknown';
        sessionStatusError = statusResult.$2;
        loading = false;
      });
    }
    refreshing = false;
  }

  Future<void> _toggleMcp(Json server) async {
    final serverName = server['name'];
    if (serverName is! String || mcpMutations.contains(serverName)) {
      return;
    }
    final connected = _mcpStatus(server) == 'connected';
    setState(() => mcpMutations.add(serverName));
    try {
      await api.setMcpConnection(
        widget.session.directory,
        serverName,
        connect: !connected,
      );
      if (mounted) {
        notice(
          context,
          connected ? 'Servidor MCP desconectado.' : 'Conexão MCP solicitada.',
        );
      }
      await _loadCapabilities();
    } catch (exception) {
      if (mounted) {
        notice(context, exception);
      }
    } finally {
      if (mounted) {
        setState(() => mcpMutations.remove(serverName));
      }
    }
  }

  Future<void> _activateSkill(Json skill) async {
    final skillName = skill['name'];
    if (skillName is! String || !canActivateSkill || activatingSkill != null) {
      return;
    }
    final description = skill['description'] as String?;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Ativar $skillName?'),
        content: Text(
          '${description == null ? '' : '$description\n\n'}A skill será anexada à sessão e o OpenCode retomará a execução.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Ativar e continuar'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    setState(() => activatingSkill = skillName);
    try {
      await api.activateSkill(widget.session, skillName);
      if (mounted) {
        notice(context, 'Skill ativada. A sessão foi retomada.');
        Navigator.pop(context, true);
      }
    } catch (exception) {
      if (mounted) {
        notice(context, exception);
      }
    } finally {
      if (mounted) {
        setState(() => activatingSkill = null);
      }
    }
  }

  String _mcpStatus(Json server) {
    final status = server['status'];
    if (status is String) {
      return status;
    }
    return object(status)['status'] as String? ?? 'unknown';
  }

  String _mcpStatusLabel(String status) {
    return switch (status) {
      'connected' => 'Conectado',
      'pending' => 'Conectando',
      'disabled' => 'Desativado',
      'failed' => 'Falha',
      'needs_auth' || 'needsAuth' || 'needs-auth' => 'Requer autenticação',
      _ => 'Status desconhecido',
    };
  }

  bool _needsAuthentication(String status) =>
      status == 'needs_auth' || status == 'needsAuth' || status == 'needs-auth';

  Color _mcpStatusColor(String status) {
    return switch (status) {
      'connected' => AppColors.accent,
      'pending' => AppColors.warning,
      'failed' ||
      'needs_auth' ||
      'needsAuth' ||
      'needs-auth' =>
        AppColors.danger,
      _ => AppColors.muted,
    };
  }

  String? _mcpError(Json server) {
    final status = server['status'];
    final statusError = object(status)['error'];
    if (statusError is String) {
      return statusError;
    }
    final serverError = server['error'];
    return serverError is String ? serverError : null;
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Ferramentas'),
              Text(
                '${widget.machine.name} · ${folderName(widget.session.directory)}',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: AppColors.muted,
                    ),
              ),
            ],
          ),
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.hub_outlined), text: 'MCPs'),
              Tab(icon: Icon(Icons.auto_awesome_outlined), text: 'Skills'),
            ],
          ),
          actions: [
            IconButton(
              tooltip: 'Atualizar ferramentas',
              onPressed: loading ? null : _loadCapabilities,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: TabBarView(
          children: [
            _mcpList(),
            _skillList(),
          ],
        ),
      ),
    );
  }

  Widget _mcpList() {
    if (loading && servers.isEmpty && mcpError == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return RefreshIndicator(
      onRefresh: _loadCapabilities,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 28),
        children: [
          Text(
            'Servidores MCP',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 5),
          Text(
            'Confira a conexão e altere quais servidores disponibilizam ferramentas nesta máquina. A ação vale até reiniciar o OpenCode.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppColors.muted,
                  height: 1.4,
                ),
          ),
          if (loading) ...[
            const SizedBox(height: 14),
            const LinearProgressIndicator(),
          ],
          if (mcpError != null) ...[
            const SizedBox(height: 14),
            InfoBox(mcpError!, icon: Icons.error_outline),
          ],
          if (mcpError == null && servers.isEmpty && !loading) ...[
            const SizedBox(height: 16),
            const InfoBox(
              'Nenhum servidor MCP foi configurado para este diretório. Adicione servidores na configuração do OpenCode no computador.',
            ),
          ],
          for (final server in servers) ...[
            const SizedBox(height: 10),
            _mcpCard(server),
          ],
        ],
      ),
    );
  }

  Widget _mcpCard(Json server) {
    final name = server['name'] as String? ?? 'Servidor MCP';
    final status = _mcpStatus(server);
    final connected = status == 'connected';
    final isPending = status == 'pending';
    final canToggle = !isPending && !_needsAuthentication(status);
    final mutationInProgress = mcpMutations.contains(name);
    final statusColor = _mcpStatusColor(status);
    final statusError = _mcpError(server) ??
        (_needsAuthentication(status)
            ? 'Conclua a autenticação deste MCP no computador.'
            : null);
    return Card(
      color: AppColors.surfaceRaised,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(15, 13, 8, 13),
        child: Row(
          children: [
            Icon(Icons.hub_outlined, color: statusColor),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _mcpStatusLabel(status),
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: statusColor,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                  if (statusError != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      statusError,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: AppColors.muted,
                          ),
                    ),
                  ],
                ],
              ),
            ),
            if (mutationInProgress)
              const Padding(
                padding: EdgeInsets.all(12),
                child: SizedBox(
                  width: 19,
                  height: 19,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else
              IconButton(
                tooltip: _needsAuthentication(status)
                    ? 'Autenticação necessária no computador'
                    : connected
                        ? 'Desconectar $name'
                        : 'Conectar $name',
                onPressed: canToggle ? () => _toggleMcp(server) : null,
                icon: Icon(
                  connected ? Icons.link_off : Icons.link,
                  color: connected ? AppColors.warning : AppColors.accent,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _skillList() {
    if (loading && skills.isEmpty && skillsError == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return RefreshIndicator(
      onRefresh: _loadCapabilities,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 28),
        children: [
          Text(
            'Skills disponíveis',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 5),
          Text(
            'Ativar uma skill anexa suas instruções à sessão e retoma a execução no OpenCode.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppColors.muted,
                  height: 1.4,
                ),
          ),
          if (sessionBusy) ...[
            const SizedBox(height: 14),
            const InfoBox(
              'A sessão está em execução. Aguarde terminar antes de ativar uma skill.',
              icon: Icons.sync,
            ),
          ],
          if (sessionStatusError != null) ...[
            const SizedBox(height: 14),
            InfoBox(
              'Não foi possível confirmar o estado da sessão: $sessionStatusError',
              icon: Icons.error_outline,
            ),
          ],
          if (loading) ...[
            const SizedBox(height: 14),
            const LinearProgressIndicator(),
          ],
          if (skillsError != null) ...[
            const SizedBox(height: 14),
            InfoBox(skillsError!, icon: Icons.error_outline),
          ],
          if (skillsError == null && skills.isEmpty && !loading) ...[
            const SizedBox(height: 16),
            const InfoBox(
              'Nenhuma skill encontrada para este diretório. Confira as pastas de skills do OpenCode no computador.',
            ),
          ],
          for (final skill in skills) ...[
            const SizedBox(height: 10),
            _skillCard(skill),
          ],
        ],
      ),
    );
  }

  Widget _skillCard(Json skill) {
    final name = skill['name'] as String? ?? 'Skill';
    final description = skill['description'] as String?;
    final isActivating = activatingSkill == name;
    return Card(
      color: AppColors.surfaceRaised,
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(15, 7, 8, 7),
        leading: const Icon(Icons.auto_awesome, color: AppColors.accent),
        title: Text(name),
        subtitle: description == null ? null : Text(description),
        trailing: isActivating
            ? const SizedBox(
                width: 21,
                height: 21,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : IconButton(
                tooltip: 'Ativar $name nesta sessão',
                onPressed:
                    canActivateSkill ? () => _activateSkill(skill) : null,
                icon: const Icon(Icons.play_arrow),
              ),
        onTap: canActivateSkill ? () => _activateSkill(skill) : null,
      ),
    );
  }
}
