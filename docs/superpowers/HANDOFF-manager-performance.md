# Handoff — Aba de Performance no Manager

**Última atualização:** 2026-09-18
**Branch:** `prototype` (nos dois repositórios)

Este arquivo existe para retomar o trabalho em outra sessão sem reler todo o
histórico. Leia-o inteiro antes de tocar em código.

---

## 1. Objetivo

Expandir a view `manager` do fork com uma **aba de Performance por instância**
(dashboard de diagnóstico para o time interno de operação da WMI) e corrigir a
**perda silenciosa de headers de webhook** na interface.

Usuário-alvo definido: **time interno WMI (operação)**, não cliente final. Isso
justifica densidade de informação, jargão técnico e métricas como código de
motivo de desconexão e taxa de falha.

## 2. Onde está cada coisa

O manager **não tem fonte no repositório principal**. O fonte vive no submódulo:

| Caminho | O que é |
|---|---|
| `evolution-wmi/` | Backend (Evolution API v2.3.7). Serve `manager/dist` em `/manager` |
| `evolution-wmi/manager/dist/` | Bundle compilado, commitado como artefato (desatualizado) |
| `evolution-wmi/evolution-manager-v2/` | **Submódulo** — fonte do manager (React + Vite) |

O submódulo aponta para o fork da WMI:
`https://github.com/nicolaswmisolutions/evolution-manager-v2.git`

## 3. Documentos já escritos

| Arquivo | Conteúdo |
|---|---|
| [`specs/2026-09-17-manager-performance-design.md`](specs/2026-09-17-manager-performance-design.md) | Spec de desenho: decisões, contrato de dados, riscos |
| [`plans/2026-09-17-manager-performance.md`](plans/2026-09-17-manager-performance.md) | Plano de implementação em 9 tarefas, com código e comandos |

**Leia o spec antes do plano.** O plano assume as decisões do spec.

## 4. Estado do git

Nada foi enviado ao remoto. Tudo local, na branch `prototype`.

**`evolution-wmi`** (raiz):

```
(esta sessão)  build(manager): serve the demo-mode manager from the dev compose
a6cbe35f build(manager): bump submodule with the performance prototype
eb9dd9c7 docs(manager): add implementation plan for the performance screen
4360ad8c build(manager): point manager submodule to the WMI fork
d33672c6 docs(manager): add design spec for performance dashboard and webhook headers
```

**`evolution-manager-v2`** (submódulo), sobre `95d27b4` do fork:

```
456e4d1 feat(webhook): let the form read and write custom headers as JSON
84cc6e7 feat(demo): run the manager without a backend behind a build flag
33422b3 feat(performance): add prototype performance screen with mock data
96a7630 fix(docker): repair the manager image build
```

Árvore limpa nos dois. `.claude/` fica **fora** dos commits, por decisão do usuário.

## 5. O que já foi feito

### Conserto do build Docker do manager (commit `96a7630`)

O `Dockerfile` do submódulo copiava `postcss.config.js` e `tailwind.config.js`,
que não existem desde a migração para Tailwind 4 (que usa o plugin do Vite).
**O build de container estava quebrado.** Corrigido, e a imagem base subiu para
Node 22, exigência do Vite 7.

Esta correção vale por si só e sobrevive mesmo se o protótipo mudar de rumo.

### Protótipo da tela (commit `33422b3`)

Tela de Performance com **dados fictícios**, para validar layout e escolha de
métricas antes de investir em backend.

Arquivos:

- `src/pages/instance/Performance/mockData.ts` — dados fictícios. **Único arquivo
  descartável**; o resto é base da implementação real.
- `src/pages/instance/Performance/index.tsx` — a tela.
- `src/routes/index.tsx` — rota nova.
- `src/components/sidebar.tsx` — item de menu com ícone `Activity`.
- `src/lib/provider/features.ts` — gate `performance: { api: true, go: false }`.

Blocos na tela: 4 KPIs (total, enviadas, recebidas, **taxa de falha**), volume no
tempo (área empilhada), conexão, entrega e leitura, tipos de mensagem.

### Modo demo (commit `84cc6e7`)

O manager roda **inteiro sem backend**. Um adaptador axios responde às rotas da
Evolution API a partir de um estado em memória guardado no `localStorage`.

Com ele funcionam: login, lista de instâncias, criação de instância, fluxo de
conexão com QR, settings e webhook. Nenhuma tela sabe que o backend não existe,
o que apagou a dívida do `ProtectedRoute`.

Arquivos, todos em `src/lib/demo/`:

| Arquivo | Responsabilidade |
|---|---|
| `config.ts` | A flag `IS_DEMO` e os tempos simulados |
| `store.ts` | Estado + seed de duas instâncias, persistido no `localStorage` |
| `handlers.ts` | Tabela de rotas da API simulada |
| `adapter.ts` | Adaptador axios e sua instalação |
| `uid.ts` | Id com fallback fora de contexto seguro |

Três detalhes que custaram para descobrir e não devem ser redescobertos:

1. **O adaptador precisa ser instalado em três lugares:** `api`, `apiGlobal` e o
   `axios` padrão. Login e licença usam o padrão, e o axios 1.x **copia**
   `defaults.adapter` para cada instância no momento do `create()` — então
   setar só o global não alcança `api`/`apiGlobal`, que já existem.
2. **A flag é de build, não de runtime.** O Vite substitui `import.meta.env` em
   tempo de compilação, então um build normal não vira demo por engano. Passa
   por `ARG VITE_DEMO_MODE` no `Dockerfile` do submódulo.
3. **`/license/status` responde 404 de propósito**, reproduzindo este backend,
   que não tem o módulo. O login cai no `try/catch` e segue o fluxo normal. Se
   respondesse `inactive`, o manager redirecionaria para registro.

Rotas não simuladas respondem **501 com mensagem explícita**, para que um limite
do modo demo não seja confundido com bug de tela.

### Dívidas temporárias do protótipo

Estas **devem ser desfeitas** na implementação real:

1. ~~A rota não usa `ProtectedRoute`~~ — **resolvido** no commit `84cc6e7`. A
   rota agora usa `<ProtectedRoute feature="performance">`, e o gate
   `performance` está amarrado a `IS_DEMO`, para que um build normal não exponha
   um dashboard fictício.
2. Textos da tela de Performance **fixos em pt-BR**, fora do i18next. Na
   implementação real vão para as quatro línguas (`pt-BR`, `en-US`, `es-ES`,
   `fr-FR`). O campo de headers do webhook **já** está nas quatro.
3. Banner amarelo fixo no topo avisando que os números são fictícios.
4. A paleta das séries (verde `#189d68` / azul `#3b82f6`) **não passou pelo
   validador de daltonismo** do skill de dataviz. Mitigado com legenda e rótulos,
   mas vale validar antes de virar padrão.
5. `mockData.ts` continua a fonte da tela de Performance. O modo demo **não**
   alimenta essa tela — são dois mocks independentes, e só o de Performance é
   descartável.

## 6. Como retomar

Requer Docker Desktop rodando. **Tudo é buildado e executado em container** —
nada roda direto na máquina (preferência explícita do usuário).

```bash
cd /d/WMI/evolution/evolution-wmi

# Se o submódulo estiver vazio:
git submodule update --init --recursive

# Buildar e subir o manager
docker compose -f docker-compose.dev.yaml build frontend
docker compose -f docker-compose.dev.yaml up -d frontend
```

Abrir **http://localhost:3000/manager/login** e entrar com **qualquer** URL e
qualquer chave — em modo demo o login sempre aceita. Dali: duas instâncias
(`suporte-wmi` e `comercial-wmi`) já conectadas, cada uma com headers de webhook
diferentes, e o botão de criar instância leva ao QR simulado, que vira `open`
uns 6 segundos depois.

Para voltar ao estado inicial, apagar a chave `evolution-demo-state` do
`localStorage` (ou usar `resetDemoState()` de `src/lib/demo/store.ts`).

Para um build **sem** modo demo, basta não passar o argumento:
`docker build --build-arg VITE_DEMO_MODE=false ./evolution-manager-v2`.

Rodar testes no submódulo (quando existirem, a partir da Task 2 do plano):

```bash
cd evolution-manager-v2
docker run --rm -v "$(pwd)":/app -w /app node:22-alpine \
  sh -c "npm ci --ignore-scripts && npm test"
```

## 7. Descobertas técnicas que importam

Levantadas na análise; não precisam ser redescobertas.

**Headers de webhook são um bug de perda de dados.** `Webhook.headers` (JSONB) é
persistido pela API e aplicado em
`src/api/integrations/event/webhook/webhook.controller.ts:78`, mas o `FormSchema`
da página Webhook do manager não conhece o campo. Todo save pela UI envia payload
sem `headers`, **podendo apagar** os configurados via API. É o item de maior
prioridade do plano, acima dos gráficos.

**`findMessages` devolve `count`.** Em
`src/api/integrations/channel/whatsapp/whatsapp.baileys.service.ts:5016`, aceita
`where.messageTimestamp` (`gte` **e** `lte`, ambos obrigatórios), `messageType`,
`source` e `key.fromMe`, retornando `{ messages: { total, pages, currentPage,
records } }`. Permite agregar sem trafegar mensagens: `offset: 1` e lê o `total`.

**O filtro `fromMe` ignora `false`.** O backend testa por truthiness
(`keyFilters?.fromMe ? ... : {}`), então não dá para filtrar só recebidas.
Derivar por subtração: `recebidas = total − enviadas`.

**Não há histórico de desconexões.** A tabela `Instance` guarda apenas a
**última** (`disconnectionAt`, `disconnectionReasonCode`). Uptime real e contagem
de quedas exigem tabela nova — fase 2.

**Falta índice composto.** `Message` só tem `@@index([instanceId])`. Agregação por
janela de tempo precisa de `(instanceId, messageTimestamp)`, nos **dois** schemas
(postgresql e mysql).

**O tipo `Instance` do manager é incompleto.** Não declara `disconnectionAt` nem
`disconnectionReasonCode`, embora a API os retorne (`instanceInfo` usa `findMany`
sem `select`). O plano já tem o passo que corrige.

**O `Dockerfile` da API não builda o submódulo.** Ele faz
`COPY ./manager ./manager`, copiando o `dist` commitado. Mudanças de UI não chegam
a `/manager` em produção. Task 9 do plano resolve.

**Não há `.env` no repositório.** O `Dockerfile:22` faz
`COPY ./.env.example ./.env`, então uma API buildada daqui sobe com a chave de
exemplo `429683C4C977415CAAFCCE10F7D57E11` — o default público da Evolution API.
Só para teste local; trocar em qualquer ambiente exposto.

**Não há infraestrutura de teste.** `npm test` da API aponta para
`test/all.test.ts` e `/test/` está no `.gitignore`; o manager tem
`"test": "echo 'No tests specified'"`. O plano introduz vitest apenas para a
lógica pura de bucketização.

**O gate de licença não trava.** O commit `5a7e177` do fork adiciona checagem de
`/license/status`, mas com `try/catch` que cai no fluxo normal quando o endpoint
não existe — que é o caso deste backend. Se um dia o backend responder
`/license/status` com `inactive`, o manager passa a redirecionar para registro.

## 8. Pendências

1. **Validar o protótipo com a operação.** É o passo que estava em curso. O
   retorno esperado são ajustes de layout e de escolha de métricas.
2. **Branch `prototype` não existe no fork remoto.** Só `main`. Por isso o
   `.gitmodules` está sem a linha `branch`; adicionar depois do primeiro push.
3. **Diretório vazio travado.** `D:\WMI\evolution\evolution-manager-v2` (o clone
   irmão duplicado) teve o conteúdo apagado, mas a pasta vazia ficou presa por
   outro processo, provavelmente o VSCode. Remover do workspace e apagar.
4. **Artifact vazio.** Foi criado um artifact em claude.ai antes de ficar claro
   que tudo deveria ser Docker. Está vazio e privado; apagar se não for usado.
5. **Ambiente com API — é o próximo bloqueio.** Não existe stack local com API +
   Postgres subindo. O `docker-compose.dev.yaml` declara `env_file: - .env`
   (inexistente) e não tem banco; o `docker-compose.yaml` completo tem Postgres e
   Redis. O modo demo contorna isso para prototipagem, mas **conectar um número
   de verdade exige essa stack** — o mock não fala com o WhatsApp.
6. **A correção de headers ainda não foi provada contra backend real.** O campo
   JSON foi exercitado só contra o adaptador demo. O bug de perda silenciosa
   descrito na seção 7 continua de pé até ser testado com API e banco.

## 9. Próximo passo sugerido

Decisão do usuário: **fechar o nível de protótipo antes de qualquer outra
coisa**, e só então conectar um número real e passar a ter dados de verdade.

Com o modo demo entregue, o protótipo está navegável de ponta a ponta. O que
falta, em ordem:

1. **Avaliar o protótipo com a operação.** É o passo que estava em curso desde a
   sessão anterior e continua sendo o gate.
2. **Subir a stack com API + Postgres**, para conectar um número real
   (pendência 5). Sem ela não há dados, e sem dados a fase 1 não pode ser
   medida.
3. **Retomar o plano a partir da Task 2** (vitest). A Task 1 está feita; a Task
   3 foi entregue em forma de protótipo e precisa ser revalidada contra o
   backend real.

Se a avaliação mudar as decisões, revisar o spec primeiro, depois o plano, antes
de codificar.

O spec previa o editor de headers em **pares chave/valor**; a implementação usa
**JSON**, por escolha do usuário — mostra o objeto inteiro de uma vez, que é o
que a operação quer ao diagnosticar. Se isso virar definitivo, atualizar a
seção 7 do spec.

A fase 2 (endpoint agregado no backend) só deve ser decidida com o **tempo de
carregamento medido** da fase 1 — a tela real exibe esse número no rodapé. No
protótipo ele é simulado.
