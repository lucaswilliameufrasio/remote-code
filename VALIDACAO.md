# Validação desta entrega

## Executado

- `make validate` — formatação sem diferenças, `flutter analyze --no-fatal-infos`
  sem issues, 28 testes Flutter/Dart e 7 testes de configuração Android/iOS.
- `make build-check ios-preview-build` — APK Android debug, iOS Release sem
  assinatura e iOS Simulator debug compilados.

O APK release atual está assinado com a chave debug pela configuração Gradle do
scaffold. Não o distribua; configure a assinatura release antes de publicar.

Os testes HTTP usam `MockClient`; nenhum servidor OpenCode ou endpoint externo é
chamado pela suíte automatizada. Foram adicionados contratos para fila, permissões,
MCPs e skills, além de testes de busca, linha do tempo e tela de ferramentas.

O build iOS ainda avisa que `flutter_secure_storage` não oferece suporte ao Swift
Package Manager; o Flutter informa que isso poderá virar erro numa versão futura.

## Ainda precisa de validação real

- Conectar a um servidor OpenCode v2 atual pela tailnet.
- Validar contra um servidor OpenCode v2 real: lista e substituição/cancelamento de
  itens pendentes, permissões persistentes, estado e conexão de MCPs e ativação de
  skills.
- Inspeção visual/interação no simulador iOS: o build foi gerado, mas o backend de
  entrada `serve-sim` falhou ao iniciar por falta do pacote pinned; captura de tela
  funciona, porém toques/acessibilidade não ficaram disponíveis.
- Confirmar listagem global paginada, filtro por diretório e abertura de sessão
  existente pelo ID; testar também seleção de agentes/modelos no servidor real.
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

Uma ferramenta interrompida por reboot não continua automaticamente. A retomada
valida o histórico da sessão e uma nova continuação enviada pelo usuário.
