# Remoto — OpenCode no celular

Aplicativo Flutter para Android e iOS. Conecta a várias máquinas por Tailscale,
lista e retoma sessões antigas sem exigir que elas já tenham sido abertas no
celular. O nome comercial é provisório; o projeto técnico se chama `remote_dev`.

## O que está implementado

- Cadastro/edição de várias máquinas e teste de saúde/versão.
- HTTP Basic Auth, senha e dados locais no Android Keystore/iOS Keychain.
- API HTTP OpenCode v2: sessões globais paginadas com busca por cursor opaco.
- Listagem por diretório, cadastro de caminhos e abertura direta pelo ID.
- Chat com as 200 mensagens mais recentes, abertura ancorada na última mensagem,
  atalho para voltar ao fim, Markdown e ações de ferramenta recolhidas.
- Busca de agentes e modelos; mensagens podem ser enfileiradas durante uma execução.
  Editar uma mensagem de texto pendente substitui o original e coloca a versão nova
  no fim, pois a API OpenCode v2 não edita texto em posição. Mensagens com anexos ou
  referências não compatíveis ficam protegidas contra substituição.
- MCPs com status e ações de conexão, skills disponíveis e ativação na sessão.
  Conectar/desconectar MCPs altera o estado em runtime até reiniciar o OpenCode.
- Aprovação de permissões uma vez, sempre ou negar, além de respostas às perguntas
  do agente.
- Até 100 atalhos recentes de sessões, identificados por máquina + ID, com
  diretório e rascunho persistentes.
- Atualização a cada 3 segundos em primeiro plano; reconexão com espera de até
  30 segundos. Ao retornar ao app, recarrega o histórico do servidor.
- Instaladores de serviço Linux/systemd e macOS/LaunchAgent.
- Workflow GitHub Actions para testes, APK debug e compilação iOS sem assinatura.

## Estado da entrega

Migração para a API OpenCode v2 implementada com testes de contrato HTTP. Ainda
falta validar a integração com um servidor v2 real; consulte `VALIDACAO.md` para
os testes e builds executados nesta entrega.

Os diretórios nativos `android/` e `ios/` são gerados por `scripts/bootstrap.py`
usando teu SDK Flutter, evitando um scaffold nativo manual incompleto. O script
preserva `lib/` e `pubspec.yaml` e configura os projetos recém-gerados.

## 1. Preparar cada máquina

Instale OpenCode e Tailscale. Faça login no Tailscale e configure os provedores
do OpenCode com o **mesmo usuário que já usava as sessões antigas**.

### Iniciar manualmente com Tailscale

Para este app Flutter, use `opencode serve`: ele disponibiliza a API HTTP sem a
interface web. `opencode web` é para abrir a interface do OpenCode no navegador e
não é necessário para conectar este app.

O app usa a API HTTP v2 do servidor. Servidores que oferecem somente a API
legacy v1 não são compatíveis.

Configure `OPENCODE_SERVER_PASSWORD` no ambiente do servidor usando o gerenciador
de segredos disponível para você. Não coloque a senha em argumentos de comandos,
no histórico do shell ou em arquivos versionados. O usuário HTTP padrão do OpenCode
é `opencode`. Execute o servidor com o mesmo usuário do sistema que possui as
sessões antigas.

#### Prompt oculto para uso temporário (Bash/Zsh)

Digite a senha somente no prompt oculto. O comando e a senha não ficam no histórico
do shell; mantenha este terminal aberto enquanto estiver usando o servidor:

```bash
printf 'Senha do servidor: '
read -s OPENCODE_SERVER_PASSWORD
printf '\n'
export OPENCODE_SERVER_PASSWORD
opencode serve --hostname 127.0.0.1 --port 4096
unset OPENCODE_SERVER_PASSWORD
```

Em outro terminal da workstation, publique o serviço somente pela tailnet:

```bash
tailscale serve --bg http://127.0.0.1:4096
tailscale serve status
```

O `tailscale serve` cria o endpoint HTTPS da máquina dentro da tailnet. No celular,
conecte o Tailscale e cadastre no app a URL HTTPS exibida por `tailscale serve
status`, usuário `opencode` e a senha definida acima ou fornecida pelo gerenciador
de segredos do ambiente. O servidor fica ligado apenas ao loopback; não use Funnel
nem exponha a porta 4096
publicamente. `opencode serve` permanece em primeiro plano:
mantenha o terminal do servidor ativo ou use `tmux` se precisar deixá-lo rodando
ao sair.

### Linux, incluindo CachyOS

```bash
bash host/install-linux.sh
sudo loginctl enable-linger "$USER"
tailscale serve --bg http://127.0.0.1:4096
tailscale serve status
systemctl --user status remote-dev-opencode.service
```

O instalador pede uma senha, cria um arquivo privado de ambiente e usa o
executável instalado no teu PATH. `enable-linger` permite iniciar o serviço de
usuário no boot, antes de abrir o terminal ou fazer login. Confira se `tailscaled`
também está habilitado no boot. Não execute o instalador como root.

### macOS

```bash
python3 host/install-macos.py
tailscale serve --bg http://127.0.0.1:4096
tailscale serve status
```

O LaunchAgent inicia ao fazer login. Não promete disponibilidade antes do login,
inclusive após reboot com FileVault. O computador deve estar acordado e online.
Um serviço de sistema antes do login requer configuração separada de usuário e
acesso aos dados; não é instalado por este pacote.

Se a porta 4096 já estiver em uso, pare/ajuste o servidor anterior ou altere porta
no serviço e no Tailscale Serve. O pacote não encerra processos existentes.

### Usar também no terminal

```bash
  opencode attach '<URL_EXIBIDA_PELO_TAILSCALE_SERVE>' \
  --dir '<CAMINHO_DO_PROJETO>' --session '<ID_DA_SESSAO>'
```

Anexe o TUI ao serviço persistente para terminal e celular operarem no mesmo
servidor. Execute o comando em um ambiente que disponibilize as credenciais do
servidor pelo mecanismo seguro escolhido; nunca inclua a senha no comando ou no
histórico do shell. Não precisa manter uma janela de terminal aberta para o
agente rodar.

## 2. Preparar o Flutter

Use Flutter estável 3.35 ou superior, Python 3 e Android SDK/JDK para Android.
Para iOS use teu Mac com Xcode, CocoaPods e assinatura Apple configurada.

Para testar um servidor OpenCode local no iOS Simulator, o build de depuração
aceita `ALLOW_LOCAL_SERVER_HTTP=true` e `USE_LOCAL_OPENCODE_SERVER=true`. O
segredo precisa chegar ao processo do simulador pela variável
`REMOTE_OPENCODE_SERVER_PASSWORD`; o app salva esse perfil apenas no Keychain do
simulador. Não passe senha em `--dart-define` nem habilite essa opção em release.
O servidor de teste deve continuar limitado a `127.0.0.1`.

No iOS Simulator, o app lê essa variável por um canal nativo disponível apenas
em builds `DEBUG`; o opt-in de preview também precisa estar ativo. A senha não é
incluída no binário nem nos argumentos de build e, após a leitura, é persistida
no Keychain do simulador.

```bash
python3 scripts/bootstrap.py
dart format lib test
flutter analyze --no-fatal-infos
flutter test
flutter run
```

Para gerar o APK de desenvolvimento ou o APK em modo release:

```bash
flutter build apk --debug
flutter build apk --release
```

Artefatos: `build/app/outputs/flutter-apk/app-debug.apk` e
`build/app/outputs/flutter-apk/app-release.apk`. A configuração Gradle atual
assina o variant release com a chave debug; o APK release serve para validação,
mas **não deve ser distribuído**. Configure uma chave release própria antes de
publicar.

No iOS:

```bash
open ios/Runner.xcworkspace
flutter build ipa
```

Selecione teu Development Team e um bundle identifier próprio no Xcode.
Um `Runner.app` sem assinatura do CI não é instalável em um iPhone comum;
use assinatura local/TestFlight para isso.

## 3. Cadastrar máquinas no celular

1. Instale/ative o Tailscale no Android/iPhone, na mesma tailnet.
2. Toque **Máquina** e informe nome, URL HTTPS emitida pelo Tailscale Serve,
   usuário `opencode` e a senha.
3. Cadastre opcionalmente os diretórios remotos (caminhos do PC, não do celular).
4. Teste conexão, salve e abra a máquina.
5. Use **Todas as sessões**, um diretório, ou o ícone de chave para abrir pelo ID.

Serve mantém o acesso dentro da tailnet e usa certificado HTTPS confiável.
Não habilite Funnel para este caso. Respeite as ACLs/grants da tua tailnet.
O app não gerencia o login/VPN Tailscale nem descobre dispositivos pela API
administrativa. Conecta às URLs cadastradas usando a VPN do sistema.

HTTP direto em IP `100.64.0.0/10`, IPv6 Tailscale ou MagicDNS é opcional:

```bash
python3 scripts/bootstrap.py --allow-http
flutter run --dart-define=ALLOW_TAILNET_HTTP=true
flutter build apk --debug --dart-define=ALLOW_TAILNET_HTTP=true
```

Esse opt-in relaxa ATS/cleartext no projeto nativo. O app ainda limita HTTP aos
formatos de endereço da tailnet, mas hostname curto não comprova que a rota
está passando pela VPN. Use HTTPS em operação normal. Nunca ignora certificados.

## 4. Recuperar sessões que nunca apareceram no celular

**A sessão mora na máquina, não no aplicativo Android.** A lista global consulta
o servidor e pode encontrar diretórios nunca cadastrados no celular. Abertura
pelo ID não cria uma nova sessão: carrega a sessão existente e seu diretório
remoto.

Se não encontrar uma sessão:

```bash
cd /caminho/do/projeto
opencode session list --format json
opencode db path
```

Confira usuário, HOME/XDG_DATA_HOME, instalação e caminho do banco de dados do
processo usado anteriormente. Um servidor de outro usuário não terá aquele
histórico. Sessões num banco antigo não são recuperadas apenas sabendo o ID.

Para migrar entre instalações/usuários, faça uma exportação explícita na origem
e importação no destino, sem sobrescrever nem apagar o banco original:

```bash
opencode export ses_ID > session.json
opencode import session.json
```

Confira o ID retornado após importar e abra esse ID no app. O diretório do projeto
e os arquivos precisam continuar acessíveis na máquina de destino. A importação
é uma operação no host; o app não copia bancos SQLite nem arquivos do projeto.

O filtro por diretório consulta até 500 sessões. Para continuar além desse limite,
use a lista global paginada. A API usa cursores opacos; o app não tenta inferir
posição por timestamp. O histórico do chat mostra as 200 mensagens mais recentes.

## O que reboot consegue restaurar

O serviço volta, o app reconecta, carrega o histórico persistido e permite enviar
um novo comando na mesma sessão. Várias sessões ficam disponíveis para retomada.
Trocar de tela/app não aborta o agente que continua rodando no PC.

Reboot interrompe processos, ferramentas e requisições de modelo em andamento.
O app **não retoma uma execução automaticamente** nem repete prompts que possam
ter sido recebidos antes de uma queda de conexão. Revise o histórico/diff e envie
um comando de continuação. Ele não liga um PC desligado nem evita suspensão.

## Compatibilidade e limites

Esta versão usa a API HTTP **v2** (`/api/session` e recursos relacionados), não
os endpoints legacy v1. A documentação do OpenCode ainda classifica a API HTTP
v2 como experimental e seus contratos podem evoluir. Mantenha o servidor
atualizado; servidores que só oferecem a API v1 não são compatíveis.

Permissões e formulários pendentes são consultados por sessão. O app não aprova
permissões automaticamente.

Sem terminal SSH interativo, editor completo, upload de anexos, notificações push,
VPN embutida ou sincronização de credenciais entre celulares nesta entrega.
Polling é suspenso em segundo plano; iOS não garante execução contínua do app.
Histórico é carregado do servidor ao abrir; não há cópia offline do chat.

Credenciais locais não são exportadas. Logs dos serviços podem conter conteúdo
do trabalho. Guarde os arquivos privados do host e aplique as regras de rede da
tailnet. O app não expõe porta pública e o OpenCode fica ligado apenas a loopback.

## Estrutura

```text
lib/core/         cliente HTTP, modelos e armazenamento seguro
lib/features/     máquinas, sessões, chat e solicitações do agente
host/             inicialização persistente Linux/macOS
scripts/          geração dos projetos nativos e verificações locais
test/             contratos HTTP e retomada após reiniciar o app
.github/workflows/flutter.yml
```

## Fontes usadas na implementação

- https://opencode.ai/v2/docs/api/
- https://opencode.ai/v2/docs/build/client/
- https://opencode.ai/v2/docs/cli/
- https://github.com/anomalyco/opencode/blob/dev/packages/opencode/src/session/session.ts
- https://tailscale.com/docs/reference/tailscale-cli/serve
- https://tailscale.com/docs/use-cases/application-testing/share-local-dev-server-with-team
