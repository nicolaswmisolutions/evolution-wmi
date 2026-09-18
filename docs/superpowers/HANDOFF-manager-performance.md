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

A branch `prototype` **existe nos dois remotos** desde 2026-09-18, e o
`.gitmodules` já registra `branch = prototype`.

**`evolution-wmi`** (raiz):

```
b1bd29ae build(manager): track the prototype branch of the manager submodule
21ca5e4e build(manager): serve the demo-mode manager from the dev compose
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

### Fase 1 ligada nos dados reais (commit `81d2656` no submódulo)

A tela deixou de ler `mockData.ts` — o arquivo foi apagado. Agora monta o
panorama a partir de contagens ao `POST /chat/findMessages`, atrás da interface
`PerformanceSource`. Trocar para o endpoint agregado da fase 2 é apontar
`usePerformanceOverview` para outro adapter e apagar um arquivo.

Módulos novos em `src/lib/performance/`: `types.ts` (contrato), `buckets.ts`,
`delivery.ts`, `concurrency.ts`, `findMessagesSource.ts`. Os três primeiros têm
testes — **20 testes, vitest rodando em container**, com `TZ` fixo.

**Medições contra a instância conectada, não suposições:**

| O quê | Resultado |
|---|---|
| `messages.total` com `offset: 1` | Funciona; conta sem trafegar mensagens |
| `key.fromMe: true` | 118 de 211 — filtra |
| `key.fromMe: false` | 211 — **ignorado**, como o spec previa |
| Soma dos 30 buckets vs. contagem única | 161 = 161, e 96 = 96 enviadas — **fecha exato** |
| 60 requisições (série de 30 dias) | **552 ms** |

A soma bater com a contagem direta é o que prova que as janelas não se
sobrepõem nem deixam buraco: sobreposição inflaria o total, buraco o reduziria.

**O `loadTimeMs` decide a fase 2, e a medida já existe: ~550 ms.** Isso é rápido
o bastante para a fase 2 não ser urgente. A ressalva é o volume: esta medição é
sobre ~200 mensagens e sem o índice `(instanceId, messageTimestamp)`. Refazer a
medida numa instância com volume real antes de concluir.

### Dívidas do protótipo — situação

Estas **deviam ser desfeitas** na implementação real:

1. ~~A rota não usa `ProtectedRoute`~~ — **resolvido** no commit `84cc6e7`. A
   rota agora usa `<ProtectedRoute feature="performance">`, e o gate
   `performance` está amarrado a `IS_DEMO`, para que um build normal não exponha
   um dashboard fictício.
2. ~~Textos fixos em pt-BR~~ — **resolvido**: a tela inteira passou para o
   i18next nas quatro línguas.
3. ~~Banner de dados fictícios~~ — **removido**, junto com os dados fictícios.
4. A paleta das séries (verde `#189d68` / azul `#3b82f6`) **não passou pelo
   validador de daltonismo** do skill de dataviz. Mitigado com legenda e rótulos,
   mas continua pendente.
5. ~~`mockData.ts`~~ — **apagado**. O modo demo agora simula também o
   `findMessages`, com números determinísticos por janela, para que a aba
   funcione na stack de demonstração.
6. **Entrega e leitura é amostra**, não o período inteiro: as últimas 200
   enviadas, rotulado na tela. Some na fase 2.
7. **`vitest.config.ts` é separado do `vite.config.ts` de propósito** — o vitest
   2 traz o próprio Vite 5, cujos tipos conflitam com o Vite 7 do projeto e
   quebram o `tsc -b`. Some quando o vitest acompanhar o Vite 7.

## 6. Como retomar

Requer Docker Desktop rodando. **Tudo é buildado e executado em container** —
nada roda direto na máquina (preferência explícita do usuário).

São **dois** ambientes, em portas diferentes, e podem rodar ao mesmo tempo.

### Stack real — para conectar um número (porta 3000)

`docker-compose.dev.yaml`: API deste fork + Postgres 15 + Redis + manager real.

Exige um `.env` na raiz, **não versionado** (`*.env` está no `.gitignore`). Gere
a partir de `.env.example` trocando pelo menos:

| Variável | Valor local |
|---|---|
| `SERVER_URL` | `http://localhost:8080` |
| `DATABASE_CONNECTION_URI` | `postgresql://evolution:<senha>@evolution-postgres:5432/evolution?schema=public` |
| `CACHE_REDIS_URI` | `redis://evolution-redis:6379/6` |
| `AUTHENTICATION_API_KEY` | **gere uma nova** — nunca a de exemplo |
| `POSTGRES_DATABASE` / `POSTGRES_USERNAME` / `POSTGRES_PASSWORD` | consumidas pelo compose; não existem no `.env.example` |
| `TELEMETRY_ENABLED` | `false` em local |

```bash
cd /d/WMI/evolution/evolution-wmi
git submodule update --init --recursive   # se o submódulo estiver vazio
docker compose -f docker-compose.dev.yaml up -d --build
```

Login em **http://localhost:3000/manager/login** com servidor
`http://localhost:8080` e a sua `AUTHENTICATION_API_KEY`. As migrations rodam
sozinhas no start da API (`deploy_database.sh` no entrypoint).

**Duas armadilhas neste arranjo**, ambas verificadas:

1. **O campo de servidor vem preenchido errado.** O formulário sugere
   `window.location.origin`, ou seja `http://localhost:3000` — que é o nginx do
   manager, não a API. Deixar o valor sugerido faz o `verifyServer` receber HTML
   em vez de JSON e o login falhar com "servidor inválido". **Troque para
   `http://localhost:8080`.** Faz sentido no arranjo upstream, onde a própria API
   serve o manager na mesma origem; aqui eles estão separados.
2. **Não use http://localhost:8080/manager.** A API serve ali o `manager/dist`
   commitado, que está **desatualizado** — conferido: aquele bundle não tem o
   campo de headers. O `Dockerfile` da API faz `COPY ./manager ./manager` e nunca
   builda o submódulo (Task 9 do plano). O manager com as mudanças é o da
   porta 3000.

O CORS foi verificado do navegador para a API: `GET /`, o preflight `OPTIONS`
com header `apikey` e o `POST /verify-creds` respondem com
`Access-Control-Allow-Origin: http://localhost:3000`. Chave errada devolve 401.

### Stack demo — para prototipar sem backend (porta 3001)

```bash
docker compose -f docker-compose.demo.yaml up -d --build
```

O compose de demo declara `name: evolution-demo` e chama o serviço de
`manager-demo` **de propósito**. Sem isso o compose entende os dois `frontend`
como o mesmo serviço do mesmo projeto e **derruba a stack real** ao subir a
demo — aconteceu.

**http://localhost:3001/manager/login**, com **qualquer** URL e qualquer chave —
em modo demo o login sempre aceita. Dali: duas instâncias (`suporte-wmi` e
`comercial-wmi`) já conectadas, cada uma com headers de webhook diferentes, e o
botão de criar instância leva ao QR simulado, que vira `open` uns 6 segundos
depois.

Para zerar, apagar a chave `evolution-demo-state` do `localStorage` (ou usar
`resetDemoState()` de `src/lib/demo/store.ts`).

Rodar testes no submódulo (quando existirem, a partir da Task 2 do plano):

```bash
cd evolution-manager-v2
docker run --rm -v "$(pwd)":/app -w /app node:22-alpine \
  sh -c "npm ci --ignore-scripts && npm test"
```

## 7. Descobertas técnicas que importam

Levantadas na análise; não precisam ser redescobertas.

**Headers de webhook: o diagnóstico anterior estava errado.** `Webhook.headers`
(JSONB) é persistido pela API e aplicado no envio, e o `FormSchema` da página
Webhook não conhecia o campo. Mas o save **não apagava** os headers: o `update`
do Prisma recebe `undefined` quando o campo falta, e `undefined` significa "não
alterar". Medido contra a API local em 2026-09-18 — um save sem `headers` trocou
a URL e preservou os headers.

O risco real aparece **ao adicionar o campo**: com o formulário enviando
`headers` sempre, um `{}` sobrescreve os salvos. Reproduzido. Por isso o
`onSubmit` omite o campo enquanto o `find` não respondeu.

Era funcionalidade ausente, não perda de dados em curso.

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
5. ~~Ambiente com API~~ — **resolvido.** `docker-compose.dev.yaml` agora sobe API +
   Postgres + Redis + manager real. Verificado: `GET /` responde, `fetchInstances`
   autentica (401 sem chave), e as migrations criaram as tabelas.
6. **Conectar um número de verdade ainda não foi feito** — é o passo do usuário.
   A prontidão foi verificada: `instance/create` com `qrcode:true` devolveu um
   QR real (código de 217 caracteres e PNG base64 de 12 KB), o que só acontece
   se o container alcançou os servidores do WhatsApp. Sem erros no log da API.
7. **A tela de headers não foi clicada num navegador.** A lógica foi validada
   contra a API por `curl`; o formulário em si só passou por build e typecheck.
8. **O banco local está limpo** — as instâncias `teste-qr` e `teste-headers`,
   usadas nas verificações, foram apagadas.

## 9. Próximo passo sugerido

Decisão do usuário: **fechar o nível de protótipo antes de qualquer outra
coisa**, e só então conectar um número real e passar a ter dados de verdade.

Com o modo demo entregue, o protótipo está navegável de ponta a ponta. O que
falta, em ordem:

A fase 1 está completa: Tasks 1 a 8 do plano entregues, com um número real
conectado. Falta:

1. **Validar a tela num navegador, com a operação.** Nada da UI foi clicado —
   só build, typecheck e testes de lógica pura. É o gate de verdade.
2. **Task 9: buildar o submódulo no `Dockerfile` da API.** Hoje ele copia o
   `manager/dist` commitado, que está velho. Enquanto isso não for feito, o
   manager em `http://localhost:8080/manager` não tem nada desta entrega.
3. **Testes para `parseHeadersJson`.** O vitest já existe e a função já é pura;
   ficou sem cobertura.
4. **Repetir a medição de `loadTimeMs` com volume real.** Os 552 ms saíram de
   ~200 mensagens. É esse número, não a intuição, que decide a fase 2.
5. **Validador de daltonismo na paleta** (dívida 4 da seção 5).

Se a avaliação mudar as decisões, revisar o spec primeiro, depois o plano, antes
de codificar.

O spec previa o editor de headers em **pares chave/valor**; a implementação usa
**JSON**, por escolha do usuário — mostra o objeto inteiro de uma vez, que é o
que a operação quer ao diagnosticar. Se isso virar definitivo, atualizar a
seção 7 do spec.

A fase 2 (endpoint agregado no backend) só deve ser decidida com o **tempo de
carregamento medido** da fase 1 — a tela real exibe esse número no rodapé. No
protótipo ele é simulado.
