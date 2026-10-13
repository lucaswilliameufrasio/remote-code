import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import '../core/api.dart';
import '../core/models.dart';
import '../core/store.dart';
import 'common.dart';
import 'design.dart';
import 'tools.dart';

class ChatScreen extends StatefulWidget {
  final AppStore store;
  final Machine machine;
  final Session session;
  final OpenCodeApi? apiOverride;
  const ChatScreen(
      {super.key,
      required this.store,
      required this.machine,
      required this.session,
      this.apiOverride});
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  late final OpenCodeApi api;
  late final TextEditingController input;
  late Session session;
  final scroll = ScrollController();
  List<Json> messages = [],
      inbox = [],
      permissions = [],
      questions = [],
      agents = [];
  Json providers = {};
  String? agent,
      modelKey,
      error,
      inboxError,
      agentSettingsError,
      modelSettingsError;
  String status = 'conectando';
  bool fetching = false,
      sending = false,
      paused = false,
      agentsLoading = true,
      modelsLoading = true;
  bool showLatestButton = false;
  final Set<String> queueMutations = {};
  int failures = 0, generation = 0;
  int settingsGeneration = 0;
  final ValueNotifier<int> settingsSheetRevision = ValueNotifier(0);
  Timer? poll, draftTimer;
  bool get busy => status == 'running' || status == 'busy' || status == 'retry';
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    api = widget.apiOverride ?? OpenCodeApi(widget.machine);
    session = widget.session;
    scroll.addListener(_updateLatestButton);
    input = TextEditingController(
        text:
            widget.store.bookmark(widget.machine.id, session.id)?.draft ?? '');
    input.addListener(_draftChanged);
    _refresh();
    _settings();
  }

  Future<void> _settings() async {
    final currentGeneration = ++settingsGeneration;
    if (!mounted) {
      return;
    }
    setState(() {
      agentsLoading = true;
      modelsLoading = true;
    });
    settingsSheetRevision.value++;

    await Future.wait<void>([
      _updateAgents(currentGeneration),
      _updateProviders(currentGeneration),
    ]);
  }

  Future<void> _updateAgents(int currentGeneration) async {
    final result = await _loadAgents();
    if (!mounted || currentGeneration != settingsGeneration) {
      return;
    }
    setState(() {
      agents = result.$1 ?? [];
      agentSettingsError = result.$2;
      agentsLoading = false;
    });
    settingsSheetRevision.value++;
  }

  Future<void> _updateProviders(int currentGeneration) async {
    final result = await _loadProviders();
    if (!mounted || currentGeneration != settingsGeneration) {
      return;
    }
    setState(() {
      providers = result.$1 ?? {};
      modelSettingsError = result.$2;
      modelsLoading = false;
    });
    settingsSheetRevision.value++;
  }

  Future<(List<Json>?, String?)> _loadAgents() async {
    try {
      final availableAgents = await api.agents(session.directory);
      return (
        availableAgents
            .where((availableAgent) =>
                availableAgent['mode'] != 'subagent' &&
                availableAgent['hidden'] != true)
            .toList(),
        null,
      );
    } catch (exception) {
      return (null, exception.toString());
    }
  }

  Future<(Json?, String?)> _loadProviders() async {
    try {
      return (object(await api.providers(session.directory)), null);
    } catch (exception) {
      return (null, exception.toString());
    }
  }

  void _draftChanged() {
    draftTimer?.cancel();
    draftTimer = Timer(const Duration(milliseconds: 500), _saveDraft);
  }

  Future<void> _saveDraft() async {
    try {
      await widget.store.remember(widget.machine, session, draft: input.text);
    } catch (e) {
      if (mounted) notice(context, 'Falha ao salvar rascunho: $e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    paused = state != AppLifecycleState.resumed;
    generation++;
    poll?.cancel();
    if (paused) {
      _saveDraft();
    } else {
      _refresh();
    }
  }

  @override
  void dispose() {
    paused = true;
    generation++;
    WidgetsBinding.instance.removeObserver(this);
    poll?.cancel();
    draftTimer?.cancel();
    scroll.removeListener(_updateLatestButton);
    settingsSheetRevision.dispose();
    _saveDraft();
    api.close();
    input.dispose();
    scroll.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (fetching || paused || !mounted) return;
    fetching = true;
    final run = generation;
    poll?.cancel();
    try {
      final result = await Future.wait<dynamic>([
        api.getSession(session.id),
        api.messages(session),
        api.statuses(),
        api.pending('permission', session),
        api.pending('question', session),
        _loadInbox(),
      ]);
      if (!mounted || paused || run != generation) return;
      final wasAtLatest = !scroll.hasClients || scroll.position.pixels < 100;
      final inboxResult = result[5] as (List<Json>?, String?);
      setState(() {
        session = result[0] as Session;
        messages = objects(result[1]);
        status =
            object(object(result[2])[session.id])['type'] as String? ?? 'idle';
        permissions = objects(result[3]);
        questions = objects(result[4]);
        inbox = inboxResult.$1 ?? inbox;
        inboxError = inboxResult.$2;
        error = null;
        failures = 0;
      });
      if (wasAtLatest) {
        _scrollToLatest(animate: false);
      }
    } catch (e) {
      if (mounted && !paused && run == generation) {
        setState(() {
          error = e.toString();
          failures++;
        });
      }
    } finally {
      fetching = false;
      if (mounted && !paused) {
        final delay = failures == 0
            ? 3
            : (3 * (1 << failures.clamp(0, 3).toInt())).clamp(3, 30).toInt();
        poll = Timer(Duration(seconds: delay), _refresh);
      }
    }
  }

  Future<(List<Json>?, String?)> _loadInbox() async {
    try {
      return (await api.inbox(session), null);
    } catch (exception) {
      return (null, exception.toString());
    }
  }

  void _updateLatestButton() {
    if (!scroll.hasClients) {
      return;
    }
    final shouldShow = scroll.position.pixels > 160;
    if (shouldShow != showLatestButton && mounted) {
      setState(() => showLatestButton = shouldShow);
    }
  }

  void _scrollToLatest({bool animate = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !scroll.hasClients) {
        return;
      }
      if (animate) {
        scroll.animateTo(
          0,
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
        );
      } else {
        scroll.jumpTo(0);
      }
    });
  }

  List<(String, String, Json)> get models {
    final providerNames = <String, String>{};
    for (final provider in objects(providers['providers'])) {
      final id = provider['id'];
      if (id is String) {
        providerNames[id] = provider['name'] as String? ?? id;
      }
    }
    final result = <(String, String, Json)>[];
    for (final model in objects(providers['models'])) {
      final providerID = model['providerID'];
      final modelID = model['modelID'];
      if (model['enabled'] != true ||
          providerID is! String ||
          modelID is! String) {
        continue;
      }
      result.add((
        '$providerID/$modelID',
        '${providerNames[providerID] ?? providerID} · ${model['name'] ?? modelID}',
        {'id': modelID, 'providerID': providerID}
      ));
    }
    return result;
  }

  Future<void> _send() async {
    final text = input.text.trim();
    if (text.isEmpty || sending || error != null) return;
    final shouldQueue = busy;
    if (shouldQueue && inboxError != null) {
      notice(
          context, 'A fila não está disponível; a mensagem não foi enviada.');
      return;
    }
    setState(() => sending = true);
    try {
      Json? model;
      for (final availableModel in models) {
        if (availableModel.$1 == modelKey) {
          model = availableModel.$3;
        }
      }
      await api.prompt(
        session,
        text,
        agent: shouldQueue ? null : agent,
        model: shouldQueue ? null : model,
        delivery: shouldQueue ? 'queue' : null,
      );
      if (!mounted) return;
      input.clear();
      await _saveDraft();
      if (!shouldQueue) {
        setState(() => status = 'busy');
      }
      await _refresh();
    } catch (e) {
      if (mounted) {
        notice(context,
            '$e\nO envio pode ter sido recebido. Confira o histórico antes de reenviar.');
      }
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  Future<void> _openTools() async {
    final activated = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => SessionToolsScreen(
          machine: widget.machine,
          session: session,
        ),
      ),
    );
    if (activated == true && mounted) {
      await _refresh();
    }
  }

  List<Json> get queuedMessages =>
      inbox.where((item) => item['type'] == 'user').toList();

  bool _canEditQueuedMessage(Json item) {
    final payload = object(item['payload']);
    if (payload['text'] is! String) {
      return false;
    }
    for (final entry in payload.entries) {
      if (entry.key == 'text' || _isEmptyPayloadValue(entry.value)) {
        continue;
      }
      return false;
    }
    return true;
  }

  bool _isEmptyPayloadValue(dynamic value) {
    if (value == null) {
      return true;
    }
    if (value is String) {
      return value.isEmpty;
    }
    if (value is List) {
      return value.isEmpty;
    }
    if (value is Map) {
      return value.isEmpty;
    }
    return false;
  }

  Future<void> _editQueuedMessage(Json item) async {
    final payload = object(item['payload']);
    final originalText = payload['text'];
    final itemID = item['id'];
    if (originalText is! String || itemID is! String) {
      return;
    }
    final editedText = await showDialog<String>(
      context: context,
      builder: (_) => QueueMessageDialog(initialText: originalText),
    );
    if (editedText == null || editedText.trim().isEmpty || !mounted) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Substituir mensagem da fila?'),
        content: const Text(
          'A API do OpenCode não edita o texto em posição. O item atual será removido e a versão editada entrará no fim da fila. Se o original começar a execução antes do cancelamento, ele não poderá mais ser removido.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Substituir'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    setState(() => queueMutations.add(itemID));
    try {
      await api.prompt(session, editedText.trim(), delivery: 'queue');
      try {
        await api.cancelInbox(session, itemID);
        if (mounted) {
          notice(context, 'Mensagem atualizada e adicionada ao fim da fila.');
        }
      } catch (cancelException) {
        if (mounted) {
          notice(
            context,
            'A versão editada entrou no fim da fila, mas não foi possível confirmar a remoção do item original. Confira a fila. $cancelException',
          );
        }
      }
      await _refresh();
    } catch (exception) {
      if (mounted) {
        if (input.text.trim().isEmpty) {
          input.text = editedText.trim();
          await _saveDraft();
          if (!mounted) {
            return;
          }
        }
        notice(
          context,
          '$exception\nO item original foi mantido. Confira a fila antes de tentar novamente.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => queueMutations.remove(itemID));
      }
    }
  }

  Future<void> _removeQueuedMessage(Json item) async {
    final itemID = item['id'];
    if (itemID is! String) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remover da fila?'),
        content: const Text(
          'A mensagem só pode ser removida enquanto ainda estiver pendente no servidor.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Manter'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Remover'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    setState(() => queueMutations.add(itemID));
    try {
      await api.cancelInbox(session, itemID);
      await _refresh();
    } catch (exception) {
      if (mounted) {
        notice(context, exception);
      }
    } finally {
      if (mounted) {
        setState(() => queueMutations.remove(itemID));
      }
    }
  }

  Future<void> _respondToPermission(Json request, String reply) async {
    final requestID = request['id'];
    if (requestID is! String) {
      return;
    }
    if (reply == 'always') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Permitir sempre?'),
          content: const Text(
            'O OpenCode salvará esta decisão como uma permissão persistente.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Permitir sempre'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) {
        return;
      }
    }
    await _action(() => api.permission(session, requestID, reply));
  }

  Future<void> _action(Future<void> Function() task) async {
    try {
      await task();
      await _refresh();
    } catch (e) {
      if (mounted) notice(context, e);
    }
  }

  Future<void> _details(String kind) async {
    try {
      final value = await api.details(session, kind);
      if (!mounted) return;
      await showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          builder: (c) => SafeArea(
              child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: SizedBox(
                      height: MediaQuery.sizeOf(c).height * .7,
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                                kind == 'diff'
                                    ? 'Alterações da sessão'
                                    : 'Contexto ativo',
                                style: Theme.of(c).textTheme.titleLarge),
                            const SizedBox(height: 12),
                            Expanded(
                                child: SingleChildScrollView(
                                    child: SelectableText(pretty(value)))),
                          ])))));
    } catch (e) {
      if (mounted) notice(context, e);
    }
  }

  Future<void> _answerQuestion(Json request) async {
    final answers = await showDialog<Json>(
        context: context, builder: (_) => FormDialog(form: request));
    if (answers != null) {
      await _action(
          () => api.replyForm(session, request['id'] as String, answers));
    }
  }

  String get _statusLabel {
    if (error != null) {
      return 'Reconectando';
    }
    return switch (status) {
      'running' || 'busy' => 'Executando',
      'retry' => 'Tentando novamente',
      'idle' => 'Pronto para continuar',
      _ => 'Conectando',
    };
  }

  String get _agentLabel {
    if (agent == null) {
      return 'Agente padrão';
    }
    for (final availableAgent in agents) {
      if (availableAgent['id'] == agent) {
        return availableAgent['name'] as String? ?? agent!;
      }
    }
    return agent!;
  }

  String get _modelLabel {
    if (modelKey == null) {
      return 'Modelo anterior';
    }
    for (final availableModel in models) {
      if (availableModel.$1 == modelKey) {
        return availableModel.$2;
      }
    }
    return 'Modelo anterior';
  }

  Future<void> _chooseAgent() async {
    final selection = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => ValueListenableBuilder<int>(
        valueListenable: settingsSheetRevision,
        builder: (context, revision, _) {
          final availableOptions = <SearchableOption>[];
          for (final availableAgent in agents) {
            final id = availableAgent['id'];
            if (id is! String) {
              continue;
            }
            availableOptions.add(
              SearchableOption(
                value: id,
                label: availableAgent['name'] as String? ?? id,
                subtitle: availableAgent['description'] as String?,
                searchTerms: id,
              ),
            );
          }
          return SearchableChoiceSheet(
            title: 'Escolher agente',
            selectedValue: agent,
            defaultLabel: 'Agente padrão',
            options: availableOptions,
            isLoading: agentsLoading,
            emptyMessage: agentSettingsError == null
                ? 'Nenhum agente adicional disponível neste diretório.'
                : 'Não foi possível carregar agentes. Tente novamente ou use o padrão do servidor.',
            searchHint: 'Buscar agente',
            optionIcon: Icons.smart_toy_outlined,
          );
        },
      ),
    );
    if (selection != null && mounted) {
      setState(() => agent = selection == '__default__' ? null : selection);
    }
  }

  Future<void> _chooseModel() async {
    final selection = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => ValueListenableBuilder<int>(
        valueListenable: settingsSheetRevision,
        builder: (context, revision, _) {
          final availableOptions = <SearchableOption>[];
          for (final availableModel in models) {
            availableOptions.add(
              SearchableOption(
                value: availableModel.$1,
                label: availableModel.$2,
                searchTerms: availableModel.$1,
              ),
            );
          }
          return SearchableChoiceSheet(
            title: 'Escolher modelo',
            selectedValue: modelKey,
            defaultLabel: 'Padrão ou modelo anterior',
            options: availableOptions,
            isLoading: modelsLoading,
            emptyMessage: modelSettingsError == null
                ? 'Nenhum modelo habilitado disponível.'
                : 'Não foi possível carregar modelos. Tente novamente ou use o padrão do servidor.',
            searchHint: 'Buscar por modelo ou provedor',
            optionIcon: Icons.auto_awesome_outlined,
          );
        },
      ),
    );
    if (selection != null && mounted) {
      setState(() => modelKey = selection == '__default__' ? null : selection);
    }
  }

  Future<void> _refreshSettings() async {
    await _settings();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              session.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              '${widget.machine.name} · ${folderName(session.directory)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: AppColors.muted,
                  ),
            ),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            tooltip: 'Ações da sessão',
            onSelected: (value) async {
              if (value == 'id') {
                await Clipboard.setData(ClipboardData(text: session.id));
                if (!context.mounted) {
                  return;
                }
                notice(context, 'ID copiado.');
              }
              if (value == 'diff' || value == 'context') {
                _details(value);
              }
              if (value == 'refresh') {
                _refresh();
              }
              if (value == 'tools') {
                _openTools();
              }
              if (value == 'settings') {
                _refreshSettings();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'tools',
                child: Text('Ferramentas e skills'),
              ),
              PopupMenuItem(
                value: 'settings',
                child: Text('Atualizar agentes e modelos'),
              ),
              PopupMenuItem(value: 'id', child: Text('Copiar ID da sessão')),
              PopupMenuItem(value: 'diff', child: Text('Ver alterações')),
              PopupMenuItem(value: 'context', child: Text('Ver contexto')),
              PopupMenuItem(value: 'refresh', child: Text('Reconectar agora')),
            ],
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            _sessionStatus(),
            if (error != null) _connectionWarning(),
            _pendingRequests(),
            Expanded(
              child: messages.isEmpty ? _emptyConversation() : _conversation(),
            ),
            if (busy) _executionBar(),
            _composer(),
          ],
        ),
      ),
    );
  }

  Widget _sessionStatus() {
    final active = error == null && (busy || status == 'idle');
    final indicatorColor = error != null
        ? AppColors.danger
        : active
            ? AppColors.accent
            : AppColors.muted;
    final icon = error != null
        ? Icons.cloud_off_outlined
        : busy
            ? Icons.sync
            : Icons.circle;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
      child: Row(
        children: [
          Icon(
            icon,
            size: 15,
            color: indicatorColor,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              error == null
                  ? _statusLabel
                  : 'Conexão instável · rascunho salvo',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: error != null ? AppColors.danger : AppColors.muted,
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _connectionWarning() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Card(
        color: AppColors.surfaceRaised,
        child: Padding(
          padding: const EdgeInsets.all(13),
          child: Row(
            children: [
              const Icon(Icons.wifi_off, color: AppColors.danger, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '$error\nTentando reconectar. Seu rascunho continua salvo.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        height: 1.35,
                      ),
                ),
              ),
              IconButton(
                tooltip: 'Tentar novamente',
                onPressed: _refresh,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pendingRequests() {
    final pendingMessages = queuedMessages;
    if (permissions.isEmpty &&
        questions.isEmpty &&
        pendingMessages.isEmpty &&
        inboxError == null) {
      return const SizedBox.shrink();
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 230),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        children: [
          if (inboxError != null)
            InfoBox(
              'Não foi possível consultar a fila: $inboxError',
              icon: Icons.error_outline,
            ),
          for (final permissionRequest in permissions)
            _permissionCard(permissionRequest),
          for (final question in questions) _questionCard(question),
          if (pendingMessages.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
              child: Row(
                children: [
                  const Icon(Icons.playlist_play, size: 17),
                  const SizedBox(width: 7),
                  Text(
                    'FILA DE MENSAGENS',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: AppColors.muted,
                          letterSpacing: 1,
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const Spacer(),
                  Text(
                    '${pendingMessages.length}',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: AppColors.muted,
                        ),
                  ),
                ],
              ),
            ),
            for (final queuedMessage in pendingMessages)
              _queuedMessageCard(queuedMessage),
          ],
        ],
      ),
    );
  }

  Widget _queuedMessageCard(Json item) {
    final itemID = item['id'] as String? ?? '';
    final text = object(item['payload'])['text'] as String? ?? 'Mensagem';
    final delivery = item['delivery'] as String? ?? 'queue';
    final mutating = queueMutations.contains(itemID);
    final canEdit = _canEditQueuedMessage(item);
    return Card(
      color: AppColors.surfaceRaised,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 7, 6, 7),
        child: Row(
          children: [
            Icon(
              delivery == 'steer' ? Icons.low_priority : Icons.schedule,
              size: 19,
              color: AppColors.accent,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    delivery == 'steer' ? 'Próxima mensagem' : 'Na fila',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: AppColors.accent,
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    text,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (!canEdit)
                    Text(
                      'Edição indisponível para anexos ou referências.',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: AppColors.warning,
                          ),
                    ),
                ],
              ),
            ),
            if (mutating)
              const Padding(
                padding: EdgeInsets.all(12),
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else ...[
              IconButton(
                tooltip: canEdit
                    ? 'Editar e reenfileirar'
                    : 'Não é possível editar anexos ou referências',
                onPressed: canEdit ? () => _editQueuedMessage(item) : null,
                icon: const Icon(Icons.edit_outlined),
              ),
              IconButton(
                tooltip: 'Remover da fila',
                onPressed: () => _removeQueuedMessage(item),
                icon: const Icon(Icons.close),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _permissionCard(Json request) {
    final resources = (request['patterns'] as List? ?? const []).join('\n');
    return Card(
      color: AppColors.surfaceRaised,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(15, 14, 15, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.shield_outlined,
                  color: AppColors.warning,
                  size: 19,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    'Sua aprovação é necessária',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 7),
            Text(
              'Permissão: ${request['permission']}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.muted,
                  ),
            ),
            if (resources.isNotEmpty) ...[
              const SizedBox(height: 5),
              SelectableText(resources),
            ],
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 8),
              title: const Text('Detalhes da ferramenta'),
              children: [SelectableText(pretty(request['metadata']))],
            ),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton(
                  onPressed: () => _respondToPermission(request, 'reject'),
                  child: const Text('Negar'),
                ),
                FilledButton(
                  onPressed: () => _respondToPermission(request, 'once'),
                  child: const Text('Uma vez'),
                ),
                TextButton(
                  onPressed: () => _respondToPermission(request, 'always'),
                  child: const Text('Sempre permitir'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _questionCard(Json question) {
    return Card(
      color: AppColors.surfaceRaised,
      child: ListTile(
        leading: const Icon(
          Icons.help_outline,
          color: AppColors.warning,
        ),
        title: const Text('O agente precisa de uma resposta'),
        subtitle: Text(question['title'] as String? ?? 'Formulário pendente'),
        trailing: const Icon(Icons.arrow_forward, size: 18),
        onTap: () => _answerQuestion(question),
      ),
    );
  }

  Widget _emptyConversation() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 58,
              height: 58,
              decoration: BoxDecoration(
                color: AppColors.accentSoft,
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Icon(Icons.terminal, color: AppColors.accent),
            ),
            const SizedBox(height: 16),
            Text(
              error != null ? 'Aguardando conexão' : 'Sessão pronta',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 7),
            Text(
              error != null
                  ? 'Assim que a máquina voltar, o histórico será carregado.'
                  : 'Escreva uma instrução abaixo para continuar o trabalho.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppColors.muted,
                    height: 1.4,
                  ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _conversation() {
    return ConversationTimeline(
      messages: messages,
      controller: scroll,
      showJumpToLatest: showLatestButton,
      onJumpToLatest: _scrollToLatest,
    );
  }

  Widget _executionBar() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      padding: const EdgeInsets.fromLTRB(12, 9, 8, 9),
      decoration: BoxDecoration(
        color: AppColors.accentSoft,
        borderRadius: smallRadius,
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 15,
            height: 15,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppColors.accent,
            ),
          ),
          const SizedBox(width: 10),
          const Expanded(child: Text('Trabalhando na máquina remota')),
          TextButton(
            onPressed: () => _action(() => api.abort(session)),
            style: TextButton.styleFrom(foregroundColor: AppColors.danger),
            child: const Text('Interromper'),
          ),
        ],
      ),
    );
  }

  Widget _composer() {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.outline)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 9, 14, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _composerOption(
                      icon: Icons.smart_toy_outlined,
                      label: _agentLabel,
                      onPressed: busy ? null : _chooseAgent,
                    ),
                    const SizedBox(width: 8),
                    _composerOption(
                      icon: Icons.auto_awesome_outlined,
                      label: _modelLabel,
                      onPressed: busy ? null : _chooseModel,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: input,
                      minLines: 1,
                      maxLines: 5,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: const InputDecoration(
                        hintText: 'Continuar o trabalho…',
                        contentPadding: EdgeInsets.fromLTRB(15, 12, 15, 12),
                      ),
                    ),
                  ),
                  const SizedBox(width: 9),
                  IconButton.filled(
                    tooltip: busy ? 'Enfileirar mensagem' : 'Enviar mensagem',
                    onPressed:
                        sending || error != null || (busy && inboxError != null)
                            ? null
                            : _send,
                    icon: sending
                        ? const SizedBox(
                            width: 19,
                            height: 19,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(busy ? Icons.playlist_add : Icons.arrow_upward),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _composerOption({
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
  }) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 16),
      label: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 138),
        child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        textStyle: Theme.of(context).textTheme.labelSmall,
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}

class MessageCard extends StatelessWidget {
  final Json message;
  const MessageCard({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    final info = object(message['info']);
    final isUser = info['role'] == 'user';
    final maxWidth = MediaQuery.sizeOf(context).width * (isUser ? .86 : .96);
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.fromLTRB(15, 13, 15, 14),
          decoration: BoxDecoration(
            color: isUser ? AppColors.accentSoft : AppColors.surface,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(18),
              topRight: Radius.circular(isUser ? 6 : 18),
              bottomLeft: const Radius.circular(18),
              bottomRight: Radius.circular(isUser ? 18 : 6),
            ),
            border: isUser ? null : Border.all(color: AppColors.outline),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!isUser) ...[
                    Container(
                      width: 21,
                      height: 21,
                      decoration: BoxDecoration(
                        color: AppColors.accentSoft,
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: const Icon(
                        Icons.terminal,
                        color: AppColors.accent,
                        size: 14,
                      ),
                    ),
                    const SizedBox(width: 7),
                  ],
                  Text(
                    isUser ? 'VOCÊ' : 'OPENCODE',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: isUser ? AppColors.accent : AppColors.muted,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.1,
                        ),
                  ),
                ],
              ),
              if (info['error'] != null) ...[
                const SizedBox(height: 9),
                InfoBox(
                  pretty(info['error']),
                  icon: Icons.error_outline,
                ),
              ],
              for (final part in objects(message['parts']))
                _renderPart(context, part),
            ],
          ),
        ),
      ),
    );
  }

  Widget _renderPart(BuildContext context, Json part) {
    final type = part['type'];
    if (type == 'text') {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: MarkdownBody(
          data: part['text'] as String? ?? '',
          selectable: true,
        ),
      );
    }
    if (type == 'reasoning') {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Material(
          color: AppColors.surfaceRaised,
          borderRadius: smallRadius,
          child: ExpansionTile(
            dense: true,
            tilePadding: const EdgeInsets.symmetric(horizontal: 11),
            childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            leading: const Icon(
              Icons.psychology_outlined,
              size: 19,
              color: AppColors.muted,
            ),
            title: const Text('Análise do modelo'),
            subtitle: const Text('Conteúdo interno ocultado'),
            children: const [
              Align(
                alignment: Alignment.centerLeft,
                child:
                    Text('Atualizações e ações do agente ficam visíveis aqui.'),
              ),
            ],
          ),
        ),
      );
    }
    if (type == 'tool') {
      final state = object(part['state']);
      final toolStatus = state['status'] as String? ?? 'running';
      final finished = toolStatus == 'completed' || toolStatus == 'done';
      return Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Material(
          color: AppColors.surfaceRaised,
          borderRadius: smallRadius,
          clipBehavior: Clip.antiAlias,
          child: ExpansionTile(
            dense: true,
            tilePadding: const EdgeInsets.symmetric(horizontal: 11),
            childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            leading: Icon(
              Icons.terminal,
              size: 18,
              color: finished ? AppColors.accent : AppColors.warning,
            ),
            title: Text(
              part['tool'] as String? ?? 'Ferramenta',
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            subtitle: Text(
              state['title'] as String? ?? toolStatus,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: SelectableText(pretty(state)),
              ),
            ],
          ),
        ),
      );
    }
    if (type == 'file') {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(
          children: [
            const Icon(Icons.attach_file, size: 17, color: AppColors.accent),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                part['filename'] as String? ??
                    part['mime'] as String? ??
                    'Arquivo',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
    }
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: Text(type as String? ?? 'Conteúdo'),
      children: [SelectableText(pretty(part))],
    );
  }
}

class SearchableOption {
  final String value;
  final String label;
  final String? subtitle;
  final String searchTerms;

  const SearchableOption({
    required this.value,
    required this.label,
    this.subtitle,
    this.searchTerms = '',
  });
}

class SearchableChoiceSheet extends StatefulWidget {
  final String title;
  final String? selectedValue;
  final String defaultLabel;
  final List<SearchableOption> options;
  final bool isLoading;
  final String emptyMessage;
  final String searchHint;
  final IconData optionIcon;

  const SearchableChoiceSheet({
    super.key,
    required this.title,
    required this.selectedValue,
    required this.defaultLabel,
    required this.options,
    required this.isLoading,
    required this.emptyMessage,
    required this.searchHint,
    required this.optionIcon,
  });

  @override
  State<SearchableChoiceSheet> createState() => _SearchableChoiceSheetState();
}

class _SearchableChoiceSheetState extends State<SearchableChoiceSheet> {
  final TextEditingController search = TextEditingController();

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  List<SearchableOption> get filteredOptions {
    final query = search.text.trim().toLowerCase();
    if (query.isEmpty) {
      return widget.options;
    }
    return widget.options.where((option) {
      final searchable =
          '${option.label} ${option.subtitle ?? ''} ${option.searchTerms}'
              .toLowerCase();
      return searchable.contains(query);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final visibleOptions = filteredOptions;
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .78,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
                child: Text(
                  widget.title,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              TextField(
                controller: search,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: widget.searchHint,
                  suffixIcon: search.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Limpar busca',
                          onPressed: () {
                            search.clear();
                            setState(() {});
                          },
                          icon: const Icon(Icons.close),
                        ),
                ),
              ),
              const SizedBox(height: 8),
              if (widget.isLoading) const LinearProgressIndicator(),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.only(top: 8),
                  children: [
                    ListTile(
                      leading: Icon(
                        widget.selectedValue == null
                            ? Icons.check_circle
                            : Icons.circle_outlined,
                        color: widget.selectedValue == null
                            ? AppColors.accent
                            : AppColors.muted,
                      ),
                      title: Text(widget.defaultLabel),
                      onTap: () => Navigator.pop(context, '__default__'),
                    ),
                    if (visibleOptions.isEmpty && !widget.isLoading)
                      Padding(
                        padding: const EdgeInsets.all(18),
                        child: Text(
                          search.text.isEmpty
                              ? widget.emptyMessage
                              : 'Nenhum resultado para “${search.text.trim()}”.',
                          textAlign: TextAlign.center,
                          style:
                              Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    color: AppColors.muted,
                                  ),
                        ),
                      ),
                    for (final option in visibleOptions)
                      ListTile(
                        leading: Icon(
                          option.value == widget.selectedValue
                              ? Icons.check_circle
                              : widget.optionIcon,
                          color: option.value == widget.selectedValue
                              ? AppColors.accent
                              : AppColors.muted,
                        ),
                        title: Text(option.label),
                        subtitle: option.subtitle == null
                            ? null
                            : Text(
                                option.subtitle!,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                        onTap: () => Navigator.pop(context, option.value),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ConversationTimeline extends StatelessWidget {
  final List<Json> messages;
  final ScrollController controller;
  final bool showJumpToLatest;
  final VoidCallback onJumpToLatest;

  const ConversationTimeline({
    super.key,
    required this.messages,
    required this.controller,
    required this.showJumpToLatest,
    required this.onJumpToLatest,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        ListView.builder(
          reverse: true,
          controller: controller,
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
          itemCount: messages.length,
          itemBuilder: (_, index) => MessageCard(
            message: messages[messages.length - 1 - index],
          ),
        ),
        if (showJumpToLatest)
          Positioned(
            right: 16,
            bottom: 14,
            child: FilledButton.tonalIcon(
              onPressed: onJumpToLatest,
              icon: const Icon(Icons.south),
              label: const Text('Mais recentes'),
            ),
          ),
      ],
    );
  }
}

class QueueMessageDialog extends StatefulWidget {
  final String initialText;

  const QueueMessageDialog({super.key, required this.initialText});

  @override
  State<QueueMessageDialog> createState() => _QueueMessageDialogState();
}

class _QueueMessageDialogState extends State<QueueMessageDialog> {
  late final TextEditingController controller;

  @override
  void initState() {
    super.initState();
    controller = TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Editar mensagem'),
      content: TextField(
        controller: controller,
        autofocus: true,
        minLines: 3,
        maxLines: 8,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(
          hintText: 'Instrução para o agente',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text),
          child: const Text('Continuar'),
        ),
      ],
    );
  }
}

class FormDialog extends StatefulWidget {
  final Json form;
  const FormDialog({super.key, required this.form});
  @override
  State<FormDialog> createState() => _FormDialogState();
}

class _FormDialogState extends State<FormDialog> {
  final formKey = GlobalKey<FormState>();
  final Map<String, dynamic> answers = {};
  final Map<String, Set<String>> selections = {};
  final Map<String, TextEditingController> controllers = {};
  late final List<Json> fields;

  @override
  void initState() {
    super.initState();
    fields = objects(widget.form['fields'])
        .where((field) => field['hidden'] != true)
        .toList();
    for (final field in fields) {
      final fieldKey = field['key'] as String;
      final fieldType = field['type'];
      final defaultValue = field['default'];
      if (fieldType == 'boolean') {
        answers[fieldKey] = defaultValue == true;
      } else if (fieldType == 'multiselect') {
        final defaults = defaultValue is List
            ? defaultValue.whereType<String>().toSet()
            : <String>{};
        selections[fieldKey] = defaults;
      } else if (fieldType != 'external' && _hasOptions(field)) {
        if (defaultValue is String) {
          answers[fieldKey] = defaultValue;
        }
      } else {
        controllers[fieldKey] = TextEditingController(
            text: defaultValue == null ? '' : defaultValue.toString());
      }
    }
  }

  @override
  void dispose() {
    for (final controller in controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  bool _hasOptions(Json field) =>
      field['options'] is List && (field['options'] as List).isNotEmpty;

  Widget _buildField(Json field) {
    final fieldKey = field['key'] as String;
    final fieldType = field['type'];
    final title = field['title'] as String? ?? fieldKey;
    final description = field['description'] as String?;

    if (fieldType == 'boolean') {
      return SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(title),
          subtitle: description == null ? null : Text(description),
          value: answers[fieldKey] as bool? ?? false,
          onChanged: (value) => setState(() => answers[fieldKey] = value));
    }

    if (fieldType == 'multiselect') {
      final selected = selections[fieldKey] ?? <String>{};
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        if (description != null) Text(description),
        Wrap(spacing: 8, children: [
          for (final option in objects(field['options']))
            FilterChip(
                label: Text(option['label'] as String? ?? ''),
                selected: selected.contains(option['value']),
                onSelected: (isSelected) => setState(() {
                      if (isSelected) {
                        selected.add(option['value'] as String);
                      } else {
                        selected.remove(option['value']);
                      }
                    }))
        ]),
        const SizedBox(height: 12),
      ]);
    }

    if (fieldType == 'string' && _hasOptions(field)) {
      final options = objects(field['options']);
      final current = answers[fieldKey] as String?;
      final initialValue =
          options.any((option) => option['value'] == current) ? current : null;
      return DropdownButtonFormField<String>(
          initialValue: initialValue,
          decoration:
              InputDecoration(labelText: title, helperText: description),
          items: [
            for (final option in options)
              DropdownMenuItem<String>(
                  value: option['value'] as String,
                  child: Text(option['label'] as String? ?? ''))
          ],
          validator: (value) => field['required'] == true && value == null
              ? 'Selecione uma opção.'
              : null,
          onChanged: (value) => answers[fieldKey] = value);
    }

    final isNumeric = fieldType == 'number' || fieldType == 'integer';
    return TextFormField(
        controller: controllers[fieldKey],
        keyboardType: isNumeric
            ? const TextInputType.numberWithOptions(decimal: true)
            : TextInputType.text,
        decoration: InputDecoration(
            labelText: title,
            helperText: fieldType == 'external'
                ? '${description ?? ''} ${field['url'] ?? ''}'.trim()
                : description,
            hintText: field['placeholder'] as String?),
        validator: (value) {
          final text = value?.trim() ?? '';
          if (field['required'] == true && text.isEmpty) {
            return 'Este campo é obrigatório.';
          }
          if (text.isNotEmpty &&
              fieldType == 'number' &&
              num.tryParse(text) == null) {
            return 'Informe um número válido.';
          }
          if (text.isNotEmpty &&
              fieldType == 'integer' &&
              int.tryParse(text) == null) {
            return 'Informe um número inteiro.';
          }
          return null;
        });
  }

  void _submit() {
    if (!(formKey.currentState?.validate() ?? false)) {
      return;
    }
    final result = <String, dynamic>{};
    for (final field in fields) {
      final fieldKey = field['key'] as String;
      final fieldType = field['type'];
      if (fieldType == 'boolean') {
        result[fieldKey] = answers[fieldKey] as bool? ?? false;
      } else if (fieldType == 'multiselect') {
        final selected = selections[fieldKey] ?? <String>{};
        final minimum =
            field['minItems'] as int? ?? (field['required'] == true ? 1 : 0);
        if (selected.length < minimum) {
          notice(context, 'Selecione pelo menos $minimum opção(ões).');
          return;
        }
        if (selected.isNotEmpty) {
          result[fieldKey] = selected.toList();
        }
      } else if (fieldType == 'string' && _hasOptions(field)) {
        final selected = answers[fieldKey];
        if (selected is String) {
          result[fieldKey] = selected;
        }
      } else {
        final text = controllers[fieldKey]?.text.trim() ?? '';
        if (text.isEmpty) {
          continue;
        }
        if (fieldType == 'number') {
          result[fieldKey] = num.parse(text);
        } else if (fieldType == 'integer') {
          result[fieldKey] = int.parse(text);
        } else {
          result[fieldKey] = text;
        }
      }
    }
    Navigator.pop(context, result);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.form['title'] as String? ?? 'Responder ao agente'),
        content: SizedBox(
            width: double.maxFinite,
            child: Form(
                key: formKey,
                child: SingleChildScrollView(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      for (final field in fields) ...[
                        _buildField(field),
                        const SizedBox(height: 12),
                      ],
                    ])))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Voltar')),
          FilledButton(
              onPressed: _submit, child: const Text('Enviar respostas'))
        ],
      );
}
