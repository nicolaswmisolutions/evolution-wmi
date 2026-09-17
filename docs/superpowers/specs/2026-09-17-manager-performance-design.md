# Dashboard de Performance e Headers por Instância no Manager

**Data:** 2026-09-17
**Repositório:** `evolution-wmi` (fork de Evolution API v2.3.7), branch `prototype`
**Status:** desenho aprovado, pronto para plano de implementação

---

## 1. Objetivo

Expandir a view `manager` com uma aba de **Performance por instância**, voltada ao time
interno de operação da WMI, e corrigir a ausência de **headers personalizados de webhook**
na interface.

O usuário-alvo é a operação interna, não o cliente final. Isso orienta as escolhas: a tela
prioriza diagnóstico ("essa instância caiu? por que as mensagens não entregam?") e tolera
densidade de informação e vocabulário técnico.

## 2. Contexto do repositório

Levantado antes do desenho, e relevante para entender as decisões:

- O manager **não tem fonte neste repositório**. `manager/dist/` contém apenas o bundle
  compilado, commitado como artefato. O fonte está no submódulo `evolution-manager-v2`
  (React 18 + Vite + TypeScript + Tailwind + shadcn/radix, com `recharts` e
  `@tanstack/react-query` já nas dependências).
- O backend só serve estático: `src/api/routes/view.router.ts` monta `manager/dist` em
  `/manager` com fallback de SPA.
- O dashboard de instância atual (`src/pages/instance/DashboardInstance/index.tsx`) tem
  card de conexão/QR e três contadores totais vindos do `_count` de `fetchInstances`.
  Nenhum recorte temporal, nenhum gráfico.
- O manager suporta dois backends: Evolution API e Evolution Go (`getProvider() === "go"`,
  com queries paralelas em `src/lib/queries/go/`).
- `DATABASE_SAVE_DATA_NEW_MESSAGE` e `DATABASE_SAVE_MESSAGE_UPDATE` são opt-in. **Nos
  ambientes da WMI ambos estão ligados**, o que viabiliza métricas com histórico retroativo.

### Bug identificado: perda silenciosa de headers

`Webhook.headers` (JSONB) é persistido pela API e aplicado no envio em
`src/api/integrations/event/webhook/webhook.controller.ts:78`. A página Webhook do manager
não conhece o campo: seu `FormSchema` cobre apenas `enabled`, `url`, `events`, `base64` e
`byEvents`.

Consequência: quem configurou headers via API não os vê na UI, e **qualquer save feito pela
UI envia um payload sem `headers`, podendo apagá-los**. É perda de dados, não apenas uma
funcionalidade ausente. Por isso tem prioridade sobre os gráficos.

## 3. Escopo

### Dentro

1. Correção dos headers de webhook (exibir, editar, preservar no save).
2. Aba `Performance` nova por instância, com:
   - volume de mensagens no tempo (enviadas vs. recebidas);
   - saúde da conexão;
   - entrega e leitura (amostra, na fase 1);
   - distribuição por tipo de mensagem.
3. Fork do `evolution-manager-v2` para a organização da WMI e repontamento do submódulo.
4. Build do submódulo dentro do Docker.

### Fora

- Métricas agregadas entre instâncias (visão de frota).
- Alertas, notificações ou limiares.
- Alterações no endpoint `/metrics` do Prometheus.
- Histórico de desconexões persistido (ver seção 7 — depende de tabela nova, fase 2).
- Suporte ao provider Evolution Go nesta entrega: a aba Performance fica oculta quando
  `getProvider() === "go"`, porque as queries e o modelo de dados do Go não foram
  analisados.

## 4. Estratégia de entrega: duas fases

Decisão do product owner: **construir o frontend primeiro, sem tocar no backend**, para
validar o layout com a operação antes de investir em endpoint e migration.

O risco dessa ordem é retrabalho. Ele é mitigado por uma fronteira única de dados, definida
já na fase 1 no formato que a fase 2 vai devolver:

```
DashboardPerformance (tela, recharts)
        ↓ consome
usePerformanceOverview(instanceName, period)   ← hook React Query
        ↓ delega
  PerformanceSource  (interface estável)
    ├── findMessagesSource   ← fase 1: N counts via /chat/findMessages
    └── analyticsSource      ← fase 2: 1 GET /analytics/overview/:instance
```

A tela conhece apenas o hook; o hook conhece apenas a interface. Migrar para a fase 2
significa trocar o wiring da fonte e apagar um arquivo. Tela, gráficos e tipos permanecem.

### Contrato de dados

```ts
type Period = "24h" | "7d" | "30d";

type DeliveryStatus = "PENDING" | "SERVER_ACK" | "DELIVERY_ACK" | "READ" | "ERROR";

type PerformanceOverview = {
  period: Period;
  generatedAt: string;               // ISO 8601
  series: Array<{
    bucket: string;                  // ISO 8601, início do bucket
    sent: number;
    received: number;
    partial?: boolean;               // true se o count desse bucket falhou
  }>;
  totals: { sent: number; received: number; total: number };
  messageTypes: Array<{ type: string; count: number }>;
  delivery: {
    counts: Record<DeliveryStatus, number>;
    sampled: boolean;                // true na fase 1
    sampleSize: number;
  };
  connection: {
    status: string;
    since: string | null;
    lastDisconnectAt: string | null;
    lastDisconnectReason: number | null;
    historyAvailable: boolean;       // false na fase 1
  };
  degraded: Array<{ metric: string; reason: string }>;
  loadTimeMs: number;                // instrumentação, ver seção 5.1
};
```

Os campos `sampled`, `historyAvailable` e `degraded` são deliberados. Eles obrigam a tela a
declarar quando um número é amostra ou está indisponível, em vez de exibir zero. Numa tela
de diagnóstico, um zero ambíguo leva a operação a investigar o problema errado.

## 5. Fase 1 — somente frontend

Rota nova `/manager/instance/:instanceId/performance`, com entrada no menu lateral do
`InstanceLayout`. O dashboard atual permanece intocado como tela de conexão/QR.

Seletor de período no topo: **24h (padrão)**, 7d, 30d.

Base: `POST /chat/findMessages` (`src/api/integrations/channel/whatsapp/whatsapp.baileys.service.ts:5016`)
aceita `where.messageTimestamp` (`gte` **e** `lte`, ambos obrigatórios), `where.messageType`,
`where.source` e `where.key.fromMe`, retornando `count` total além das mensagens. Isso
permite obter agregados sem trafegar mensagens: basta pedir `offset: 1` e ler o `count`.

### 5.1 Volume no tempo

Buckets: 24 horários (24h), 7 diários (7d), 30 diários (30d).

Por bucket, dois counts: total e `key.fromMe: true`. **`received = total − sent`.**

> O filtro `fromMe` do backend usa teste de truthiness
> (`keyFilters?.fromMe ? { ... } : {}`), portanto `fromMe: false` é ignorado e não é
> possível filtrar apenas recebidas. A subtração é a única via correta.

Custo da série: 48 requisições para 24h, 60 para 30d. Somadas à amostra de entrega (1) e
aos counts por tipo de mensagem (seção 5.4), o carregamento completo da tela fica em torno
de **57 requisições para 24h e 69 para 30d**. Todas disparadas com **concorrência limitada
a 6** e cacheadas pelo React Query.

A tela **cronometra o próprio carregamento** e exibe `loadTimeMs` no rodapé. Isso é
intencional: transforma a decisão de investir na fase 2 em evidência medida em vez de
intuição.

### 5.2 Saúde da conexão

Sem requisição nova. `connectionStatus`, `disconnectionAt` e `disconnectionReasonCode` já
vêm no objeto `instance` do `InstanceContext`, populado por `fetchInstances`.

`historyAvailable: false` na fase 1 — a tabela `Instance` guarda apenas a **última**
desconexão, não um histórico. A tela exibe "histórico de quedas indisponível" em vez de um
gráfico vazio.

### 5.3 Entrega e leitura

Ponto mais fraco da fase 1, aceito conscientemente.

Não há filtro por status no `findMessages`, então a única via é baixar mensagens e agregar
o `MessageUpdate.status` que vem no retorno. O `select` do backend inclui o campo `message`
inteiro (JSON, com payload de mídia), o que torna o payload pesado.

Decisão: **amostra das 200 mensagens mais recentes**, uma requisição (`offset: 200,
page: 1`), com `sampled: true` e o card rotulado explicitamente como
"amostra das últimas 200 mensagens". Não é a taxa de entrega do período; é indicador
direcional.

### 5.4 Tipos de mensagem

Um count por `messageType` sobre o período, usando uma **lista fixa de tipos** definida no
frontend (`conversation`, `extendedTextMessage`, `imageMessage`, `audioMessage`,
`videoMessage`, `documentMessage`, `stickerMessage`, `reactionMessage`) — a API não expõe
endpoint de tipos distintos, então a lista é uma escolha do cliente e tipos fora dela não
aparecem.

Custo: 8 requisições. Ajuda a operação a identificar uso anômalo (pico de áudio, mídia
pesada).

## 6. Fase 2 — backend

Não faz parte desta entrega; registrado para que a fase 1 não feche portas.

- `AnalyticsService` em `src/api/services/`, controller fino e router seguindo o padrão
  RouterBroker com `dataValidate` e JSONSchema7, conforme `.cursor/rules/`.
- `GET /analytics/overview/:instance?period=` devolvendo `PerformanceOverview` em uma
  chamada, com agregação SQL (`date_trunc` + `GROUP BY`) e cache curto no `CacheService`
  existente (Redis com fallback node-cache).
- Migration adicionando índice composto `(instanceId, messageTimestamp)` em `Message`.
  **Obrigatoriamente nos dois schemas** (`postgresql-schema.prisma` e
  `mysql-schema.prisma`) e nas duas pastas de migrations — hoje só existe
  `@@index([instanceId])`.
- Tabela de histórico de conexão, para habilitar uptime e contagem de quedas
  (`historyAvailable: true`).
- Entrega e leitura calculada sobre a população do período, eliminando `sampled`.

## 7. Headers personalizados de webhook

Permanecem na página **Webhook**, alinhados a como a API organiza o dado
(`POST /webhook/set/:instance`, `GET /webhook/find/:instance`). Levá-los para Settings faria
a UI divergir da API sem ganho.

Trabalho:

1. Adicionar `headers` ao `FormSchema` como lista de pares chave/valor.
2. Carregar os headers existentes vindos do `find` ao montar o formulário.
3. Reenviá-los no save, encerrando a perda silenciosa descrita na seção 2.

Este item é o **primeiro a ser implementado**: é correção de perda de dados e independe de
todo o resto.

## 8. Tratamento de erros

A tela distingue três estados que hoje colapsariam em "0":

| Estado | Apresentação |
|---|---|
| Requisição falhou | Mensagem de erro no card + ação de tentar novamente |
| Métrica indisponível nesta fase | Card em estado `degraded`, com o motivo |
| Zero legítimo no período | Valor zero, sem alarme |

Se parte dos counts da série falhar, a série é renderizada com os buckets obtidos e os
demais marcados com `partial: true` (lacuna visível no gráfico), em vez de descartar o
resultado inteiro.

## 9. Testes

O repositório não tem infraestrutura de teste: o `npm test` da API aponta para
`test/all.test.ts` e `/test/` está no `.gitignore`; o manager-v2 tem
`"test": "echo 'No tests specified'"`. Este desenho não propõe mudar isso de forma ampla.

Escopo de teste, deliberadamente cirúrgico: instalar `vitest` no fork do manager e cobrir
**apenas a lógica pura de bucketização e agregação** — fronteiras de período, conversão
para `messageTimestamp` (segundos Unix), fuso horário e soma por bucket. É onde os erros se
escondem em silêncio: um off-by-one de fuso desloca o gráfico inteiro em uma hora sem
nenhum sintoma visível.

Componentes de gráfico e chamadas HTTP ficam em teste manual, coerente com o repositório.

## 10. Build e deploy

Hoje o `Dockerfile:25` faz `COPY ./manager ./manager`, copiando o `dist` pré-compilado
commitado. O submódulo nunca é buildado, então mudanças na UI não chegam ao ar sozinhas.

Decisão: **buildar o submódulo dentro do Docker**. Estágio novo que executa
`npm ci && npm run build` em `evolution-manager-v2/` e copia o resultado para
`manager/dist`.

Implicações a tratar na implementação:

- O CI e qualquer clone precisam de `git submodule update --init --recursive`.
- O tempo de build aumenta (instalação de dependências do frontend).
- O `manager/dist` commitado deixa de ser a fonte de verdade. Ele é **mantido no
  versionamento até o build via Docker ser verificado em deploy real**, e removido logo
  depois. Manter os dois indefinidamente garante que uma hora alguém publique o artefato
  velho sem perceber.

## 11. Passos de infraestrutura

1. Forkar `evolution-foundation/evolution-manager-v2` para a organização da WMI.
2. Apontar `.gitmodules` para o fork e atualizar o commit registrado do submódulo.
3. Criar branch de trabalho no fork.

O submódulo foi inicializado localmente em `3137df46` durante a análise.

## 12. Riscos conhecidos

| Risco | Impacto | Mitigação |
|---|---|---|
| ~57–69 requisições por carregamento da tela | Lentidão perceptível | Concorrência limitada, cache do React Query, `loadTimeMs` visível para medir e decidir a fase 2 |
| Amostra de 200 mensagens lida como taxa do período | Decisão operacional errada | Rótulo explícito no card e `sampled: true` no contrato |
| Payload pesado da amostra (campo `message` completo) | Tráfego alto | Amostra limitada a 200; resolvido na fase 2 com `select` dedicado |
| Ausência de índice `(instanceId, messageTimestamp)` | Counts lentos em base grande | Índice entra na fase 2; a fase 1 mede a dor antes de pagar o custo |
| Divergência com o upstream do manager | Merges difíceis no futuro | Fork em vez de vendorização, mantendo rebase viável |
| Provider Evolution Go não coberto | Aba indisponível nesses ambientes | Aba oculta quando `getProvider() === "go"`, declarado como fora de escopo |
