import 'package:flutter/material.dart';
import '../core/api.dart';
import '../core/models.dart';
import '../core/store.dart';
import 'chat.dart';
import 'common.dart';
import 'design.dart';
import 'sessions.dart';

const allowTailnetHttp = bool.fromEnvironment('ALLOW_TAILNET_HTTP');
const allowLocalServerHttp = bool.fromEnvironment('ALLOW_LOCAL_SERVER_HTTP');

class HomeScreen extends StatefulWidget {
  final AppStore store;
  const HomeScreen({super.key, required this.store});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

enum HomeDestination { activity, machines }

class _HomeScreenState extends State<HomeScreen> {
  final Map<String, String> _health = {};
  bool _checking = false;
  HomeDestination _destination = HomeDestination.activity;
  AppStore get store => widget.store;
  @override
  void initState() {
    super.initState();
    store.addListener(_changed);
    _check();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    store.removeListener(_changed);
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
    final api = OpenCodeApi(machine);
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
            builder: (_) => MachineEditor(store: store, machine: machine)));
    if (saved == true && mounted) {
      _check();
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
            builder: (_) =>
                ChatScreen(store: store, machine: m, session: b.session)));
  }

  @override
  Widget build(BuildContext context) {
    final onlineCount =
        _health.values.where((status) => status.startsWith('Online')).length;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: AppColors.accentSoft,
                borderRadius: BorderRadius.circular(13),
              ),
              child: const Icon(
                Icons.terminal,
                color: AppColors.accent,
                size: 21,
              ),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'REMOTO',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.7,
                      ),
                ),
                Text(
                  'OpenCode no celular',
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
            tooltip: 'Testar conexões',
            onPressed: _checking ? null : _check,
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
            _machines(onlineCount),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _destination.index,
        onDestinationSelected: (index) {
          setState(() => _destination = HomeDestination.values[index]);
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.work_outline),
            selectedIcon: Icon(Icons.work),
            label: 'Trabalho',
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
    return RefreshIndicator(
      onRefresh: _check,
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
          if (_checking) ...[
            const SizedBox(height: 18),
            const LinearProgressIndicator(),
          ],
          const SizedBox(height: 30),
          Row(
            children: [
              eyebrow('Retomar trabalho', color: AppColors.accent),
              const Spacer(),
              Text(
                '${store.bookmarks.length} recentes',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: AppColors.muted,
                    ),
              ),
            ],
          ),
          const SizedBox(height: 13),
          if (store.bookmarks.isEmpty) _emptyActivity(),
          for (final bookmark in store.bookmarks) ...[
            _bookmarkCard(bookmark),
            const SizedBox(height: 10),
          ],
          if (store.bookmarks.isNotEmpty) ...[
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
                  ? 'Tudo pronto para continuar'
                  : 'Conecte seu ambiente',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 7),
            Text(
              hasMachines
                  ? 'As sessões que você abrir vão aparecer aqui para retomar com um toque.'
                  : 'Adicione seu Mac, PC ou servidor para acessar as sessões do OpenCode.',
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
            'Abra sessões e acompanhe o OpenCode em cada ambiente.',
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

class MachineEditor extends StatefulWidget {
  final AppStore store;
  final Machine? machine;
  const MachineEditor({super.key, required this.store, this.machine});
  @override
  State<MachineEditor> createState() => _MachineEditorState();
}

class _MachineEditorState extends State<MachineEditor> {
  final form = GlobalKey<FormState>();
  late final TextEditingController name, url, user, password, directories;
  bool saving = false, obscure = true;
  @override
  void initState() {
    super.initState();
    final m = widget.machine;
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
        final api = OpenCodeApi(m);
        try {
          final h = await api.health();
          if (h['healthy'] != true) {
            throw const ApiException(0, 'Servidor não está saudável.');
          }
          if (mounted) {
            notice(context, 'Conectado ao OpenCode ${h['version'] ?? ''}.');
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
              'Use a URL HTTPS do Tailscale Serve e as credenciais do OpenCode.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppColors.muted,
                    height: 1.4,
                  ),
            ),
            const SizedBox(height: 26),
            eyebrow('Identificação', color: AppColors.accent),
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
              decoration: const InputDecoration(
                labelText: 'URL do OpenCode',
                hintText: 'https://mac.tailnet.ts.net',
                prefixIcon: Icon(Icons.link),
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
                  ? 'Defina OPENCODE_SERVER_PASSWORD na máquina.'
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
