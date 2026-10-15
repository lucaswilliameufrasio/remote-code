# Validação desta entrega

## Executado

- `make validate` — formatação sem diferenças, `flutter analyze --no-fatal-infos`
  sem issues, 59 testes Flutter/Dart e 8 testes de configuração Android/iOS.
- `make build-check` — APK Android debug e iOS Release sem assinatura compilados.
- `make test-ios-simulator` — fluxo de onboarding passou no simulador iOS.

O APK release atual está assinado com a chave debug pela configuração Gradle do
scaffold. Não o distribua; configure a assinatura release antes de publicar.

Os testes HTTP usam `MockClient`; nenhum servidor OpenCode ou endpoint externo é
chamado pela suíte automatizada. Há cobertura para paginação global, sessões criadas
fora do app na tela **Trabalho**, consulta de pendências por localização, permissões,
MCPs e skills. A paginação de recentes cobre lotes de 10, cursor opaco, ausência
de duplicatas, fim da listagem, reinício ao atualizar e nova tentativa após falha.

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

Uma ferramenta interrompida por reboot não continua automaticamente. A retomada
valida o histórico da sessão e uma nova continuação enviada pelo usuário.
