# Collab MCP

MCP server que permite múltiplos agentes de IA (Claude Code, Codex, Cursor) se comunicarem entre si através de salas de chat compartilhadas.

Resolve o problema de ter que fazer copy & paste entre instâncias de agentes que trabalham no mesmo feature — o "meio de campo humano" deixa de ser necessário.

## Como funciona

O Collab MCP é um servidor MCP (Model Context Protocol) que expõe tools de chat. Cada agente conecta nele via stdio e pode enviar/ler mensagens em salas compartilhadas. As mensagens ficam persistidas em SQLite local.

```
Terminal 1: Claude Code (backend)      ─┐
Terminal 2: Codex / Symphony (audit)    ├── collab MCP ── SQLite (~/.config/collab/collab.db)
Terminal 3: Cursor (website)           ─┘
```

## Instalação

```bash
git clone <repo-url> ~/AI/collab-mcp
cd ~/AI/collab-mcp
npm install
npm run build
```

O banco SQLite é criado automaticamente em `~/.config/collab/collab.db` na primeira execução.

Pra ter o comando `collab` disponível no terminal:

```bash
npm link
```

## CLI — Você participa direto do terminal

Você (o humano) usa o comando `collab` pra enviar e ler mensagens sem precisar de nenhum agente como intermediário.

```bash
# Enviar mensagem
collab send aba-80 andre "@backend Adiciona paginação no endpoint de notes"
collab send aba-80 andre "@all Mudança de prioridade: foquem no login primeiro"

# Ler mensagens
collab read aba-80                  # todas
collab read aba-80 --since 5       # apenas após a msg #5

# Listar salas e participantes
collab rooms
collab who aba-80

# Checar mensagens pendentes pra um agente (usado em hooks)
collab check aba-80 backend 10     # exit 0 = nada novo, exit 2 = tem msgs
```

## Notificações — Como o agente fica sabendo

### 1. Hook PostToolUse (recomendado — notificação automática)

O hook `PostToolUse` roda após **cada tool call** do agente. Ele chama `collab check` que verifica se há mensagens novas com `@nome` ou `@all`. Se houver, retorna exit code 2 (BLOCK) + conteúdo das mensagens, que é injetado no contexto do agente.

**Resultado:** O agente recebe mensagens automaticamente enquanto trabalha, sem polling manual.

Adicione no `.claude/settings.local.json` de cada projeto:

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "[ ! -f .collab-room ] || collab check \"$(cat .collab-room)\" \"$(cat .collab-name)\" \"$(cat .collab-last-id 2>/dev/null || echo 0)\"",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

- **PostToolUse** — notifica durante o trabalho (a cada Read, Edit, Bash, etc.)

> **Nota:** Não use hook `Stop` — causa loop infinito (agent tenta parar → hook bloqueia → agent tenta parar → ...).

**Como funciona internamente:**

1. Agente faz qualquer tool call (ex: `Edit` um arquivo)
2. Hook roda `collab check <room> <name> <last_id>` (~50ms)
3. Se `.collab-room` não existe → hook passa silencioso (exit 0)
4. Se não tem mensagens novas → hook passa silencioso (exit 0)
5. Se tem mensagens com `@nome` ou `@all` → exit 2 (BLOCK) + conteúdo
6. Claude Code injeta o output no contexto do agente
7. Agente vê as mensagens e reage

**Arquivos de estado** que o agente mantém no workspace:

| Arquivo | Conteúdo | Exemplo |
|---------|----------|---------|
| `.collab-room` | ID do room ativo | `aba-80` |
| `.collab-name` | Nome do participante | `backend` |
| `.collab-last-id` | ID da última mensagem lida | `42` |

Instrua no CLAUDE.md de cada repo (veja seção [Configuração nos repos](#configuração-nos-repos-claudemd)):

```markdown
Ao entrar em um room, crie os arquivos de estado:
- `echo "<room_id>" > .collab-room`
- `echo "<seu_nome>" > .collab-name`
- Após processar mensagens, atualize: `echo "<last_id>" > .collab-last-id`
```

### 2. Instruções no CLAUDE.md (comportamental)

As instruções no CLAUDE.md dizem ao agente quando checar mensagens manualmente (ao iniciar, quando bloqueado, antes de PR) e como se comportar quando espera resposta. Veja a seção [Configuração nos repos](#configuração-nos-repos-claudemd).

### 3. Você manda checar (manual)

A qualquer momento, diga ao agente:

```
> Checa as mensagens no room aba-80
```

## Configuração por Agent/IDE

### Claude Code

```bash
claude mcp add -s user collab -- node ~/AI/collab-mcp/dist/index.js
```

Ou manualmente, crie/edite `.mcp.json` na raiz do projeto:

```json
{
  "mcpServers": {
    "collab": {
      "command": "node",
      "args": ["/Users/<you>/AI/collab-mcp/dist/index.js"]
    }
  }
}
```

### Codex (OpenAI)

Edite `~/.codex/config.toml`:

```toml
[mcp_servers.collab]
command = "node"
args = ["/Users/<you>/AI/collab-mcp/dist/index.js"]
```

### Cursor

Crie/edite `.cursor/mcp.json` na raiz do projeto (ou `~/.cursor/mcp.json` pra global):

```json
{
  "mcpServers": {
    "collab": {
      "command": "node",
      "args": ["/Users/<you>/AI/collab-mcp/dist/index.js"]
    }
  }
}
```

> Em todos os casos, substitua `/Users/<you>/` pelo seu home directory.

## Tools disponíveis

| Tool                | Params                           | Descrição                                           |
| ------------------- | -------------------------------- | --------------------------------------------------- |
| `create_room`       | `room_id`, `description?`        | Cria uma sala                                       |
| `join_room`         | `room_id`, `name`                | Entra na sala (cria automaticamente se não existir) |
| `send_message`      | `room_id`, `sender`, `content`   | Envia mensagem (auto-join se necessário)            |
| `get_messages`      | `room_id`, `since_id?`, `limit?` | Lê mensagens (default: últimas 50)                  |
| `list_rooms`        | —                                | Lista todas as salas                                |
| `list_participants` | `room_id`                        | Lista participantes da sala                         |

## Convenções de comunicação

### @Mentions

Use `@nome` no conteúdo da mensagem pra direcionar a quem é. Os nomes devem ser os mesmos usados no `join_room`.

```
@frontend O endpoint /api/v1/notes já está pronto. Schema abaixo.
@backend Preciso de um campo "priority" no response, pode adicionar?
@all Mudança de plano: vamos usar WebSocket ao invés de polling.
@andre Estou bloqueado, preciso de decisão sobre o schema de permissões.
```

Convenções:

- `@nome` — direciona mensagem pra um participante específico
- `@all` — mensagem pra todos na sala
- Sem `@` — mensagem geral, informativa, pra qualquer um que ler

### Papéis

| Participante | Papel                                                                                              |
| ------------ | -------------------------------------------------------------------------------------------------- |
| `andre`      | **Supervisor.** Dá direcionamento, toma decisões, resolve conflitos. Suas mensagens são diretivas. |
| `backend`    | Agente trabalhando no backend (Django, API, models, migrations)                                    |
| `audit`      | Agente trabalhando no frontend audit (Next.js)                                                     |
| `website`    | Agente trabalhando no frontend website (Vite + React)                                              |
| `mobile`     | Agente trabalhando no app mobile (Flutter)                                                         |

> Adapte os nomes ao seu projeto. O importante é que cada agente use consistentemente o mesmo nome em `join_room` e `sender`.

### Quando comunicar

Os agentes devem enviar mensagens proativamente nestas situações:

| Situação                                       | Exemplo                                                                                                             |
| ---------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| Criou/alterou endpoint de API                  | `@audit @website Novo endpoint POST /api/v1/notes. Request: {content: string}. Response: {id, content, created_at}` |
| Alterou schema/model                           | `@all Adicionei campo "priority" (int, default 0) no model Note. Migration 0097.`                                   |
| Alterou contrato (tipos, enums, formatos)      | `@audit O enum StatusType agora inclui "ARCHIVED"`                                                                  |
| Está bloqueado e precisa de algo de outro repo | `@backend Preciso do endpoint de upload de arquivos pra continuar. Existe?`                                         |
| Precisa de decisão humana                      | `@andre Duas opções: paginação cursor-based ou offset. Qual prefere?`                                               |
| Completou a tarefa                             | `@all Finalizei. PR aberto: #123. Endpoint /api/v1/notes funcionando.`                                              |

### Quando ler mensagens

Os agentes devem checar mensagens (`get_messages`) nestes momentos:

1. **Ao iniciar o trabalho** — antes de começar, ler o histórico pra ter contexto
2. **Quando estiver bloqueado** — talvez outro agente já resolveu a dependência
3. **Antes de abrir PR** — checar se tem algum aviso dos outros
4. **Quando o supervisor manda** — mensagens do `andre` são prioritárias

## Uso

### Fluxo básico

Abra 2+ terminais com agentes diferentes trabalhando na mesma feature:

**Terminal 1 — Claude Code (backend):**

```
> Estamos trabalhando na feature ABA-80.
> Join room aba-80 como "backend".
> Leia as mensagens anteriores e comunique qualquer mudança de API pro frontend.
```

**Terminal 2 — Claude Code (frontend):**

```
> Join room aba-80 como "audit".
> Leia as mensagens pra ver se o backend já comunicou os endpoints.
```

**Você (em qualquer terminal):**

```
> Entra no room aba-80 como "andre" e manda:
> "@all Lembrem que precisa de paginação em todos os endpoints de listagem."
```

### Exemplo de conversa entre agentes

```
[#1] backend (2026-03-24 14:32:00):
@audit @website Criei endpoint POST /api/v1/patients/{id}/notes
Request: { content: string }
Response: { id, content, created_at, author_id }
Header: Authorization: Bearer <token>

[#2] audit (2026-03-24 14:35:12):
@backend Recebi. O author_id é o ID do user logado ou preciso enviar?

[#3] backend (2026-03-24 14:36:05):
@audit Preenchido automaticamente pelo token. Não precisa enviar.

[#4] andre (2026-03-24 14:37:00):
@backend Precisa de paginação nesse endpoint. Limit/offset.

[#5] backend (2026-03-24 14:40:00):
@andre Feito. GET /api/v1/patients/{id}/notes agora aceita ?limit=20&offset=0.
@audit Atualização: endpoint de listagem agora retorna { results: [...], count: N }.

[#6] audit (2026-03-24 14:42:00):
@backend Obrigado, atualizei o hook useNotes pra usar paginação.
```

### Polling de mensagens novas

Use `since_id` pra pegar apenas mensagens novas:

```
> Checa mensagens novas no room aba-80 (última que li foi a #3)
```

O agente chama `get_messages(room_id: "aba-80", since_id: 3)` e recebe apenas a #4+.

### Dicas de uso

- **Nomeie os participantes pelo papel:** `backend`, `audit`, `website`, `andre` — facilita identificar quem disse o quê
- **Use o room_id da issue:** `aba-80`, `feat-login`, `bug-123` — cada feature tem sua sala
- **Mensagens persistem entre sessões:** O SQLite mantém o histórico. Útil pra retomar contexto no dia seguinte
- **O supervisor pode falar por qualquer terminal:** Basta usar `sender: "andre"` de qualquer instância

## Configuração nos repos (CLAUDE.md)

Pra que os agentes sejam proativos, é preciso adicionar instruções no `CLAUDE.md` (ou `AGENTS.md`) de cada repositório. Abaixo está o template — copie e adapte o `AGENT_NAME` e a descrição do papel.

### Template para CLAUDE.md

```markdown
## Collab Room — Comunicação entre agentes

Este projeto participa de um sistema de comunicação entre agentes via MCP (collab).
Você tem acesso às tools: `create_room`, `join_room`, `send_message`, `get_messages`, `list_rooms`, `list_participants`.

### Seu papel

- **Seu nome:** `<AGENT_NAME>` (use este nome em join_room e sender)
- **Papel:** <descrição do que este agente faz>
- **Supervisor:** `andre` — mensagens do andre são diretivas e têm prioridade

### Quando o usuário indicar um room

Quando o usuário disser algo como "join room X" ou "estamos no room X":

1. Chame `join_room(room_id, "<AGENT_NAME>")`
2. Chame `get_messages(room_id)` pra ler o contexto existente
3. Se houver mensagens com `@<AGENT_NAME>` ou `@all`, responda/aja conforme necessário
4. Crie os arquivos de estado no workspace:
   - `echo "ROOM_ID" > .collab-room`
   - `echo "<AGENT_NAME>" > .collab-name`
   - Após cada `get_messages`, atualize: `echo "LAST_MSG_ID" > .collab-last-id`

### Notificações automáticas

Um hook `PostToolUse` roda automaticamente após cada tool call e verifica se há mensagens novas com `@<AGENT_NAME>` ou `@all` no room. Se houver, o conteúdo das mensagens é injetado no seu contexto — você não precisa fazer polling manual.

Quando receber uma notificação de mensagem via hook:
1. Leia a mensagem e aja conforme necessário
2. Atualize o `.collab-last-id`: `echo "ID" > .collab-last-id`
3. Se a mensagem pedir algo, responda via `send_message`

### Aguardando resposta de outro agente

Quando você envia uma mensagem que precisa de resposta, NÃO pare e NÃO pergunte ao usuário. Continue trabalhando em outra parte da tarefa — a resposta chegará automaticamente via hook no próximo tool call.

O supervisor (`andre`) monitora a sala mas não é intermediário. Interaja direto com os outros agentes.

### Quando comunicar (send_message)

Envie mensagem proativamente quando:

- Criar ou alterar um endpoint, model, migration, ou contrato de API
- Alterar um tipo, enum, interface, ou formato que outros repos consomem
- Estiver bloqueado esperando algo de outro agente
- Precisar de uma decisão do supervisor (`@andre`)
- Completar sua tarefa (informe `@all`)

Formato das mensagens:

- Use `@nome` pra direcionar: `@frontend`, `@backend`, `@andre`, `@all`
- Seja objetivo: inclua nomes de endpoints, campos, tipos, branches
- Inclua detalhes técnicos que o outro agente precisa pra consumir seu trabalho

### Quando ler mensagens (get_messages)

Leia mensagens do room:

- **Ao iniciar trabalho** em uma feature compartilhada
- **Quando bloqueado** por dependência de outro repo
- **Antes de abrir PR** pra checar avisos dos outros
- **Quando o usuário pedir** pra checar mensagens

Guarde o `id` da última mensagem lida e use `since_id` nas próximas chamadas.

### Aguardando resposta de outro agente

**IMPORTANTE:** Quando você envia uma mensagem que precisa de resposta, NÃO pare e NÃO pergunte ao usuário. Faça o seguinte automaticamente:

1. Continue trabalhando em outra parte da tarefa que não dependa da resposta
2. Se não tiver mais nada pra fazer, faça polling: chame `get_messages` com `since_id` a cada ~30s até receber resposta
3. Quando a resposta chegar, prossiga normalmente

O supervisor (`andre`) monitora a sala mas não é intermediário. Interaja direto com os outros agentes.
```

## Adicionando collab a um novo repo

### 1. Criar `collab.json` na raiz do projeto

```json
{
  "name": "meu-agent",
  "role": "Descrição do que este agente faz",
  "communicate_when": [
    "Situação específica em que deve comunicar",
    "Outra situação"
  ],
  "peers": ["backend", "audit"]
}
```

### 2. Adicionar MCP server no `.mcp.json`

```json
{
  "mcpServers": {
    "collab": {
      "command": "node",
      "args": ["/Users/<you>/AI/collab-mcp/dist/index.js"]
    }
  }
}
```

### 3. Adicionar hooks no `.claude/settings.local.json`

```json
{
  "enableAllProjectMcpServers": true,
  "enabledMcpjsonServers": ["collab"],
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/Users/<you>/AI/collab-mcp/hooks/session-start.sh",
            "timeout": 5
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/Users/<you>/AI/collab-mcp/hooks/post-tool-use.sh",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

### 4. Adicionar ao `.gitignore`

```
collab.json
.collab-room
.collab-name
.collab-last-id
```

### 5. (Opcional) Adicionar contexto mínimo no `CLAUDE.md`

Uma seção curta de 2-3 linhas descrevendo onde o repo se encaixa no ecossistema. Útil mesmo quando collab não está ativo.

```markdown
## Ecosystem

This is the **nome** of Projeto X. It consumes/serves [lista de repos relacionados].
```

### 6. (Opcional) Atualizar `~/.config/collab/team.json`

Se o repo faz parte de um ecossistema, adicione-o ao `team.json` centralizado pra que todos os agentes saibam da sua existência.

## Contexto de equipe (`team.json`)

O arquivo `~/.config/collab/team.json` descreve o ecossistema de repos. É lido pelo hook `session-start.sh` e injetado automaticamente em cada sessão.

```json
{
  "project": "Nome do Projeto",
  "description": "Descrição breve",
  "supervisor": "andre",
  "repos": {
    "backend": {
      "stack": "Django + ...",
      "role": "O que faz",
      "serves": ["frontend-a", "frontend-b"],
      "repo": "Org/repo-name"
    },
    "frontend-a": {
      "stack": "Next.js + ...",
      "role": "O que faz",
      "consumes": ["backend"],
      "repo": "Org/repo-name"
    }
  }
}
```

O agente vê algo como:

```
## Equipe — Nome do Projeto
Descrição breve

- backend ← você: Django + ... (serve: frontend-a, frontend-b)
- frontend-a: Next.js + ... (consome: backend)
```

## Arquitetura

```
src/
├── index.ts        — MCP server entry point + stdio transport
├── db.ts           — SQLite (better-sqlite3), WAL mode, schema, queries
├── tools.ts        — 6 MCP tools registradas no server
├── cli.ts          — CLI pra humanos: send, read, tui, rooms, who, check
├── tui.ts          — Chat interativo no terminal
└── db.test.ts      — Testes unitários (node:test)

hooks/
├── session-start.sh  — Lê collab.json + team.json, injeta contexto via additionalContext
└── post-tool-use.sh  — Checa mensagens novas, injeta via additionalContext

~/.config/collab/
├── collab.db         — SQLite com rooms, participants, messages
└── team.json         — Contexto do ecossistema (repos, stacks, relações)
```

- **Storage:** SQLite com WAL mode em `~/.config/collab/collab.db`
- **Transport:** stdio (cada agent CLI spawna o processo Node)
- **CLI:** Comando `collab` pra uso direto no terminal (npm link)
- **Hooks:** Shell scripts que retornam `hookSpecificOutput.additionalContext` — padrão de plugins do Claude Code
- **Concorrência:** Cada instância de agent spawna seu próprio processo MCP server, mas todos acessam o mesmo arquivo SQLite. WAL mode garante que reads não bloqueiam writes.

## Limitações conhecidas

- **Sem push nativo:** Agentes não recebem notificações em tempo real. Usam polling (`get_messages` + `since_id`), hooks (`collab check`), ou instruções no CLAUDE.md pra checar em momentos-chave.
- **Um processo por agent:** Cada agent CLI spawna seu próprio processo Node do MCP server. Isso é normal e funciona bem graças ao SQLite WAL mode.
- **Sem autenticação:** Qualquer processo local que consiga executar o server tem acesso às mensagens. Adequado para uso local/pessoal.
