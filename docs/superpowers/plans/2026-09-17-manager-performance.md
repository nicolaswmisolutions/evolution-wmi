# Manager: Aba de Performance e Headers de Webhook — Plano de Implementação

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Adicionar uma aba de Performance por instância no manager e corrigir a perda silenciosa de headers de webhook, sem tocar no backend da API.

**Architecture:** Todo o trabalho de produto acontece no submódulo `evolution-manager-v2` (fork da WMI). Os números vêm de chamadas `count` ao endpoint existente `POST /chat/findMessages`, atrás de uma fronteira `PerformanceSource` que será trocada por um endpoint agregado na fase 2 sem tocar na tela. A lógica pura (bucketização temporal, ranking de status, concorrência, conversão de headers) é isolada em módulos testáveis com vitest; o restante é verificado manualmente no container.

**Tech Stack:** React 18, TypeScript 5, Vite 7, TanStack Query 5, react-hook-form + zod, recharts, Tailwind 4, i18next, vitest (novo), Docker.

## Global Constraints

- **Build e teste exclusivamente via Docker.** Nunca rodar `npm run dev`, `vite` ou `npm run build` direto na máquina. Use `docker compose -f docker-compose.dev.yaml build frontend` e `docker compose -f docker-compose.dev.yaml up frontend`.
- Dois repositórios: `evolution-wmi` (raiz) e o submódulo `evolution-manager-v2`. **Commits são separados, cada um no seu repositório.** Após commitar no submódulo, commite o ponteiro atualizado em `evolution-wmi`.
- Branch de trabalho: `prototype` nos dois repositórios.
- Conventional Commits são obrigatórios (commitlint ativo em `evolution-wmi`).
- Todo texto visível ao usuário passa por i18next. As **quatro** línguas devem ser atualizadas juntas: `pt-BR.json`, `en-US.json`, `es-ES.json`, `fr-FR.json`.
- TypeScript em modo `strict` com `noUnusedLocals` e `noUnusedParameters` ligados — variáveis não usadas quebram o build.
- Alias de import: `@/` resolve para `src/` no submódulo.
- O provider Evolution Go está **fora de escopo**: a aba Performance é ocultada via o mecanismo `FEATURES`.
- Ao final de cada tarefa que altere a UI, valide no container antes de commitar.

---

## Estrutura de arquivos

**No submódulo `evolution-manager-v2`:**

| Arquivo | Responsabilidade |
|---|---|
| `Dockerfile` (modificar) | Build do container do manager — hoje quebrado |
| `vite.config.ts` (modificar) | Configuração do vitest |
| `package.json` (modificar) | Dependência do vitest e script `test` |
| `src/lib/webhook/headers.ts` (criar) | Conversão objeto ⇄ pares chave/valor |
| `src/lib/webhook/headers.test.ts` (criar) | Testes da conversão |
| `src/types/evolution.types.ts` (modificar) | Campo `headers` no tipo `Webhook` |
| `src/pages/instance/Webhook/index.tsx` (modificar) | Editor de headers |
| `src/lib/performance/types.ts` (criar) | Contrato `PerformanceOverview` e interface `PerformanceSource` |
| `src/lib/performance/buckets.ts` (criar) | Bucketização temporal (lógica pura) |
| `src/lib/performance/buckets.test.ts` (criar) | Testes da bucketização |
| `src/lib/performance/delivery.ts` (criar) | Ranking de status de entrega (lógica pura) |
| `src/lib/performance/delivery.test.ts` (criar) | Testes do ranking |
| `src/lib/performance/concurrency.ts` (criar) | `mapWithConcurrency` com resultados settled |
| `src/lib/performance/concurrency.test.ts` (criar) | Testes da concorrência |
| `src/lib/performance/findMessagesSource.ts` (criar) | Adapter fase 1 sobre `findMessages` |
| `src/lib/queries/performance/usePerformanceOverview.ts` (criar) | Hook React Query + wiring da fonte |
| `src/lib/provider/features.ts` (modificar) | Gate `performance` |
| `src/routes/index.tsx` (modificar) | Rota `/manager/instance/:instanceId/performance` |
| `src/components/sidebar.tsx` (modificar) | Item de menu |
| `src/pages/instance/Performance/index.tsx` (criar) | Tela: header, seletor de período, composição |
| `src/pages/instance/Performance/VolumeChart.tsx` (criar) | Gráfico de volume no tempo |
| `src/pages/instance/Performance/ConnectionCard.tsx` (criar) | Card de saúde da conexão |
| `src/pages/instance/Performance/DeliveryCard.tsx` (criar) | Card de entrega/leitura |
| `src/pages/instance/Performance/MessageTypesChart.tsx` (criar) | Distribuição por tipo |
| `src/translate/languages/*.json` (modificar, 4 arquivos) | Textos |

**No repositório `evolution-wmi`:**

| Arquivo | Responsabilidade |
|---|---|
| `Dockerfile` (modificar) | Buildar o submódulo e servir em `manager/dist` |

---

## Task 1: Consertar o build Docker do manager

O `Dockerfile` do submódulo copia `postcss.config.js` e `tailwind.config.js`, que **não existem** — o projeto migrou para Tailwind 4, que usa o plugin do Vite. O build do container falha hoje, então nada pode ser verificado até isso funcionar. Também subimos a imagem base para Node 22, porque o Vite 7 exige Node 20.19+ ou 22.12+ e `node:20-alpine` deixa isso no acaso da tag.

**Files:**
- Modify: `evolution-manager-v2/Dockerfile:1-30`

**Interfaces:**
- Consumes: nada
- Produces: imagem `evolution/manager:local` funcional, servindo o manager em `http://localhost:3000`

- [ ] **Step 1: Confirmar que o build falha hoje**

```bash
cd /d/WMI/evolution/evolution-wmi
docker compose -f docker-compose.dev.yaml build frontend
```

Esperado: FALHA com `"/postcss.config.js": not found`.

- [ ] **Step 2: Reescrever o estágio de build do Dockerfile**

Substitua o bloco desde `FROM node:20-alpine as build-deps` até a linha `RUN echo "Iniciando build..."` inclusive, por:

```dockerfile
FROM node:22-alpine AS build-deps
WORKDIR /usr/src/app

# Copy package files
COPY package*.json ./

# Install dependencies without running prepare scripts
RUN echo "Iniciando install..." && \
    npm ci --ignore-scripts && \
    echo "Install concluído."

# Copy source code
COPY src/ ./src/
COPY tsconfig.json tsconfig.app.json tsconfig.node.json ./
COPY vite.config.ts index.html components.json ./
COPY public/ ./public/

# Build the application
RUN echo "Iniciando build..." && \
    npm run build && \
    echo "Build concluído."
```

O estágio `FROM nginx:alpine` em diante fica inalterado.

- [ ] **Step 3: Rodar o build e verificar que passa**

```bash
docker compose -f docker-compose.dev.yaml build frontend
```

Esperado: SUCESSO, com `Build concluído.` no log.

- [ ] **Step 4: Subir e conferir que a tela de login carrega**

```bash
docker compose -f docker-compose.dev.yaml up -d frontend
```

Abra `http://localhost:3000/manager/login`. Esperado: tela de login renderizada, sem erro no console do navegador.

- [ ] **Step 5: Commit (no submódulo)**

```bash
cd /d/WMI/evolution/evolution-wmi/evolution-manager-v2
git add Dockerfile
git commit -m "fix(docker): repair manager image build

The build stage copied postcss.config.js and tailwind.config.js, which no
longer exist since the project moved to Tailwind 4 and its Vite plugin, so
the image failed to build. Also pins Node 22, which Vite 7 requires."
```

---

## Task 2: Infraestrutura de testes (vitest)

O repositório não tem testes. Instalamos o vitest e o deixamos rodando em container, para que as tarefas seguintes possam ser escritas com teste primeiro. O fuso é fixado para que testes de data sejam reprodutíveis em qualquer máquina.

**Files:**
- Modify: `evolution-manager-v2/package.json`
- Modify: `evolution-manager-v2/vite.config.ts`
- Create: `evolution-manager-v2/src/lib/performance/sanity.test.ts` (temporário, removido no Step 6)

**Interfaces:**
- Consumes: nada
- Produces: comando `npm test` funcional; `describe/it/expect` disponíveis globalmente

- [ ] **Step 1: Adicionar a dependência e o script**

Em `package.json`, adicione a `devDependencies` (mantendo a ordem alfabética):

```json
"vitest": "^2.1.9",
```

E substitua o script `test` existente:

```json
"test": "vitest run",
"test:watch": "vitest",
```

- [ ] **Step 2: Configurar o vitest**

Substitua todo o conteúdo de `vite.config.ts` por:

```ts
/// <reference types="vitest" />
import path from "path"
import react from "@vitejs/plugin-react"
import tailwindcss from "@tailwindcss/vite"
import { defineConfig } from "vite"

export default defineConfig({
  plugins: [react(), tailwindcss()],
  resolve: {
    alias: {
      "@": path.resolve(__dirname, "./src"),
    },
  },
  test: {
    globals: true,
    environment: "node",
    include: ["src/**/*.test.ts"],
    env: {
      // Fixa o fuso para que os testes de bucketização sejam determinísticos.
      TZ: "America/Sao_Paulo",
    },
  },
})
```

- [ ] **Step 3: Escrever um teste de sanidade que deve falhar**

Crie `src/lib/performance/sanity.test.ts`:

```ts
describe("infraestrutura de testes", () => {
  it("roda no fuso America/Sao_Paulo", () => {
    expect(new Date("2026-09-17T12:00:00Z").getHours()).toBe(9);
  });

  it("falha de propósito", () => {
    expect(true).toBe(false);
  });
});
```

- [ ] **Step 4: Rodar os testes em container e ver a falha esperada**

```bash
cd /d/WMI/evolution/evolution-wmi/evolution-manager-v2
docker run --rm -v "$(pwd)":/app -w /app node:22-alpine sh -c "npm ci --ignore-scripts && npm test"
```

Esperado: o primeiro teste PASSA (confirmando o fuso) e o segundo FALHA com `expected true to be false`.

- [ ] **Step 5: Remover o teste que falha de propósito**

Apague o bloco `it("falha de propósito", ...)` do arquivo, mantendo o teste de fuso.

- [ ] **Step 6: Rodar de novo e ver tudo passar**

```bash
docker run --rm -v "$(pwd)":/app -w /app node:22-alpine sh -c "npm ci --ignore-scripts && npm test"
```

Esperado: `1 passed`.

- [ ] **Step 7: Commit (no submódulo)**

```bash
git add package.json package-lock.json vite.config.ts src/lib/performance/sanity.test.ts
git commit -m "test: add vitest with a pinned timezone

Introduces vitest so the pure logic behind the performance screen can be
written test-first. TZ is pinned to America/Sao_Paulo so date bucketing
tests are reproducible across machines."
```

---

## Task 3: Headers personalizados de webhook

`Webhook.headers` é persistido pela API e aplicado no envio, mas a UI não conhece o campo: o payload do save não o inclui, então salvar pela tela pode apagar headers configurados via API. Esta é a correção de maior prioridade do plano.

**Files:**
- Create: `evolution-manager-v2/src/lib/webhook/headers.ts`
- Create: `evolution-manager-v2/src/lib/webhook/headers.test.ts`
- Modify: `evolution-manager-v2/src/types/evolution.types.ts:335-342`
- Modify: `evolution-manager-v2/src/pages/instance/Webhook/index.tsx`
- Modify: `evolution-manager-v2/src/translate/languages/pt-BR.json`, `en-US.json`, `es-ES.json`, `fr-FR.json`

**Interfaces:**
- Consumes: vitest (Task 2)
- Produces: `HeaderPair`, `objectToPairs(headers)`, `pairsToObject(pairs)` de `@/lib/webhook/headers`

- [ ] **Step 1: Escrever os testes que falham**

Crie `src/lib/webhook/headers.test.ts`:

```ts
import { objectToPairs, pairsToObject } from "./headers";

describe("objectToPairs", () => {
  it("devolve lista vazia para undefined", () => {
    expect(objectToPairs(undefined)).toEqual([]);
  });

  it("devolve lista vazia para null", () => {
    expect(objectToPairs(null)).toEqual([]);
  });

  it("converte cada entrada em um par", () => {
    expect(objectToPairs({ Authorization: "Bearer x", "X-Tenant": "wmi" })).toEqual([
      { key: "Authorization", value: "Bearer x" },
      { key: "X-Tenant", value: "wmi" },
    ]);
  });
});

describe("pairsToObject", () => {
  it("devolve objeto vazio para lista vazia", () => {
    expect(pairsToObject([])).toEqual({});
  });

  it("descarta pares sem nome", () => {
    expect(pairsToObject([{ key: "   ", value: "ignorado" }, { key: "X-Ok", value: "1" }])).toEqual({
      "X-Ok": "1",
    });
  });

  it("remove espaços ao redor do nome mas preserva o valor", () => {
    expect(pairsToObject([{ key: "  X-Tenant  ", value: "  wmi  " }])).toEqual({
      "X-Tenant": "  wmi  ",
    });
  });

  it("mantém o último valor quando o nome se repete", () => {
    expect(pairsToObject([{ key: "X-Dup", value: "a" }, { key: "X-Dup", value: "b" }])).toEqual({
      "X-Dup": "b",
    });
  });

  it("faz round-trip preservando o conteúdo", () => {
    const original = { Authorization: "Bearer x", "X-Tenant": "wmi" };
    expect(pairsToObject(objectToPairs(original))).toEqual(original);
  });
});
```

- [ ] **Step 2: Rodar e confirmar a falha**

```bash
cd /d/WMI/evolution/evolution-wmi/evolution-manager-v2
docker run --rm -v "$(pwd)":/app -w /app node:22-alpine sh -c "npm ci --ignore-scripts && npm test"
```

Esperado: FALHA com `Failed to resolve import "./headers"`.

- [ ] **Step 3: Implementar o módulo**

Crie `src/lib/webhook/headers.ts`:

```ts
export type HeaderPair = { key: string; value: string };

/** Converte o objeto de headers vindo da API na lista que o formulário edita. */
export function objectToPairs(headers?: Record<string, string> | null): HeaderPair[] {
  if (!headers) return [];
  return Object.entries(headers).map(([key, value]) => ({ key, value: String(value) }));
}

/**
 * Converte a lista do formulário no objeto que a API espera.
 * Pares sem nome são descartados; quando o nome se repete, o último vence.
 */
export function pairsToObject(pairs: HeaderPair[]): Record<string, string> {
  const result: Record<string, string> = {};
  for (const pair of pairs) {
    const name = pair.key.trim();
    if (!name) continue;
    result[name] = pair.value;
  }
  return result;
}
```

- [ ] **Step 4: Rodar e ver passar**

```bash
docker run --rm -v "$(pwd)":/app -w /app node:22-alpine sh -c "npm ci --ignore-scripts && npm test"
```

Esperado: todos os testes de `headers.test.ts` PASSAM.

- [ ] **Step 5: Adicionar `headers` ao tipo `Webhook`**

Em `src/types/evolution.types.ts`, substitua o tipo `Webhook`:

```ts
export type Webhook = {
  id?: string;
  enabled: boolean;
  url: string;
  events: string[];
  base64: boolean;
  byEvents: boolean;
  headers?: Record<string, string>;
};
```

`FetchWebhookResponse` em `src/lib/queries/webhook/types.ts` deriva de `Webhook` via `Omit`, então passa a expor `headers` automaticamente — não precisa ser alterado.

- [ ] **Step 6: Adicionar os textos nas quatro línguas**

Em `src/translate/languages/pt-BR.json`, dentro do objeto `webhook.form`, adicione:

```json
"headers": {
  "label": "Headers personalizados",
  "description": "Cabeçalhos HTTP enviados em cada requisição do webhook",
  "keyPlaceholder": "Nome do header",
  "valuePlaceholder": "Valor",
  "add": "Adicionar header",
  "remove": "Remover"
}
```

Em `en-US.json`:

```json
"headers": {
  "label": "Custom headers",
  "description": "HTTP headers sent with every webhook request",
  "keyPlaceholder": "Header name",
  "valuePlaceholder": "Value",
  "add": "Add header",
  "remove": "Remove"
}
```

Em `es-ES.json`:

```json
"headers": {
  "label": "Encabezados personalizados",
  "description": "Encabezados HTTP enviados en cada solicitud del webhook",
  "keyPlaceholder": "Nombre del encabezado",
  "valuePlaceholder": "Valor",
  "add": "Añadir encabezado",
  "remove": "Eliminar"
}
```

Em `fr-FR.json`:

```json
"headers": {
  "label": "En-têtes personnalisés",
  "description": "En-têtes HTTP envoyés à chaque requête du webhook",
  "keyPlaceholder": "Nom de l'en-tête",
  "valuePlaceholder": "Valeur",
  "add": "Ajouter un en-tête",
  "remove": "Supprimer"
}
```

- [ ] **Step 7: Ligar os headers no formulário**

Em `src/pages/instance/Webhook/index.tsx`:

7a. Adicione aos imports existentes:

```ts
import { Trash2 } from "lucide-react";
import { useFieldArray } from "react-hook-form";

import { objectToPairs, pairsToObject } from "@/lib/webhook/headers";
```

7b. Substitua o `FormSchema`:

```ts
const FormSchema = z.object({
  enabled: z.boolean(),
  url: z.string().url("Invalid URL format"),
  events: z.array(z.string()),
  base64: z.boolean(),
  byEvents: z.boolean(),
  headers: z.array(z.object({ key: z.string(), value: z.string() })),
});
```

7c. Em `defaultValues`, adicione `headers: []` após `byEvents: false,`.

7d. Logo após a declaração `const form = useForm<FormSchemaType>({...});`, adicione:

```ts
  const headerFields = useFieldArray({ control: form.control, name: "headers" });
```

7e. Substitua o corpo do `form.reset` dentro do `useEffect`:

```ts
      form.reset({
        enabled: webhook.enabled,
        url: webhook.url,
        events: webhook.events,
        base64: webhook.webhookBase64,
        byEvents: webhook.webhookByEvents,
        headers: objectToPairs(webhook.headers),
      });
```

7f. Substitua a montagem de `webhookData` no `onSubmit`:

```ts
      const webhookData: WebhookType = {
        enabled: data.enabled,
        url: data.url,
        events: data.events,
        base64: data.base64,
        byEvents: data.byEvents,
        headers: pairsToObject(data.headers),
      };
```

7g. Insira o editor logo **depois** do `FormSwitch` de `base64` e **antes** da `<div className="mb-4 flex justify-between">`:

```tsx
              <div className="flex flex-col gap-3">
                <div>
                  <FormLabel className="text-base">{t("webhook.form.headers.label")}</FormLabel>
                  <p className="text-sm text-muted-foreground">{t("webhook.form.headers.description")}</p>
                </div>

                {headerFields.fields.map((field, index) => (
                  <div key={field.id} className="flex items-center gap-2">
                    <Input
                      placeholder={t("webhook.form.headers.keyPlaceholder")}
                      {...form.register(`headers.${index}.key` as const)}
                    />
                    <Input
                      placeholder={t("webhook.form.headers.valuePlaceholder")}
                      {...form.register(`headers.${index}.value` as const)}
                    />
                    <Button
                      type="button"
                      variant="outline"
                      size="icon"
                      aria-label={t("webhook.form.headers.remove")}
                      onClick={() => headerFields.remove(index)}
                    >
                      <Trash2 className="h-4 w-4" />
                    </Button>
                  </div>
                ))}

                <div>
                  <Button type="button" variant="outline" onClick={() => headerFields.append({ key: "", value: "" })}>
                    {t("webhook.form.headers.add")}
                  </Button>
                </div>
              </div>
```

- [ ] **Step 8: Rebuildar e validar manualmente no container**

```bash
cd /d/WMI/evolution/evolution-wmi
docker compose -f docker-compose.dev.yaml build frontend
docker compose -f docker-compose.dev.yaml up -d frontend
```

Abra `http://localhost:3000/manager/login`, conecte à API e vá em uma instância → Eventos → Webhook. Verifique, nesta ordem:

1. Adicione um header `X-Teste: 123`, salve, recarregue a página. Esperado: o header reaparece preenchido.
2. Altere apenas a URL e salve. Recarregue. **Esperado: o header `X-Teste` continua lá** — esta é a regressão que a tarefa corrige.
3. Remova o header, salve, recarregue. Esperado: nenhum header listado.

- [ ] **Step 9: Commit (no submódulo)**

```bash
cd /d/WMI/evolution/evolution-wmi/evolution-manager-v2
git add src/lib/webhook src/types/evolution.types.ts src/pages/instance/Webhook/index.tsx src/translate/languages
git commit -m "fix(webhook): stop dropping custom headers on save

The webhook form never knew about the headers field, so every save sent a
payload without it and silently wiped headers configured through the API.
Adds a key/value editor that loads the existing headers and sends them back."
```

- [ ] **Step 10: Commit do ponteiro (no repositório raiz)**

```bash
cd /d/WMI/evolution/evolution-wmi
git add evolution-manager-v2
git commit -m "build(manager): bump submodule with webhook headers fix"
```

---

## Task 4: Bucketização temporal

Lógica pura que divide um período em janelas de tempo. É onde erros silenciosos se escondem: um bucket que termina no mesmo instante em que o próximo começa faz mensagens serem contadas duas vezes, porque o filtro da API é inclusivo nas duas pontas (`gte` e `lte`).

**Files:**
- Create: `evolution-manager-v2/src/lib/performance/types.ts`
- Create: `evolution-manager-v2/src/lib/performance/buckets.ts`
- Create: `evolution-manager-v2/src/lib/performance/buckets.test.ts`

**Interfaces:**
- Consumes: vitest (Task 2)
- Produces:
  - `type Period = "24h" | "7d" | "30d"` de `@/lib/performance/types`
  - `type Bucket = { start: Date; end: Date }` de `@/lib/performance/buckets`
  - `buildBuckets(period: Period, now: Date): Bucket[]`

- [ ] **Step 1: Criar o arquivo de tipos**

Crie `src/lib/performance/types.ts`:

```ts
export type Period = "24h" | "7d" | "30d";

export type DeliveryStatus = "PENDING" | "SERVER_ACK" | "DELIVERY_ACK" | "READ" | "ERROR";

export type SeriesPoint = {
  bucket: string;
  sent: number;
  received: number;
  partial?: boolean;
};

export type PerformanceOverview = {
  period: Period;
  generatedAt: string;
  series: SeriesPoint[];
  totals: { sent: number; received: number; total: number };
  messageTypes: Array<{ type: string; count: number }>;
  delivery: {
    counts: Record<DeliveryStatus, number>;
    sampled: boolean;
    sampleSize: number;
  };
  connection: {
    status: string;
    since: string | null;
    lastDisconnectAt: string | null;
    lastDisconnectReason: number | null;
    historyAvailable: boolean;
  };
  degraded: Array<{ metric: string; reason: string }>;
  loadTimeMs: number;
};

export type FetchOverviewParams = {
  instanceName: string;
  token: string;
  period: Period;
  connectionStatus: string;
  lastDisconnectAt: string | null;
  lastDisconnectReason: number | null;
  now?: Date;
};

export interface PerformanceSource {
  fetchOverview(params: FetchOverviewParams): Promise<PerformanceOverview>;
}
```

- [ ] **Step 2: Escrever os testes que falham**

Crie `src/lib/performance/buckets.test.ts`:

```ts
import { buildBuckets } from "./buckets";

const NOW = new Date("2026-09-17T13:45:30-03:00");

describe("buildBuckets", () => {
  it("cria 24 janelas para 24h", () => {
    expect(buildBuckets("24h", NOW)).toHaveLength(24);
  });

  it("cria 7 janelas para 7d", () => {
    expect(buildBuckets("7d", NOW)).toHaveLength(7);
  });

  it("cria 30 janelas para 30d", () => {
    expect(buildBuckets("30d", NOW)).toHaveLength(30);
  });

  it("alinha as janelas horárias no início da hora", () => {
    for (const bucket of buildBuckets("24h", NOW)) {
      expect(bucket.start.getMinutes()).toBe(0);
      expect(bucket.start.getSeconds()).toBe(0);
      expect(bucket.start.getMilliseconds()).toBe(0);
    }
  });

  it("alinha as janelas diárias na meia-noite local", () => {
    for (const bucket of buildBuckets("7d", NOW)) {
      expect(bucket.start.getHours()).toBe(0);
      expect(bucket.start.getMinutes()).toBe(0);
    }
  });

  it("não sobrepõe janelas adjacentes, porque o filtro da API é inclusivo nas duas pontas", () => {
    const buckets = buildBuckets("24h", NOW);
    for (let i = 0; i < buckets.length - 1; i++) {
      expect(buckets[i].end.getTime()).toBeLessThan(buckets[i + 1].start.getTime());
      expect(buckets[i + 1].start.getTime() - buckets[i].end.getTime()).toBe(1);
    }
  });

  it("não deixa buraco entre janelas diárias", () => {
    const buckets = buildBuckets("30d", NOW);
    for (let i = 0; i < buckets.length - 1; i++) {
      expect(buckets[i + 1].start.getTime() - buckets[i].end.getTime()).toBe(1);
    }
  });

  it("coloca o instante atual dentro da última janela", () => {
    for (const period of ["24h", "7d", "30d"] as const) {
      const last = buildBuckets(period, NOW).at(-1)!;
      expect(last.start.getTime()).toBeLessThanOrEqual(NOW.getTime());
      expect(last.end.getTime()).toBeGreaterThanOrEqual(NOW.getTime());
    }
  });

  it("devolve as janelas em ordem cronológica", () => {
    const buckets = buildBuckets("7d", NOW);
    for (let i = 0; i < buckets.length - 1; i++) {
      expect(buckets[i].start.getTime()).toBeLessThan(buckets[i + 1].start.getTime());
    }
  });
});
```

- [ ] **Step 3: Rodar e confirmar a falha**

```bash
cd /d/WMI/evolution/evolution-wmi/evolution-manager-v2
docker run --rm -v "$(pwd)":/app -w /app node:22-alpine sh -c "npm ci --ignore-scripts && npm test"
```

Esperado: FALHA com `Failed to resolve import "./buckets"`.

- [ ] **Step 4: Implementar a bucketização**

Crie `src/lib/performance/buckets.ts`:

```ts
import { Period } from "./types";

export type Bucket = { start: Date; end: Date };

/**
 * Divide o período em janelas contíguas e sem sobreposição, terminando na
 * janela que contém `now`.
 *
 * Cada janela termina 1ms antes do início da seguinte: o filtro
 * `messageTimestamp` da API é inclusivo em `gte` e `lte`, então janelas que
 * compartilhassem a fronteira contariam a mesma mensagem duas vezes.
 *
 * A aritmética usa setHours/setDate em vez de somar milissegundos para que
 * mudanças de horário de verão não desalinhem as janelas.
 */
export function buildBuckets(period: Period, now: Date): Bucket[] {
  const buckets: Bucket[] = [];

  if (period === "24h") {
    for (let i = 23; i >= 0; i--) {
      const start = new Date(now);
      start.setHours(start.getHours() - i, 0, 0, 0);

      const end = new Date(start);
      end.setHours(end.getHours() + 1);
      end.setMilliseconds(-1);

      buckets.push({ start, end });
    }
    return buckets;
  }

  const days = period === "7d" ? 7 : 30;

  for (let i = days - 1; i >= 0; i--) {
    const start = new Date(now);
    start.setDate(start.getDate() - i);
    start.setHours(0, 0, 0, 0);

    const end = new Date(start);
    end.setDate(end.getDate() + 1);
    end.setMilliseconds(-1);

    buckets.push({ start, end });
  }

  return buckets;
}
```

- [ ] **Step 5: Rodar e ver passar**

```bash
docker run --rm -v "$(pwd)":/app -w /app node:22-alpine sh -c "npm ci --ignore-scripts && npm test"
```

Esperado: todos os testes de `buckets.test.ts` PASSAM.

- [ ] **Step 6: Commit (no submódulo)**

```bash
git add src/lib/performance/types.ts src/lib/performance/buckets.ts src/lib/performance/buckets.test.ts
git commit -m "feat(performance): add time bucketing for the performance screen

Splits a period into contiguous, non-overlapping windows. Windows end 1ms
before the next one starts because the API timestamp filter is inclusive on
both ends, which would otherwise double count boundary messages."
```

---

## Task 5: Status de entrega e concorrência limitada

Duas funções puras que o adapter da Task 6 consome. O ranking de status resolve qual é o estado real de uma mensagem a partir da lista de atualizações; o limitador de concorrência impede que 57 requisições saiam de uma vez e preserva os resultados parciais quando algumas falham.

**Files:**
- Create: `evolution-manager-v2/src/lib/performance/delivery.ts`
- Create: `evolution-manager-v2/src/lib/performance/delivery.test.ts`
- Create: `evolution-manager-v2/src/lib/performance/concurrency.ts`
- Create: `evolution-manager-v2/src/lib/performance/concurrency.test.ts`

**Interfaces:**
- Consumes: `DeliveryStatus` de `@/lib/performance/types` (Task 4)
- Produces:
  - `resolveDeliveryStatus(updates?: Array<{ status: string }> | null): DeliveryStatus`
  - `type Settled<R> = { ok: true; value: R } | { ok: false; error: unknown }`
  - `mapWithConcurrency<T, R>(items: T[], limit: number, worker: (item: T, index: number) => Promise<R>): Promise<Settled<R>[]>`

- [ ] **Step 1: Escrever os testes de status que falham**

Crie `src/lib/performance/delivery.test.ts`:

```ts
import { resolveDeliveryStatus } from "./delivery";

describe("resolveDeliveryStatus", () => {
  it("considera pendente quando não há atualização", () => {
    expect(resolveDeliveryStatus([])).toBe("PENDING");
    expect(resolveDeliveryStatus(undefined)).toBe("PENDING");
    expect(resolveDeliveryStatus(null)).toBe("PENDING");
  });

  it("devolve o estado mais avançado da lista", () => {
    expect(resolveDeliveryStatus([{ status: "SERVER_ACK" }, { status: "DELIVERY_ACK" }])).toBe("DELIVERY_ACK");
  });

  it("independe da ordem das atualizações", () => {
    expect(resolveDeliveryStatus([{ status: "READ" }, { status: "SERVER_ACK" }])).toBe("READ");
  });

  it("prioriza ERROR sobre qualquer confirmação", () => {
    expect(resolveDeliveryStatus([{ status: "READ" }, { status: "ERROR" }])).toBe("ERROR");
  });

  it("ignora estados desconhecidos", () => {
    expect(resolveDeliveryStatus([{ status: "WHATEVER" }, { status: "SERVER_ACK" }])).toBe("SERVER_ACK");
  });

  it("considera pendente quando só há estados desconhecidos", () => {
    expect(resolveDeliveryStatus([{ status: "WHATEVER" }])).toBe("PENDING");
  });
});
```

- [ ] **Step 2: Escrever os testes de concorrência que falham**

Crie `src/lib/performance/concurrency.test.ts`:

```ts
import { mapWithConcurrency } from "./concurrency";

describe("mapWithConcurrency", () => {
  it("preserva a ordem dos resultados", async () => {
    const result = await mapWithConcurrency([1, 2, 3, 4], 2, async (n) => n * 10);
    expect(result).toEqual([
      { ok: true, value: 10 },
      { ok: true, value: 20 },
      { ok: true, value: 30 },
      { ok: true, value: 40 },
    ]);
  });

  it("nunca ultrapassa o limite de tarefas simultâneas", async () => {
    let running = 0;
    let peak = 0;

    await mapWithConcurrency(Array.from({ length: 20 }, (_, i) => i), 3, async (n) => {
      running++;
      peak = Math.max(peak, running);
      await new Promise((resolve) => setTimeout(resolve, 1));
      running--;
      return n;
    });

    expect(peak).toBeLessThanOrEqual(3);
  });

  it("captura a falha de um item sem derrubar os demais", async () => {
    const result = await mapWithConcurrency([1, 2, 3], 2, async (n) => {
      if (n === 2) throw new Error("boom");
      return n;
    });

    expect(result[0]).toEqual({ ok: true, value: 1 });
    expect(result[1].ok).toBe(false);
    expect(result[2]).toEqual({ ok: true, value: 3 });
  });

  it("devolve lista vazia para entrada vazia", async () => {
    expect(await mapWithConcurrency([], 4, async (n) => n)).toEqual([]);
  });

  it("passa o índice para o worker", async () => {
    const result = await mapWithConcurrency(["a", "b"], 1, async (item, index) => `${index}:${item}`);
    expect(result).toEqual([
      { ok: true, value: "0:a" },
      { ok: true, value: "1:b" },
    ]);
  });
});
```

- [ ] **Step 3: Rodar e confirmar as falhas**

```bash
cd /d/WMI/evolution/evolution-wmi/evolution-manager-v2
docker run --rm -v "$(pwd)":/app -w /app node:22-alpine sh -c "npm ci --ignore-scripts && npm test"
```

Esperado: FALHA ao resolver `./delivery` e `./concurrency`.

- [ ] **Step 4: Implementar o ranking de status**

Crie `src/lib/performance/delivery.ts`:

```ts
import { DeliveryStatus } from "./types";

const RANK: Record<string, number> = {
  PENDING: 0,
  SERVER_ACK: 1,
  DELIVERY_ACK: 2,
  READ: 3,
};

/**
 * Resolve o estado de entrega de uma mensagem a partir das atualizações.
 *
 * A API devolve as atualizações sem ordem garantida, então escolhemos o
 * estado mais avançado em vez de confiar na posição. ERROR vence qualquer
 * confirmação: numa tela de diagnóstico, uma falha registrada importa mais
 * do que um ack anterior.
 */
export function resolveDeliveryStatus(updates?: Array<{ status: string }> | null): DeliveryStatus {
  if (!updates || updates.length === 0) return "PENDING";

  let best: DeliveryStatus = "PENDING";

  for (const update of updates) {
    if (update.status === "ERROR") return "ERROR";
    const rank = RANK[update.status];
    if (rank === undefined) continue;
    if (rank > RANK[best]) best = update.status as DeliveryStatus;
  }

  return best;
}
```

- [ ] **Step 5: Implementar o limitador de concorrência**

Crie `src/lib/performance/concurrency.ts`:

```ts
export type Settled<R> = { ok: true; value: R } | { ok: false; error: unknown };

/**
 * Executa `worker` sobre os itens com no máximo `limit` tarefas simultâneas.
 *
 * Devolve resultados settled, na ordem da entrada: a tela precisa renderizar
 * a série com as janelas que vieram, marcando as que falharam, em vez de
 * descartar o carregamento inteiro por causa de uma requisição.
 */
export async function mapWithConcurrency<T, R>(
  items: T[],
  limit: number,
  worker: (item: T, index: number) => Promise<R>,
): Promise<Settled<R>[]> {
  const results: Settled<R>[] = new Array(items.length);
  let cursor = 0;

  const runners = Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (cursor < items.length) {
      const index = cursor++;
      try {
        results[index] = { ok: true, value: await worker(items[index], index) };
      } catch (error) {
        results[index] = { ok: false, error };
      }
    }
  });

  await Promise.all(runners);
  return results;
}
```

- [ ] **Step 6: Rodar e ver passar**

```bash
docker run --rm -v "$(pwd)":/app -w /app node:22-alpine sh -c "npm ci --ignore-scripts && npm test"
```

Esperado: todos os testes PASSAM.

- [ ] **Step 7: Commit (no submódulo)**

```bash
git add src/lib/performance/delivery.ts src/lib/performance/delivery.test.ts src/lib/performance/concurrency.ts src/lib/performance/concurrency.test.ts
git commit -m "feat(performance): add delivery status ranking and bounded concurrency

Delivery updates arrive unordered, so the status is resolved by rank rather
than position, with ERROR taking precedence. The concurrency helper returns
settled results so a single failed request degrades one bucket instead of
the whole screen."
```

---

## Task 6: Adapter da fase 1 sobre findMessages

Monta o `PerformanceOverview` a partir de chamadas `count` ao endpoint existente. É a única peça que a fase 2 substitui.

**Files:**
- Create: `evolution-manager-v2/src/lib/performance/findMessagesSource.ts`

**Interfaces:**
- Consumes: `buildBuckets` (Task 4), `resolveDeliveryStatus` e `mapWithConcurrency` (Task 5), tipos de `@/lib/performance/types` (Task 4), `api` de `@/lib/queries/api`
- Produces: `findMessagesSource: PerformanceSource`, `MESSAGE_TYPES`, `DELIVERY_SAMPLE_SIZE`

- [ ] **Step 1: Implementar o adapter**

Crie `src/lib/performance/findMessagesSource.ts`:

```ts
import { api } from "@/lib/queries/api";

import { buildBuckets } from "./buckets";
import { mapWithConcurrency } from "./concurrency";
import { resolveDeliveryStatus } from "./delivery";
import {
  DeliveryStatus,
  FetchOverviewParams,
  PerformanceOverview,
  PerformanceSource,
  SeriesPoint,
} from "./types";

/**
 * A API não expõe os tipos de mensagem distintos, então a lista é uma escolha
 * do cliente: tipos fora dela não aparecem no gráfico.
 */
export const MESSAGE_TYPES = [
  "conversation",
  "extendedTextMessage",
  "imageMessage",
  "audioMessage",
  "videoMessage",
  "documentMessage",
  "stickerMessage",
  "reactionMessage",
];

export const DELIVERY_SAMPLE_SIZE = 200;

const CONCURRENCY = 6;

type CountParams = {
  instanceName: string;
  token: string;
  from: Date;
  to: Date;
  fromMe?: boolean;
  messageType?: string;
};

const buildWhere = ({ from, to, fromMe, messageType }: Omit<CountParams, "instanceName" | "token">) => ({
  messageTimestamp: { gte: from.toISOString(), lte: to.toISOString() },
  // O backend testa `fromMe` por truthiness, então só faz sentido enviar `true`.
  ...(fromMe ? { key: { fromMe: true } } : {}),
  ...(messageType ? { messageType } : {}),
});

const countMessages = async ({ instanceName, token, ...filters }: CountParams): Promise<number> => {
  const response = await api.post(
    `/chat/findMessages/${instanceName}`,
    { where: buildWhere(filters), offset: 1, page: 1 },
    { headers: { apikey: token } },
  );
  return response.data?.messages?.total ?? 0;
};

const emptyDeliveryCounts = (): Record<DeliveryStatus, number> => ({
  PENDING: 0,
  SERVER_ACK: 0,
  DELIVERY_ACK: 0,
  READ: 0,
  ERROR: 0,
});

const fetchDeliverySample = async (instanceName: string, token: string, from: Date, to: Date) => {
  const response = await api.post(
    `/chat/findMessages/${instanceName}`,
    { where: buildWhere({ from, to, fromMe: true }), offset: DELIVERY_SAMPLE_SIZE, page: 1 },
    { headers: { apikey: token } },
  );

  const records: Array<{ MessageUpdate?: Array<{ status: string }> }> = response.data?.messages?.records ?? [];
  const counts = emptyDeliveryCounts();

  for (const record of records) {
    counts[resolveDeliveryStatus(record.MessageUpdate)]++;
  }

  return { counts, sampleSize: records.length };
};

export const findMessagesSource: PerformanceSource = {
  async fetchOverview(params: FetchOverviewParams): Promise<PerformanceOverview> {
    const { instanceName, token, period, now = new Date() } = params;
    const startedAt = Date.now();

    const buckets = buildBuckets(period, now);
    const windowStart = buckets[0].start;
    const windowEnd = buckets[buckets.length - 1].end;
    const degraded: PerformanceOverview["degraded"] = [];

    // Uma requisição de total e uma de enviadas por janela. "Recebidas" sai por
    // subtração, porque o backend ignora o filtro `fromMe: false`.
    const jobs = buckets.flatMap((bucket) => [
      { bucket, fromMe: false },
      { bucket, fromMe: true },
    ]);

    const counts = await mapWithConcurrency(jobs, CONCURRENCY, (job) =>
      countMessages({
        instanceName,
        token,
        from: job.bucket.start,
        to: job.bucket.end,
        fromMe: job.fromMe,
      }),
    );

    const series: SeriesPoint[] = buckets.map((bucket, index) => {
      const totalResult = counts[index * 2];
      const sentResult = counts[index * 2 + 1];

      if (!totalResult.ok || !sentResult.ok) {
        return { bucket: bucket.start.toISOString(), sent: 0, received: 0, partial: true };
      }

      const sent = sentResult.value;
      const received = Math.max(totalResult.value - sent, 0);
      return { bucket: bucket.start.toISOString(), sent, received };
    });

    if (series.some((point) => point.partial)) {
      degraded.push({ metric: "series", reason: "partial" });
    }

    const totals = series.reduce(
      (acc, point) => ({
        sent: acc.sent + point.sent,
        received: acc.received + point.received,
        total: acc.total + point.sent + point.received,
      }),
      { sent: 0, received: 0, total: 0 },
    );

    const typeResults = await mapWithConcurrency(MESSAGE_TYPES, CONCURRENCY, (messageType) =>
      countMessages({ instanceName, token, from: windowStart, to: windowEnd, messageType }),
    );

    const messageTypes = MESSAGE_TYPES.map((type, index) => {
      const result = typeResults[index];
      return { type, count: result.ok ? result.value : 0 };
    }).filter((entry) => entry.count > 0);

    if (typeResults.some((result) => !result.ok)) {
      degraded.push({ metric: "messageTypes", reason: "partial" });
    }

    let delivery = { counts: emptyDeliveryCounts(), sampled: true, sampleSize: 0 };

    try {
      const sample = await fetchDeliverySample(instanceName, token, windowStart, windowEnd);
      delivery = { counts: sample.counts, sampled: true, sampleSize: sample.sampleSize };
    } catch {
      degraded.push({ metric: "delivery", reason: "failed" });
    }

    return {
      period,
      generatedAt: new Date().toISOString(),
      series,
      totals,
      messageTypes,
      delivery,
      connection: {
        status: params.connectionStatus,
        since: null,
        lastDisconnectAt: params.lastDisconnectAt,
        lastDisconnectReason: params.lastDisconnectReason,
        // A tabela Instance guarda apenas a última desconexão, não um histórico.
        historyAvailable: false,
      },
      degraded,
      loadTimeMs: Date.now() - startedAt,
    };
  },
};
```

- [ ] **Step 2: Verificar que o TypeScript compila**

```bash
cd /d/WMI/evolution/evolution-wmi/evolution-manager-v2
docker run --rm -v "$(pwd)":/app -w /app node:22-alpine sh -c "npm ci --ignore-scripts && npx tsc --noEmit -p tsconfig.app.json"
```

Esperado: nenhum erro.

- [ ] **Step 3: Rodar os testes existentes para garantir que nada quebrou**

```bash
docker run --rm -v "$(pwd)":/app -w /app node:22-alpine sh -c "npm ci --ignore-scripts && npm test"
```

Esperado: todos PASSAM.

- [ ] **Step 4: Commit (no submódulo)**

```bash
git add src/lib/performance/findMessagesSource.ts
git commit -m "feat(performance): add phase-1 source built on findMessages counts

Assembles the overview from count-only calls to the existing endpoint, so no
backend change is needed yet. Received messages are derived by subtraction
because the API ignores a false fromMe filter."
```

---

## Task 7: Rota, menu e esqueleto navegável da tela

Entrega uma tela alcançável que já busca os dados e mostra os números crus, antes de qualquer gráfico. Isso permite medir o tempo de carregamento real — a evidência que decide a fase 2 — sem esperar a UI final.

**Files:**
- Create: `evolution-manager-v2/src/lib/queries/performance/usePerformanceOverview.ts`
- Create: `evolution-manager-v2/src/pages/instance/Performance/index.tsx`
- Modify: `evolution-manager-v2/src/types/evolution.types.ts:24-44`
- Modify: `evolution-manager-v2/src/lib/provider/features.ts:5-21`
- Modify: `evolution-manager-v2/src/routes/index.tsx`
- Modify: `evolution-manager-v2/src/components/sidebar.tsx`
- Modify: `evolution-manager-v2/src/translate/languages/*.json` (4 arquivos)

**Interfaces:**
- Consumes: `findMessagesSource` (Task 6), `PerformanceOverview` e `Period` (Task 4)
- Produces: `usePerformanceOverview({ instanceName, token, period, connectionStatus, lastDisconnectAt, lastDisconnectReason })` devolvendo `UseQueryResult<PerformanceOverview>`

- [ ] **Step 1: Criar o hook**

Crie `src/lib/queries/performance/usePerformanceOverview.ts`:

```ts
import { useQuery } from "@tanstack/react-query";

import { findMessagesSource } from "@/lib/performance/findMessagesSource";
import { PerformanceOverview, PerformanceSource, Period } from "@/lib/performance/types";

/**
 * Único ponto de troca entre a fase 1 e a fase 2: basta apontar para o
 * adapter do endpoint agregado quando ele existir.
 */
const source: PerformanceSource = findMessagesSource;

interface IParams {
  instanceName: string | null;
  token: string | null;
  period: Period;
  connectionStatus: string;
  lastDisconnectAt: string | null;
  lastDisconnectReason: number | null;
}

export const usePerformanceOverview = (params: IParams) => {
  const { instanceName, token, period } = params;

  return useQuery<PerformanceOverview>({
    queryKey: ["performance", "overview", instanceName, period],
    queryFn: () =>
      source.fetchOverview({
        instanceName: instanceName!,
        token: token!,
        period,
        connectionStatus: params.connectionStatus,
        lastDisconnectAt: params.lastDisconnectAt,
        lastDisconnectReason: params.lastDisconnectReason,
      }),
    enabled: !!instanceName && !!token,
    staleTime: 60_000,
    refetchOnWindowFocus: false,
  });
};
```

- [ ] **Step 2: Declarar os campos de desconexão no tipo `Instance`**

A API já devolve `disconnectionAt` e `disconnectionReasonCode` em `fetchInstances` (o `findMany` de `instanceInfo` não usa `select`, então todas as colunas vêm), mas o tipo do manager não os declara. Em `src/types/evolution.types.ts`, adicione ao tipo `Instance`, logo após `clientName: string;`:

```ts
  disconnectionAt?: string | null;
  disconnectionReasonCode?: number | null;
```

- [ ] **Step 3: Registrar o gate de feature**

Em `src/lib/provider/features.ts`, adicione dentro de `FEATURES`, logo após a linha `dashboard: { api: true, go: true },`:

```ts
  performance: { api: true, go: false },
```

- [ ] **Step 4: Adicionar os textos nas quatro línguas**

Em `pt-BR.json`, adicione `"performance": "Performance"` dentro do objeto `sidebar` e, no nível raiz, o bloco:

```json
"performance": {
  "title": "Performance",
  "subtitle": "Diagnóstico da instância",
  "period": { "24h": "24 horas", "7d": "7 dias", "30d": "30 dias" },
  "totals": { "sent": "Enviadas", "received": "Recebidas", "total": "Total" },
  "volume": { "title": "Volume de mensagens" },
  "connection": {
    "title": "Conexão",
    "status": "Estado",
    "lastDisconnect": "Última desconexão",
    "reason": "Motivo",
    "never": "Nenhuma registrada",
    "historyUnavailable": "Histórico de quedas indisponível nesta fase"
  },
  "delivery": {
    "title": "Entrega e leitura",
    "sampleNotice": "Amostra das últimas {{count}} mensagens enviadas",
    "PENDING": "Pendente",
    "SERVER_ACK": "No servidor",
    "DELIVERY_ACK": "Entregue",
    "READ": "Lida",
    "ERROR": "Falha"
  },
  "types": { "title": "Tipos de mensagem" },
  "degraded": {
    "series": "Parte das janelas não pôde ser carregada",
    "messageTypes": "Parte dos tipos não pôde ser carregada",
    "delivery": "Amostra de entrega indisponível"
  },
  "loadTime": "Carregado em {{ms}} ms",
  "error": "Não foi possível carregar os dados",
  "retry": "Tentar novamente"
}
```

Em `en-US.json`, adicione `"performance": "Performance"` em `sidebar` e, no nível raiz:

```json
"performance": {
  "title": "Performance",
  "subtitle": "Instance diagnostics",
  "period": { "24h": "24 hours", "7d": "7 days", "30d": "30 days" },
  "totals": { "sent": "Sent", "received": "Received", "total": "Total" },
  "volume": { "title": "Message volume" },
  "connection": {
    "title": "Connection",
    "status": "State",
    "lastDisconnect": "Last disconnection",
    "reason": "Reason",
    "never": "None recorded",
    "historyUnavailable": "Disconnection history unavailable in this phase"
  },
  "delivery": {
    "title": "Delivery and read",
    "sampleNotice": "Sample of the last {{count}} sent messages",
    "PENDING": "Pending",
    "SERVER_ACK": "On server",
    "DELIVERY_ACK": "Delivered",
    "READ": "Read",
    "ERROR": "Failed"
  },
  "types": { "title": "Message types" },
  "degraded": {
    "series": "Some time windows could not be loaded",
    "messageTypes": "Some message types could not be loaded",
    "delivery": "Delivery sample unavailable"
  },
  "loadTime": "Loaded in {{ms}} ms",
  "error": "Could not load the data",
  "retry": "Try again"
}
```

Em `es-ES.json`, adicione `"performance": "Rendimiento"` em `sidebar` e, no nível raiz:

```json
"performance": {
  "title": "Rendimiento",
  "subtitle": "Diagnóstico de la instancia",
  "period": { "24h": "24 horas", "7d": "7 días", "30d": "30 días" },
  "totals": { "sent": "Enviados", "received": "Recibidos", "total": "Total" },
  "volume": { "title": "Volumen de mensajes" },
  "connection": {
    "title": "Conexión",
    "status": "Estado",
    "lastDisconnect": "Última desconexión",
    "reason": "Motivo",
    "never": "Ninguna registrada",
    "historyUnavailable": "Historial de caídas no disponible en esta fase"
  },
  "delivery": {
    "title": "Entrega y lectura",
    "sampleNotice": "Muestra de los últimos {{count}} mensajes enviados",
    "PENDING": "Pendiente",
    "SERVER_ACK": "En el servidor",
    "DELIVERY_ACK": "Entregado",
    "READ": "Leído",
    "ERROR": "Fallo"
  },
  "types": { "title": "Tipos de mensaje" },
  "degraded": {
    "series": "Algunas ventanas no se pudieron cargar",
    "messageTypes": "Algunos tipos no se pudieron cargar",
    "delivery": "Muestra de entrega no disponible"
  },
  "loadTime": "Cargado en {{ms}} ms",
  "error": "No se pudieron cargar los datos",
  "retry": "Intentar de nuevo"
}
```

Em `fr-FR.json`, adicione `"performance": "Performance"` em `sidebar` e, no nível raiz:

```json
"performance": {
  "title": "Performance",
  "subtitle": "Diagnostic de l'instance",
  "period": { "24h": "24 heures", "7d": "7 jours", "30d": "30 jours" },
  "totals": { "sent": "Envoyés", "received": "Reçus", "total": "Total" },
  "volume": { "title": "Volume de messages" },
  "connection": {
    "title": "Connexion",
    "status": "État",
    "lastDisconnect": "Dernière déconnexion",
    "reason": "Motif",
    "never": "Aucune enregistrée",
    "historyUnavailable": "Historique des coupures indisponible à ce stade"
  },
  "delivery": {
    "title": "Livraison et lecture",
    "sampleNotice": "Échantillon des {{count}} derniers messages envoyés",
    "PENDING": "En attente",
    "SERVER_ACK": "Sur le serveur",
    "DELIVERY_ACK": "Livré",
    "READ": "Lu",
    "ERROR": "Échec"
  },
  "types": { "title": "Types de message" },
  "degraded": {
    "series": "Certaines fenêtres n'ont pas pu être chargées",
    "messageTypes": "Certains types n'ont pas pu être chargés",
    "delivery": "Échantillon de livraison indisponible"
  },
  "loadTime": "Chargé en {{ms}} ms",
  "error": "Impossible de charger les données",
  "retry": "Réessayer"
}
```

- [ ] **Step 5: Criar a tela com os números crus**

Crie `src/pages/instance/Performance/index.tsx`:

```tsx
import { Button } from "@evoapi/design-system/button";
import { Card, CardContent, CardHeader, CardTitle } from "@evoapi/design-system/card";
import { useState } from "react";
import { useTranslation } from "react-i18next";

import { BaseHeader } from "@/components/base-header";
import { LoadingSpinner } from "@/components/ui/loading-spinner";

import { useInstance } from "@/contexts/InstanceContext";

import { Period } from "@/lib/performance/types";
import { usePerformanceOverview } from "@/lib/queries/performance/usePerformanceOverview";

const PERIODS: Period[] = ["24h", "7d", "30d"];

function Performance() {
  const { t } = useTranslation();
  const { instance } = useInstance();
  const [period, setPeriod] = useState<Period>("24h");

  const { data, isLoading, isError, refetch } = usePerformanceOverview({
    instanceName: instance?.name ?? null,
    token: instance?.token ?? null,
    period,
    connectionStatus: instance?.connectionStatus ?? "unknown",
    lastDisconnectAt: instance?.disconnectionAt ?? null,
    lastDisconnectReason: instance?.disconnectionReasonCode ?? null,
  });

  if (!instance) return <LoadingSpinner />;

  return (
    <div className="flex flex-col gap-6">
      <BaseHeader title={t("performance.title")} subtitle={t("performance.subtitle")} />

      <div className="flex gap-2">
        {PERIODS.map((option) => (
          <Button
            key={option}
            variant={option === period ? "default" : "outline"}
            onClick={() => setPeriod(option)}
          >
            {t(`performance.period.${option}`)}
          </Button>
        ))}
      </div>

      {isLoading && <LoadingSpinner />}

      {isError && (
        <Card className="border-sidebar-border bg-sidebar">
          <CardContent className="flex items-center justify-between gap-4 pt-6">
            <span>{t("performance.error")}</span>
            <Button onClick={() => refetch()}>{t("performance.retry")}</Button>
          </CardContent>
        </Card>
      )}

      {data && (
        <>
          <section className="grid grid-cols-1 gap-4 sm:grid-cols-3">
            {(["sent", "received", "total"] as const).map((key) => (
              <Card key={key} className="border-sidebar-border bg-sidebar">
                <CardHeader>
                  <CardTitle className="text-sm font-medium text-muted-foreground">
                    {t(`performance.totals.${key}`)}
                  </CardTitle>
                </CardHeader>
                <CardContent className="text-3xl font-bold">{data.totals[key]}</CardContent>
              </Card>
            ))}
          </section>

          <pre className="overflow-x-auto rounded-md bg-muted p-4 text-xs">
            {JSON.stringify({ series: data.series, messageTypes: data.messageTypes, delivery: data.delivery }, null, 2)}
          </pre>

          <p className="text-right text-xs text-muted-foreground">
            {t("performance.loadTime", { ms: data.loadTimeMs })}
          </p>
        </>
      )}
    </div>
  );
}

export { Performance };
```

O `<pre>` com JSON é andaime e é removido na Task 8.

- [ ] **Step 6: Registrar a rota**

Em `src/routes/index.tsx`, adicione o import junto aos demais de páginas de instância:

```ts
import { Performance } from "@/pages/instance/Performance";
```

E o objeto de rota logo após o bloco de `dashboard`:

```tsx
  {
    path: "/manager/instance/:instanceId/performance",
    element: (
      <ProtectedRoute feature="performance">
        <InstanceLayout>
          <Performance />
        </InstanceLayout>
      </ProtectedRoute>
    ),
  },
```

- [ ] **Step 7: Adicionar o item no menu lateral**

Em `src/components/sidebar.tsx`, adicione `Activity` à lista de ícones importados de `lucide-react` (mantendo a ordem alfabética, antes de `ChevronDown`) e insira o item em `menus`, logo após a entrada de `dashboard`:

```ts
      { id: "performance", title: t("sidebar.performance"), icon: Activity, path: "performance" },
```

- [ ] **Step 8: Rebuildar e validar no container**

```bash
cd /d/WMI/evolution/evolution-wmi
docker compose -f docker-compose.dev.yaml build frontend
docker compose -f docker-compose.dev.yaml up -d frontend
```

Em `http://localhost:3000/manager`, entre numa instância. Verifique:

1. O item "Performance" aparece no menu lateral.
2. A tela carrega, os três totais aparecem preenchidos e o JSON do andaime mostra 24 janelas.
3. O rodapé mostra o tempo de carregamento. **Anote esse número** — ele é a evidência sobre a necessidade da fase 2.
4. Troque para 7d e 30d; os números mudam e o JSON passa a ter 7 e 30 janelas.

- [ ] **Step 9: Commit (no submódulo)**

```bash
cd /d/WMI/evolution/evolution-wmi/evolution-manager-v2
git add src/lib/queries/performance src/pages/instance/Performance src/lib/provider/features.ts src/routes/index.tsx src/components/sidebar.tsx src/types/evolution.types.ts src/translate/languages
git commit -m "feat(performance): add reachable performance screen with raw totals

Wires the route, sidebar entry and feature gate, and renders the totals plus
a scaffold JSON dump. The footer reports the measured load time, which is the
evidence for deciding whether the aggregated backend endpoint is needed."
```

- [ ] **Step 10: Commit do ponteiro (no repositório raiz)**

```bash
cd /d/WMI/evolution/evolution-wmi
git add evolution-manager-v2
git commit -m "build(manager): bump submodule with performance screen skeleton"
```

---

## Task 8: Gráficos e cards da tela de Performance

Substitui o andaime pelos componentes finais.

**Files:**
- Create: `evolution-manager-v2/src/pages/instance/Performance/VolumeChart.tsx`
- Create: `evolution-manager-v2/src/pages/instance/Performance/ConnectionCard.tsx`
- Create: `evolution-manager-v2/src/pages/instance/Performance/DeliveryCard.tsx`
- Create: `evolution-manager-v2/src/pages/instance/Performance/MessageTypesChart.tsx`
- Modify: `evolution-manager-v2/src/pages/instance/Performance/index.tsx`

**Interfaces:**
- Consumes: `PerformanceOverview` e `DeliveryStatus` de `@/lib/performance/types` (Task 4); `InstanceStatus` de `@/components/instance-status`; `recharts`
- Produces: componentes `VolumeChart`, `ConnectionCard`, `DeliveryCard`, `MessageTypesChart`, todos recebendo `overview: PerformanceOverview`

- [ ] **Step 1: Criar o gráfico de volume**

Crie `src/pages/instance/Performance/VolumeChart.tsx`:

```tsx
import { Card, CardContent, CardHeader, CardTitle } from "@evoapi/design-system/card";
import { useTranslation } from "react-i18next";
import { Area, AreaChart, CartesianGrid, Legend, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts";

import { PerformanceOverview } from "@/lib/performance/types";

function VolumeChart({ overview }: { overview: PerformanceOverview }) {
  const { t, i18n } = useTranslation();

  const labelFor = (iso: string) => {
    const date = new Date(iso);
    return overview.period === "24h"
      ? date.toLocaleTimeString(i18n.language, { hour: "2-digit" })
      : date.toLocaleDateString(i18n.language, { day: "2-digit", month: "2-digit" });
  };

  const data = overview.series.map((point) => ({
    label: labelFor(point.bucket),
    sent: point.sent,
    received: point.received,
  }));

  return (
    <Card className="border-sidebar-border bg-sidebar">
      <CardHeader>
        <CardTitle className="text-sm font-medium text-muted-foreground">{t("performance.volume.title")}</CardTitle>
      </CardHeader>
      <CardContent className="h-72">
        <ResponsiveContainer width="100%" height="100%">
          <AreaChart data={data}>
            <CartesianGrid strokeDasharray="3 3" className="stroke-muted" />
            <XAxis dataKey="label" fontSize={12} />
            <YAxis allowDecimals={false} fontSize={12} />
            <Tooltip />
            <Legend />
            <Area
              type="monotone"
              dataKey="sent"
              name={t("performance.totals.sent")}
              stackId="1"
              stroke="#189d68"
              fill="#189d68"
              fillOpacity={0.35}
            />
            <Area
              type="monotone"
              dataKey="received"
              name={t("performance.totals.received")}
              stackId="1"
              stroke="#2563eb"
              fill="#2563eb"
              fillOpacity={0.35}
            />
          </AreaChart>
        </ResponsiveContainer>
      </CardContent>
    </Card>
  );
}

export { VolumeChart };
```

- [ ] **Step 2: Criar o card de conexão**

Crie `src/pages/instance/Performance/ConnectionCard.tsx`:

```tsx
import { Card, CardContent, CardHeader, CardTitle } from "@evoapi/design-system/card";
import { useTranslation } from "react-i18next";

import { InstanceStatus } from "@/components/instance-status";

import { PerformanceOverview } from "@/lib/performance/types";

function ConnectionCard({ overview }: { overview: PerformanceOverview }) {
  const { t, i18n } = useTranslation();
  const { connection } = overview;

  return (
    <Card className="border-sidebar-border bg-sidebar">
      <CardHeader>
        <CardTitle className="text-sm font-medium text-muted-foreground">
          {t("performance.connection.title")}
        </CardTitle>
      </CardHeader>
      <CardContent className="space-y-3 text-sm">
        <div className="flex items-center justify-between gap-3">
          <span className="text-muted-foreground">{t("performance.connection.status")}</span>
          <InstanceStatus status={connection.status} />
        </div>
        <div className="flex items-center justify-between gap-3">
          <span className="text-muted-foreground">{t("performance.connection.lastDisconnect")}</span>
          <span>
            {connection.lastDisconnectAt
              ? new Date(connection.lastDisconnectAt).toLocaleString(i18n.language)
              : t("performance.connection.never")}
          </span>
        </div>
        {connection.lastDisconnectReason !== null && (
          <div className="flex items-center justify-between gap-3">
            <span className="text-muted-foreground">{t("performance.connection.reason")}</span>
            <span className="font-mono">{connection.lastDisconnectReason}</span>
          </div>
        )}
        {!connection.historyAvailable && (
          <p className="pt-2 text-xs text-muted-foreground">{t("performance.connection.historyUnavailable")}</p>
        )}
      </CardContent>
    </Card>
  );
}

export { ConnectionCard };
```

- [ ] **Step 3: Criar o card de entrega**

Crie `src/pages/instance/Performance/DeliveryCard.tsx`:

```tsx
import { Card, CardContent, CardHeader, CardTitle } from "@evoapi/design-system/card";
import { useTranslation } from "react-i18next";

import { DeliveryStatus, PerformanceOverview } from "@/lib/performance/types";

const ORDER: DeliveryStatus[] = ["READ", "DELIVERY_ACK", "SERVER_ACK", "PENDING", "ERROR"];

function DeliveryCard({ overview }: { overview: PerformanceOverview }) {
  const { t } = useTranslation();
  const { delivery } = overview;

  return (
    <Card className="border-sidebar-border bg-sidebar">
      <CardHeader>
        <CardTitle className="text-sm font-medium text-muted-foreground">
          {t("performance.delivery.title")}
        </CardTitle>
      </CardHeader>
      <CardContent className="space-y-2 text-sm">
        {ORDER.map((status) => (
          <div key={status} className="flex items-center justify-between gap-3">
            <span className="text-muted-foreground">{t(`performance.delivery.${status}`)}</span>
            <span className="font-medium">{delivery.counts[status]}</span>
          </div>
        ))}
        {delivery.sampled && (
          <p className="pt-2 text-xs text-muted-foreground">
            {t("performance.delivery.sampleNotice", { count: delivery.sampleSize })}
          </p>
        )}
      </CardContent>
    </Card>
  );
}

export { DeliveryCard };
```

- [ ] **Step 4: Criar o gráfico de tipos**

Crie `src/pages/instance/Performance/MessageTypesChart.tsx`:

```tsx
import { Card, CardContent, CardHeader, CardTitle } from "@evoapi/design-system/card";
import { useTranslation } from "react-i18next";
import { Bar, BarChart, CartesianGrid, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts";

import { PerformanceOverview } from "@/lib/performance/types";

function MessageTypesChart({ overview }: { overview: PerformanceOverview }) {
  const { t } = useTranslation();

  return (
    <Card className="border-sidebar-border bg-sidebar">
      <CardHeader>
        <CardTitle className="text-sm font-medium text-muted-foreground">{t("performance.types.title")}</CardTitle>
      </CardHeader>
      <CardContent className="h-72">
        <ResponsiveContainer width="100%" height="100%">
          <BarChart data={overview.messageTypes}>
            <CartesianGrid strokeDasharray="3 3" className="stroke-muted" />
            <XAxis dataKey="type" fontSize={11} interval={0} angle={-30} textAnchor="end" height={80} />
            <YAxis allowDecimals={false} fontSize={12} />
            <Tooltip />
            <Bar dataKey="count" fill="#189d68" radius={[4, 4, 0, 0]} />
          </BarChart>
        </ResponsiveContainer>
      </CardContent>
    </Card>
  );
}

export { MessageTypesChart };
```

- [ ] **Step 5: Compor a tela e remover o andaime**

Em `src/pages/instance/Performance/index.tsx`, adicione aos imports:

```ts
import { ConnectionCard } from "./ConnectionCard";
import { DeliveryCard } from "./DeliveryCard";
import { MessageTypesChart } from "./MessageTypesChart";
import { VolumeChart } from "./VolumeChart";
```

E substitua o bloco `<pre>...</pre>` por:

```tsx
          {data.degraded.length > 0 && (
            <div className="rounded-md border border-amber-500/40 bg-amber-500/10 p-3 text-sm">
              <ul className="list-inside list-disc">
                {data.degraded.map((item) => (
                  <li key={item.metric}>{t(`performance.degraded.${item.metric}`)}</li>
                ))}
              </ul>
            </div>
          )}

          <VolumeChart overview={data} />

          <section className="grid grid-cols-1 gap-4 lg:grid-cols-2">
            <ConnectionCard overview={data} />
            <DeliveryCard overview={data} />
          </section>

          <MessageTypesChart overview={data} />
```

- [ ] **Step 6: Rebuildar e validar no container**

```bash
cd /d/WMI/evolution/evolution-wmi
docker compose -f docker-compose.dev.yaml build frontend
docker compose -f docker-compose.dev.yaml up -d frontend
```

Em `http://localhost:3000/manager`, entre numa instância e abra Performance. Verifique:

1. O gráfico de volume aparece com as janelas do período e a legenda enviadas/recebidas.
2. O card de conexão mostra o estado e o aviso de histórico indisponível.
3. O card de entrega mostra os cinco estados e o rótulo de amostra.
4. O gráfico de tipos aparece; se a instância não tiver mensagens, fica vazio sem quebrar.
5. Alterne entre claro e escuro e confirme que os gráficos permanecem legíveis.
6. Reduza a janela a largura de celular e confirme que não há rolagem horizontal da página.

- [ ] **Step 7: Commit (no submódulo)**

```bash
cd /d/WMI/evolution/evolution-wmi/evolution-manager-v2
git add src/pages/instance/Performance
git commit -m "feat(performance): render volume, connection, delivery and type charts

Replaces the scaffold JSON with the final components and surfaces degraded
metrics explicitly, so an unavailable number is never shown as a zero."
```

- [ ] **Step 8: Commit do ponteiro (no repositório raiz)**

```bash
cd /d/WMI/evolution/evolution-wmi
git add evolution-manager-v2
git commit -m "build(manager): bump submodule with performance charts"
```

---

## Task 9: Buildar o submódulo no Dockerfile da API

A API serve `manager/dist` em `/manager`, mas o `Dockerfile` copia o `dist` pré-compilado commitado — o submódulo nunca é buildado, então mudanças na UI não chegam à rota `/manager` em produção.

**Files:**
- Modify: `evolution-wmi/Dockerfile:1-30` e a seção de cópia da imagem final

**Interfaces:**
- Consumes: submódulo `evolution-manager-v2` presente no contexto de build
- Produces: imagem da API servindo o manager recém-buildado em `/manager`

- [ ] **Step 1: Adicionar o estágio de build do manager**

No topo do `Dockerfile`, **antes** de `FROM node:24-alpine AS builder`, insira:

```dockerfile
FROM node:22-alpine AS manager-builder

WORKDIR /manager

COPY evolution-manager-v2/package*.json ./
RUN npm ci --ignore-scripts

COPY evolution-manager-v2/ ./
RUN npm run build
```

- [ ] **Step 2: Sobrescrever o dist no estágio builder**

No estágio `builder`, logo **depois** da linha `COPY ./manager ./manager`, adicione:

```dockerfile
COPY --from=manager-builder /manager/dist ./manager/dist
```

A ordem importa: o `dist` commitado é copiado primeiro e imediatamente substituído pelo recém-buildado. O artefato versionado segue como rede de segurança até este build ser validado em deploy real, conforme o spec.

- [ ] **Step 3: Buildar a imagem da API**

```bash
cd /d/WMI/evolution/evolution-wmi
docker compose -f docker-compose.dev.yaml build api
```

Esperado: SUCESSO. Se falhar por ausência do submódulo, rode `git submodule update --init --recursive` e repita.

- [ ] **Step 4: Subir e verificar que o manager buildado é servido**

```bash
docker compose -f docker-compose.dev.yaml up -d api
```

Abra `http://localhost:8080/manager`. Verifique que a aba Performance aparece no menu — é a prova de que o `dist` servido veio do build e não do artefato antigo commitado.

- [ ] **Step 5: Commit (no repositório raiz)**

```bash
git add Dockerfile
git commit -m "build(docker): build the manager submodule instead of shipping a stale dist

The image copied the committed manager/dist, so UI changes never reached the
/manager route. Adds a build stage for the submodule and overwrites the
committed artifact, which stays versioned as a fallback until this is
verified in a real deploy."
```

---

## Verificação final

- [ ] Todos os testes passam: `docker run --rm -v "$(pwd)":/app -w /app node:22-alpine sh -c "npm ci --ignore-scripts && npm test"` no submódulo.
- [ ] TypeScript compila sem erro: `npx tsc --noEmit -p tsconfig.app.json` no submódulo, via container.
- [ ] `docker compose -f docker-compose.dev.yaml build` conclui para `api` e `frontend`.
- [ ] Headers de webhook sobrevivem a um save que altera apenas a URL.
- [ ] A aba Performance carrega nos três períodos e o tempo medido foi anotado.
- [ ] Nenhum texto fixo em português, inglês, espanhol ou francês foi deixado fora do i18n.
- [ ] O ponteiro do submódulo está commitado no `evolution-wmi`.
