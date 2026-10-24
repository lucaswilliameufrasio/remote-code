# Validação desta entrega

## Executado

- Na entrega de anexos, as verificações foram executadas com dependências em cache
  devido à indisponibilidade de rede: `flutter pub get --offline`,
  `make format-check test-bootstrap`, `flutter analyze --no-pub --no-fatal-infos`
  e `flutter test --no-pub` — sem issues, 83 testes Flutter/Dart e 8 testes nativos.
- Android: `./gradlew --offline app:assembleDebug` em `android/` passou. A tentativa
  `flutter build apk --debug --no-pub` falhou ao consultar dependências na rede.
- `flutter build ios --release --no-codesign --no-pub` — iOS Release compilado.
- `flutter drive --no-pub --driver=test_driver/integration_test.dart
  --target=integration_test/onboarding_test.dart` — onboarding passou no simulador iOS.

O APK release atual está assinado com a chave debug pela configuração Gradle do
scaffold. Não o distribua; configure a assinatura release antes de publicar.

Os testes HTTP usam `MockClient` e, para os anexos, o cliente de produção contra
um servidor HTTP local isolado. Nenhum servidor OpenCode ou endpoint externo é
chamado pela suíte automatizada. Há cobertura para paginação global, sessões criadas
fora do app na tela **Trabalho**, consulta de pendências por localização, permissões,
MCPs e skills. A paginação de recentes cobre lotes de 10, cursor opaco, ausência
de duplicatas, fim da listagem, reinício ao atualizar e nova tentativa após falha.
Há regressões para busca por título além da primeira página, sugestões de pastas,
deduplicação de caminhos, falhas parciais e cancelamento sem criar uma sessão.
Anexos: validação de conteúdo/tamanho/quantidade, leitura limitada de streams,
cancelamento, remoção, envio somente após confirmação, fila, falha sem reenvio
automático e resolução do modelo selecionado/da sessão/padrão.

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
- O teste de simulador cobre onboarding, não a inspeção visual completa nem fala real.
- Repetir os fluxos em dispositivos Android e iOS. O artefato iOS desta validação
  não está assinado e não é instalável diretamente em um iPhone.
- Testar o seletor nativo de arquivos em aparelhos Android/iOS e o processamento
  multimodal real por um modelo compatível. Não foram enviados anexos a provedores
  reais nem executados prompts pagos nesta validação.

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

Uma ferramenta interrompida por reboot não continua automaticamente. A retomada
valida o histórico da sessão e uma nova continuação enviada pelo usuário.
