import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/models.dart';
import 'common.dart';
import 'design.dart';

class MachineSetupScreen extends StatelessWidget {
  final AgentBackend backend;

  const MachineSetupScreen({super.key, required this.backend});

  @override
  Widget build(BuildContext context) {
    final isClaude = backend == AgentBackend.claudeCode;
    return Scaffold(
      appBar: AppBar(title: const Text('Configurar no computador')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(22, 16, 22, 32),
        children: [
          Text(backend.label, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 12),
          const InfoBox(
            'Este guia funciona offline. Execute os comandos no computador, nunca no celular. Copiar não executa nem configura serviços automaticamente.',
            icon: Icons.computer_outlined,
          ),
          const SizedBox(height: 20),
          if (isClaude)
            ..._claudeSteps(context)
          else
            ..._openCodeSteps(context),
          _step(
            context,
            'No celular: testar e salvar',
            'Ative o Tailscale no celular e conecte à mesma tailnet do computador. Volte ao cadastro, mantenha ${backend.label} selecionado e informe a URL HTTPS exibida pelo Tailscale Serve, incluindo a porta se houver. Não use localhost ou 127.0.0.1 no celular.',
          ),
          _step(
            context,
            'Qual usuário e senha usar?',
            isClaude
                ? 'Usuário: coderelay. Senha: a senha dedicada do adaptador que você digitou no computador. Nunca informe chave de API, token OAuth ou senha da Anthropic no app. Toque em Testar e depois em Salvar máquina. O teste confirma o adaptador, não saldo, assinatura ou disponibilidade do modelo.'
                : 'Usuário padrão: opencode. Senha: a senha definida em OPENCODE_SERVER_PASSWORD no computador. Toque em Testar e depois em Salvar máquina. Você também pode usar o pareamento temporário explicado abaixo; a credencial só é guardada ao salvar.',
          ),
          if (!isClaude) ...[
            _step(
              context,
              'Opcional: código temporário de pareamento',
              'Em outro terminal do computador, conectado à mesma instância OpenCode e autenticado, gere um código com o comando abaixo. No app, toque em Usar código temporário de pareamento, confira o destino HTTPS e digite somente o campo code da resposta. O código expira e é de uso único; não o compartilhe. O comando não contém a senha e requer a autenticação local do CLI.',
            ),
            const _SetupCommand(
              title: 'Gerar código no computador',
              command: 'opencode api post /api/pair',
            ),
          ],
          _step(
            context,
            'Se não conectar',
            'Confira Tailscale ativo nos dois dispositivos, a mesma tailnet, suas regras de acesso, URL/porta e o processo ainda aberto no computador. HTTP 401 indica autenticação recusada. Um timeout ou erro de DNS não é corrigido gerando outra senha. Se já existir uma instalação funcionando, reutilize sua URL em vez de abrir um segundo serviço.',
          ),
          _step(
            context,
            'Encerrar sem afetar outros serviços',
            'Os comandos deste guia mantêm o servidor em primeiro plano: deixe o terminal aberto durante o uso e pressione Ctrl-C para pará-lo. A rota Serve em background permanece configurada; remova apenas a rota que você criou, depois de conferir o status. Não use reset, não ative Funnel e não substitua rotas de outros aplicativos.',
          ),
        ],
      ),
    );
  }

  List<Widget> _openCodeSteps(BuildContext context) => [
        _step(
          context,
          '1. Preparar OpenCode e Tailscale',
          'Instale OpenCode v2 e Tailscale no computador. Faça login e configure os provedores do OpenCode com o mesmo usuário do sistema que possui suas sessões antigas. Este exemplo usa Bash ou Zsh em macOS/Linux. Não envie credenciais de provedores ao celular.',
        ),
        const SelectableText('Documentação: https://opencode.ai/v2/docs/'),
        _step(
          context,
          '2. Iniciar o servidor com senha',
          'Se já existe um OpenCode protegido, não inicie outro: use a instalação existente. Caso contrário, entre na pasta do projeto e use o bloco abaixo. Digite uma senha forte no prompt oculto; não substitua o comando por uma senha literal. O servidor escuta somente no próprio computador.',
        ),
        const _SetupCommand(
          title: 'Iniciar OpenCode · Bash/Zsh',
          command: r'''printf 'Senha do OpenCode: '
read -r -s OPENCODE_SERVER_PASSWORD
printf '\n'
export OPENCODE_SERVER_PASSWORD
opencode serve --hostname 127.0.0.1 --port 4096
unset OPENCODE_SERVER_PASSWORD''',
        ),
        ..._serveSteps(context, port: 4096, httpsPort: 443),
      ];

  List<Widget> _claudeSteps(BuildContext context) => [
        _step(
          context,
          '1. Preparar o adaptador Claude Code',
          'O Claude Code precisa do adaptador CodeRelay no computador; ele não oferece a API do OpenCode. Use macOS/Linux com Python 3.11+, Git, Make e Tailscale. Configure a autenticação do provedor no host conforme a documentação oficial do Agent SDK; ela fica separada da senha do adaptador. Não copie suas credenciais Anthropic para este app.',
        ),
        const SelectableText(
            'Documentação: https://code.claude.com/docs/en/agent-sdk/quickstart'),
        _step(
          context,
          '2. Instalar os arquivos do CodeRelay',
          'Se você ainda não possui o repositório, obtenha-o com o bloco abaixo. Caso já tenha uma cópia, entre nela e pule o clone para não sobrescrever seu trabalho. A instalação cria um ambiente Python local; não instala um serviço nem altera o OpenCode.',
        ),
        const _SetupCommand(
          title: 'Obter o repositório',
          command:
              'git clone https://github.com/lucaswilliameufrasio/remote-code.git\ncd remote-code',
        ),
        const _SetupCommand(
          title: 'Instalar o adaptador · na pasta do repositório',
          command: 'make setup-claude',
        ),
        _step(
          context,
          '3. Escolher a raiz e iniciar',
          'No bloco abaixo, substitua /caminho/real/do/projeto por uma pasta de projeto existente, absoluta e sem links simbólicos. Não use /. A raiz controla quais sessões o adaptador expõe, mas não é uma sandbox para ferramentas aprovadas. Use uma senha dedicada aleatória de pelo menos 24 caracteres, digitada no prompt oculto. Execute na pasta do repositório.',
        ),
        const _SetupCommand(
          title: 'Iniciar adaptador Claude · Bash/Zsh',
          command: r'''printf 'Senha do adaptador: '
read -r -s CODERELAY_ADAPTER_PASSWORD
printf '\n'
export CODERELAY_ADAPTER_PASSWORD
host/claude-code/.venv/bin/python host/claude-code/server.py \
  --root "/caminho/real/do/projeto" \
  --state-directory "$HOME/.local/state/coderelay-claude" \
  --port 4097
unset CODERELAY_ADAPTER_PASSWORD''',
        ),
        ..._serveSteps(context, port: 4097, httpsPort: 8443),
        _step(
          context,
          'O que esta integração oferece',
          'Sessões, histórico, texto, escolha de modelo, perguntas, aprovações por uso e interrupção. Sessões antigas abrem em leitura; continuar cria uma cópia confirmada do histórico, mas os arquivos do projeto continuam compartilhados. Anexos, fila, pareamento/QR, arquivos/diff e gestão de MCP/skills continuam específicos do OpenCode. Para usar os dois agentes no mesmo computador, crie dois cadastros separados.',
        ),
      ];

  List<Widget> _serveSteps(BuildContext context,
          {required int port, required int httpsPort}) =>
      [
        _step(
          context,
          'Publicar somente na rede privada',
          'Em outro terminal, confira o status primeiro. Só execute o comando de publicação se a porta HTTPS $httpsPort estiver livre e a porta local $port pertencer ao servidor que você acabou de iniciar. Se a porta estiver ocupada, não substitua a rota: use o endpoint existente ou escolha outra porta livre. Serve é privado; não é necessário nem recomendado usar Funnel.',
        ),
        const _SetupCommand(
            title: 'Conferir rotas existentes',
            command: 'tailscale serve status'),
        _SetupCommand(
          title: 'Publicar se a porta HTTPS $httpsPort estiver livre',
          command:
              'tailscale serve --bg --https=$httpsPort http://127.0.0.1:$port',
        ),
        const _SetupCommand(
            title: 'Consultar a URL HTTPS para o app',
            command: 'tailscale serve status'),
      ];

  Widget _step(BuildContext context, String title, String description) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(description),
        ]),
      );
}

class _SetupCommand extends StatelessWidget {
  final String title;
  final String command;

  const _SetupCommand({required this.title, required this.command});

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(title)),
              IconButton(
                tooltip: 'Copiar: $title',
                icon: const Icon(Icons.copy_outlined),
                onPressed: () async {
                  try {
                    await Clipboard.setData(ClipboardData(text: command));
                    if (context.mounted) {
                      notice(
                          context, 'Comando copiado. Execute no computador.');
                    }
                  } catch (_) {
                    if (context.mounted) {
                      notice(context,
                          'Não foi possível copiar. Selecione o comando manualmente.');
                    }
                  }
                },
              ),
            ]),
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SelectableText(command,
                  style: const TextStyle(
                      fontFamily: 'monospace', color: AppColors.accent)),
            ),
          ]),
        ),
      );
}
