# Validação desta entrega

## CodeRelay e Claude Code — 2026-10-24

- Identidade CodeRelay aplicada ao app, onboarding e ícones Android/iOS. Os
  artefatos contêm o mesmo PNG da marca. Bundle/application ID, pacote Dart e
  chaves de armazenamento/recuperação existentes foram preservados.
- `make validate build-check`: formatação e análise limpas, 143 testes Flutter,
  15 testes bootstrap, 9 filesystem Python, 5 Node, 3 runtime OpenCode,
  12 HTTP/SQLite Claude e 3 testes com SDK/CLI Claude reais passaram. APK debug e
  iOS Release sem assinatura compilados. O adaptador usa SDK Python 0.2.174.
- Onboarding e as três jornadas de `mobile_workflows_test.dart` passaram novamente
  no iPhone 18 Pro Max simulado (iOS 27).
- `scripts/test_local_app.py --device <simulator-id>`: três jornadas OpenCode com
  servidor real e HTTPS passaram: dois POSTs, um ACK perdido e três requisições
  ao modelo local, sem repetição automática do envio.
- `make test-claude-local-app DEVICE=<simulator-id>`: duas jornadas Flutter com o
  adaptador e Claude CLI/SDK reais por HTTPS passaram. Confirmou fork do histórico
  externo antes de conversar e negou uma ferramenta pelo chat. Quatro requisições
  ao modelo sintético local (incluindo o histórico inicial); o comando negado não
  criou seu arquivo. Esta suíte passou em duas execuções isoladas.
- A suíte Claude de host foi repetida: autenticação, raízes/symlinks, perguntas,
  aprovações por uso, limites, interrupção, reinício e reconciliação por ID. O SDK
  real confirmou a retomada e o fork sem chamar o modelo para copiar histórico.
- O cliente traduz IDs de sessão das solicitações Claude para o contrato interno
  da inbox, sem enviar rotas OpenCode ao adaptador Claude. Perfis novos escolhem
  o backend; perfis existentes não podem mudar o agente dos seus atalhos salvos.
- Nenhuma conta/credencial real de provedor foi usada, nem houve inferência paga.
  Modelo remoto substituído somente no protocolo por fixture local. Essas provas
  não validam assinatura/saldo/permissões de uma conta Anthropic real.
- O adaptador não foi implantado em produção e esta versão não foi instalada no
  iPhone físico. Recursos Claude limitados a sessões, texto/modelos, perguntas,
  aprovações por uso e interrupção; não há paridade com anexos, fila, arquivos/diff,
  pareamento ou gestão de MCP/skills do OpenCode. Limites e instalação estão em
  `host/claude-code/README.md`.

As seções abaixo são evidências históricas, anteriores a esta identidade e ao
suporte Claude Code.

## Validação local com servidor real — 2026-10-21

- `python3 scripts/test_local_app.py --device <simulator-id>`: três testes no
  iPhone 18 Pro Max (iOS 27), usando OpenCode v2.0.27 real isolado e HTTPS local.
  Cliente HTTP e telas de chat/arquivos/diff são os de produção, sem MockClient.
- Valida certificado confiável no cliente de teste e recusa o mesmo servidor
  sem essa confiança; autenticação correta passa e senha incorreta retorna 401.
- Raiz/listagem/prévia reais; recusa a symlink externo, localização fora da raiz
  e conteúdo binário. Navega até o arquivo e insere caminho no rascunho.
- Injeta 503 no proxy depois da admissão real do prompt: confirma pelo ID exato
  sem reenviar (um POST, uma confirmação perdida, uma chamada ao modelo local).
- Envia anexo textual, confirma persistência no histórico e exibe patch real
  de snapshots após a ferramenta write do OpenCode editar somente a fixture.
- Modelo externo substituído apenas no protocolo por fixture local determinística;
  não equivale a inferência real. Trust store/ATS globais e credenciais reais não
  são alterados. O armazenamento seguro do teste é em memória.
- Corrigido overflow do estado vazio do chat com teclado aberto; esta jornada
  falhava antes da correção e passou depois.
- `make validate` repetido após a correção: formatação e análise limpas,
  137 testes Flutter, 13 bootstrap, 9 filesystem Python, 5 Node e 3 runtime
  OpenCode passaram. `git diff --check` limpo.
- Android debug recompilado com `./gradlew --offline --quiet app:assembleDebug`.
- Suíte local real repetida em dois ambientes isolados consecutivos: três testes
  passaram em cada execução. Em cada uma, dois POSTs de prompt no total, somente
  um para a jornada de ACK perdido, e três chamadas ao provedor sintético local.
- As três jornadas de `mobile_workflows_test.dart` e o onboarding passaram
  novamente no simulador. O QR dessa suíte continua sendo detecção sintética.
- `flutter build ios --release --no-codesign --no-pub` passou (Runner.app 19,7 MB).
  Assinatura/provisionamento para aparelho físico continuam fora deste teste.

Esses testes não substituem aceitação autenticada do endpoint remoto nem câmera
e ditado em aparelho físico. As evidências de 2026-10-20 abaixo são históricas.

## Executado — Remote Code, continuação em 2026-10-20

- `make format-check test-bootstrap`, `flutter analyze --no-pub --no-fatal-infos`
  e `flutter test --no-pub` — sem issues, 137 testes Flutter/Dart e 13 testes de
  configuração nativa, incluindo regressões da nova identidade Android/iOS.
- Android: `./gradlew --offline --quiet app:assembleDebug` em `android/` passou,
  usando dependências em cache. O APK em `build/app/outputs/flutter-apk/app-debug.apk`
  foi inspecionado com `aapt`: nome Remote Code, ID `com.lucaswilliameufrasio.remotecode`.
- `flutter build ios --release --no-codesign --no-pub` — iOS Release compilado.
- `flutter drive --no-pub --driver=test_driver/integration_test.dart
  --target=integration_test/onboarding_test.dart` — onboarding passou no simulador iOS.
- O `Info.plist` do artefato iOS confirma o nome Remote Code e bundle ID
  `com.lucaswilliameufrasio.remotecode`.
- OpenCode local **v2.0.27**: `/openapi.json` confirma filesystem, pareamento e
  diff. Consulta de `lib/core` confirmou o formato das entradas e leitura de
  `pubspec.yaml` com `Range: bytes=0-63` retornou 64 bytes. Essas consultas foram
  manuais e somente leitura, fora da suíte isolada. Não foi criado/resgatado um
  código real de pareamento nem executado prompt.
- GitHub renomeado para `lucaswilliameufrasio/remote-code`, com PR1 preservada.
- `make test-host`: 9 testes Python de filesystem real, 5 testes Node do adaptador
  e verificações de sintaxe. Inclui traversal, raízes vazias, links simbólicos,
  troca de ancestral entre aberturas, FIFO, limite de bytes, Unicode, cancelamento
  e limite de quatro subprocessos.
- `make test-host-runtime`: 3 testes em OpenCode v2.0.27 isolado, com HOME, banco,
  configuração e credenciais sintéticas próprias: registro/leitura reais,
  autenticação 401, raízes configuradas e recusas por fora-da-raiz/symlink. Nenhum
  serviço ou configuração existente foi alterado. Não foi necessário instalar SDK npm.
- `make test-mobile-simulator`: 3 jornadas no simulador iOS (arquivos/diff partindo
  do chat, reconciliação sem reenvio e confirmação após QR). APIs e detecção QR
  são fixtures injetadas, não uma validação de câmera ou servidor remoto reais.

O APK desta fatia é debug. O APK release da entrega anterior não foi atualizado.
Configure assinatura release antes de publicar. O bundle novo é uma instalação
separada: não apague o app antigo antes de recadastrar e conferir suas máquinas.

Os testes HTTP usam `MockClient` e o cliente de produção contra um servidor HTTP
local isolado para anexos, filesystem, diff e pareamento. Nos testes de pareamento,
um transporte de teste preserva a validação de origem HTTPS e encaminha somente
ao servidor local; não valida TLS real. A suíte Flutter não chama OpenCode real;
o teste separado `test-host-runtime` chama somente o servidor isolado que inicia.
Nenhum endpoint externo ou prompt real é usado. Há cobertura para paginação global, sessões criadas
fora do app na tela **Trabalho**, consulta de pendências por localização, permissões,
MCPs e skills. A paginação de recentes cobre lotes de 10, cursor opaco, ausência
de duplicatas, fim da listagem, reinício ao atualizar e nova tentativa após falha.
Há regressões para busca por título além da primeira página, sugestões de pastas,
deduplicação de caminhos, falhas parciais e cancelamento sem criar uma sessão.
Anexos: validação de conteúdo/tamanho/quantidade, leitura limitada de streams,
cancelamento, remoção, envio somente após confirmação, fila, falha sem reenvio
automático e resolução do modelo selecionado/da sessão/padrão.
Filesystem/diff: navegação, escolha explícita, busca com descarte de respostas
atrasadas, limites de prévia, binários, caminhos inseguros, erros de autorização,
redirects recusados e patches legíveis. Pareamento: confirmação explícita,
uso único sem retry, checagem v2, saída durante requisição e persistência só ao
salvar máquina. Aprovações: contexto persistente, bloqueio de resposta duplicada
e atualização de pedido resolvido em outro dispositivo.
Reconciliação: ID escolhido pelo cliente, confirmação pelo mesmo ID no ACK,
histórico ou inbox, persistência do marcador, retorno à sessão, bloqueio de envio
enquanto incerto e preservação de rascunho editado. Ausência numa consulta não é
tratada como prova de falha; liberação manual exige confirmação e não reenvia nada.
O marcador guarda ID/texto no armazenamento seguro, nunca bytes dos anexos.

Uma consulta SSH somente leitura confirmou que a sessão relatada existe no serviço
OpenCode v2.0.29 remoto e ocupa a posição 17 (segunda página de 10). O endpoint
publicado pela tailnet aponta para outro processo na porta 4096, com autenticação:
sua resposta autenticada ainda não foi comparada à do serviço compartilhado.

O build iOS ainda avisa que `flutter_secure_storage` não oferece suporte ao Swift
Package Manager; o Flutter informa que isso poderá virar erro numa versão futura.

## Ainda precisa de validação real

- Conectar a um servidor OpenCode v2 atual pela tailnet.
- Validar contra um servidor OpenCode v2 real: lista e substituição/cancelamento de
  itens pendentes, permissões persistentes, estado e conexão de MCPs e ativação de
  skills.
- Confirmar no servidor OpenCode v2 real que uma sessão recém-criada no computador
  aparece em **Trabalho**, e testar pendências pelos endpoints de localização,
  paginação global, filtro por diretório, abertura por ID e seleção de agentes/modelos.
- Os testes de simulador cobrem onboarding e jornadas móveis com fixtures,
  não câmera física, inspeção visual completa nem fala real.
- Repetir os fluxos em dispositivos Android e iOS. O artefato iOS desta validação
  não está assinado e não é instalável diretamente em um iPhone.
- Testar o seletor nativo de arquivos em aparelhos Android/iOS e o processamento
  multimodal real por um modelo compatível. Não foram enviados anexos a provedores
  reais nem executados prompts pagos nesta validação.
- Testar explorador/diff e pareamento na instância v2.0.29 publicada pela tailnet.
  A validação local v2.0.27 não comprova o endpoint remoto nem TLS no celular.
- QR e reconciliação estão implementados e testados com fixtures; captura física
  e integração com a instância real ainda precisam de aceitação.
- A extensão de raízes está implementada e validada em host local isolado, mas
  precisa ser instalada/configurada pelo operador no host desejado. Não houve
  implantação automática. Sem ela, o explorador recusa funcionar. Essa restrição
  cobre somente o RPC do explorador, não as ferramentas do agente ou os endpoints
  nativos usados por outros clientes.
- Nenhum Android físico está disponível na descoberta atual. Uma entrada
  `devicectl` repete o UUID do simulador e não foi contada como teste em iPhone
  físico. Não houve uso de outro iPhone listado como indisponível.
- Avisos de compatibilidade futura: `mobile_scanner` ainda aplica Kotlin Gradle
  Plugin, e `flutter_secure_storage` ainda não suporta Swift Package Manager.

## Aceitação em máquina e celular reais

1. Iniciar o servidor com o mesmo usuário que criou sessões antigas.
2. Criar/identificar sessões em diretórios diferentes pelo terminal.
3. Conectar o celular via Tailscale e abrir as sessões pela listagem global.
4. Abrir uma sessão antiga pelo ID, sem cadastro prévio do diretório no app.
5. Enviar um prompt; conferir resposta, ferramentas e solicitações de permissão.
6. Enquanto o agente executa, confirmar que o app bloqueia um segundo envio e
   permite interromper a tarefa.
7. Responder a um formulário do agente e confirmar que ele continua.
8. Trocar de sessão; garantir que o trabalho continua no servidor.
9. Desligar a VPN, escrever um rascunho e reativá-la para conferir reconexão.
10. Reiniciar o PC e o app; conferir histórico, máquinas, atalhos e rascunhos.
11. Repetir em Android e iPhone; no iPhone validar assinatura e Keychain.
12. Abrir **Pendências**, conferir perguntas/permissões de sessões salvas e ativas,
    atualizar a lista e abrir cada item na sessão correspondente.
13. Abrir **Projetos**, confirmar agrupamento por máquina e abrir as sessões do
    diretório escolhido.
14. Ditar uma mensagem em Android/iOS, revisar/editar a transcrição, cancelar um
    ditado e confirmar que nada é enviado sem tocar no envio normal.
15. Criar uma sessão pelo terminal do computador e conferir se aparece em
    **Trabalho** ao reabrir a aba ou puxar para atualizar.
16. Em **Trabalho**, tocar em **Carregar mais 10 sessões** da máquina indicada;
    conferir que a lista cresce sem duplicatas e que o botão desaparece ao final.
17. Buscar em **Trabalho** pelo título de uma sessão fora da primeira página;
    confirmar que a API retorna a sessão e que o botão do topo atualiza a lista.
18. Em **Nova sessão**, escolher um projeto/pasta sugerida sem digitar o caminho;
    repetir com caminho manual e cancelar antes da criação.
19. Em **Anexar arquivo**, selecionar imagem/PDF/texto, remover antes do envio e
    enviar normalmente ou pela fila. Conferir rejeição de arquivos não suportados,
    limite total de 5 MiB e modelo sem suporte a imagens/PDF.
20. Abrir **Arquivos do projeto**, navegar/buscar, ler texto e inserir caminho no
    rascunho; confirmar que isso não envia prompt nem anexa conteúdo. No seletor de
    diretório, explorar uma pasta conhecida e escolher a subpasta explicitamente.
21. Abrir **Ver alterações**, conferir a base do turno e revisar patches grandes.
22. Cadastrar uma máquina por código temporário da mesma instância, conferir o
    host HTTPS e salvar. Cancelar antes de salvar não deve persistir a credencial.
23. Ler QR da mesma máquina e confirmar separadamente; recusar QR de outra origem
    e repetir por entrada manual quando a câmera estiver indisponível.
24. Interromper a resposta de envio após admissão, reabrir a sessão e verificar a
    confirmação por ID sem novo POST. Sem confirmação, conferir histórico/fila e
    cancelar ou confirmar explicitamente a liberação de outro envio.
25. No host de teste autorizado, instalar a extensão com raízes explícitas e
    conferir rejeição de acesso externo/symlinks. Não usar isso como sandbox do agente.

Uma ferramenta interrompida por reboot não continua automaticamente. A retomada
valida o histórico da sessão e uma nova continuação enviada pelo usuário.
