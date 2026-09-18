#!/usr/bin/env bash
# Collab MCP — SessionStart hook
# Reads collab.json (project root) and team.json (~/.config/collab/) to inject
# agent identity + team context into the session.
# If collab.json doesn't exist, exits silently.

COLLAB_JSON="collab.json"
TEAM_JSON="$HOME/.config/collab/team.json"

# Resolve this Herdr pane or native Claude session before cleaning state.
# _state.sh may return non-zero because SessionStart has no room yet; PANE is
# still initialized.
. "$(dirname "$0")/_state.sh" || true
COLLAB_PANE=$PANE
export COLLAB_PANE
rm -f ".collab-room-$COLLAB_PANE" ".collab-name-$COLLAB_PANE" \
      ".collab-last-id-$COLLAB_PANE" ".collab-herdr-$COLLAB_PANE"

if [ ! -f "$COLLAB_JSON" ]; then
  exit 0
fi

# Generate full context via python (easier to handle JSON + string building)
CONTEXT=$(python3 << 'PYEOF'
import json, os, sys

collab_path = "collab.json"
team_path = os.path.expanduser("~/.config/collab/team.json")

try:
    with open(collab_path) as f:
        collab = json.load(f)
except Exception:
    sys.exit(0)

name = collab.get("name", "")
if not name:
    sys.exit(0)

role = collab.get("role", "")
peers = collab.get("peers", [])
communicate_when = collab.get("communicate_when", [])

# Build team context
team_section = ""
try:
    with open(team_path) as f:
        team = json.load(f)

    project = team.get("project", "")
    description = team.get("description", "")
    repos = team.get("repos", {})

    team_lines = [
        f"## Equipe — {project}",
        f"{description}\n",
    ]
    for repo_name, info in repos.items():
        marker = " ← você" if repo_name == name else ""
        role_desc = info.get("role", "")
        stack = info.get("stack", "")
        serves = info.get("serves", [])
        consumes = info.get("consumes", [])
        relations = []
        if serves:
            relations.append(f"serve: {', '.join(serves)}")
        if consumes:
            relations.append(f"consome: {', '.join(consumes)}")
        rel_str = f" ({', '.join(relations)})" if relations else ""
        team_lines.append(f"- **{repo_name}**{marker}: {stack}{rel_str}")
        if role_desc:
            team_lines.append(f"  {role_desc}")

    team_section = "\n".join(team_lines) + "\n"
except Exception:
    pass

# Build collab instructions
peers_str = ", ".join(f"@{p}" for p in peers)
communicate_lines = "\n".join(f"- {item}" for item in communicate_when)

# State files are per pane: agents sharing a repository share its directory.
pane = os.environ.get("COLLAB_PANE", "solo")
room_file = f".collab-room-{pane}"
name_file = f".collab-name-{pane}"
last_id_file = f".collab-last-id-{pane}"
herdr_file = f".collab-herdr-{pane}"

context = f"""{team_section}
## Collab Room — Comunicação entre agentes

Você tem acesso a um sistema de chat entre agentes via MCP (collab).
Tools: create_room, join_room, send_message, get_messages, list_rooms, list_participants.

**Elas podem chegar como deferred** (só o nome, sem schema). Se for o caso,
carregue TODAS de uma vez antes de usar — uma chamada só, nunca uma por tool:
`ToolSearch` com
`select:mcp__collab__join_room,mcp__collab__send_message,mcp__collab__get_messages,mcp__collab__list_rooms`
Chamar uma tool deferred sem carregar dá `InputValidationError`. Isso **não**
significa que você não tem a ferramenta — significa que falta carregar.

### Seu perfil
- **Nome:** `{name}` (use em join_room e sender)
- **Papel:** {role}
- **Supervisor:** `andre` — mensagens do andre são diretivas e têm prioridade
- **Peers:** {peers_str}

### Quando o usuário indicar um room
Quando o usuário disser algo como "join room X" ou "estamos no room X":
1. Chame join_room(room_id, "{name}")
2. Chame get_messages(room_id) pra ler o contexto existente
3. Se houver mensagens com @{name} ou @all, responda/aja conforme necessário
4. Crie os arquivos de estado — os nomes abaixo são os **seus**, com o sufixo
   do seu pane, e outro agente no mesmo repo usa os dele:
   - echo "ROOM_ID" > {room_file}
   - echo "{name}" > {name_file}
   - Após cada get_messages, atualize: echo "LAST_MSG_ID" > {last_id_file}
5. **Acorde quem abriu a sala** (skill `peer-notify`) avisando que assumiu.

### Quando comunicar (send_message)
Envie mensagem proativamente quando:
{communicate_lines}
- Estiver bloqueado esperando algo de outro agente
- Precisar de uma decisão do supervisor (@andre)
- Completar sua tarefa (informe @all)

Formato: use @nome pra direcionar. Seja objetivo — inclua nomes de endpoints, campos, tipos, branches.

### Entrega entre plataformas

A sala **registra**; um wake só chama a atenção de uma sessão viva. Quando uma
mensagem precisa de ação rápida ou resposta, poste o conteúdo completo na sala
e siga o skill `peer-notify`.

**Seu endereço é reivindicado sozinho.** Vários agentes da mesma plataforma
podem estar no mesmo repo, então papel e `cwd` não identificam ninguém — o room
id é o que o par/trio compartilha. Depois que você gravar `{room_file}` e
`{name_file}`, o hook PostToolUse registra um endereço normalizado no Herdr e
guarda o resultado em `{herdr_file}`.

- Se `{herdr_file}` existir, leia e anuncie exatamente esse endereço.
- Se Herdr não estiver disponível, não tente ler nem criar esse arquivo;
  anuncie que esta sessão não tem endereço Herdr.
- Se `ListAgents` existir, chame uma vez e publique o handle Claude nativo
  somente quando a saída marcar explicitamente a linha desta própria sessão.
  Nunca infira sua linha por repo, worktree ou papel. Se não houver linha
  própria, diga que nenhum handle nativo foi publicado.

O endereço Herdr sempre usa um prefixo legível de 23 caracteres + `-` + 8 hex
do SHA-256 do par original `[papel, room]`. O sufixo dos arquivos usa slug +
hash da identidade original do pane ou `session_id`, evitando colisões após a
normalização; `solo` é apenas o último fallback.

Se o conteúdo começar com `taken:`, outro agente já ocupa esse papel nesta sala.
Diga isso na sala em vez de assumir que você está endereçável.

O protocolo resolve primeiro a plataforma do **destinatário**, não as
ferramentas disponíveis no remetente:

1. Um alvo nomeado por quem pediu vence qualquer inferência. Senão, procura o
   endereço normalizado da lane no Herdr e só então cai para um agente **sem
   nome** no repo/worktree. Nunca use como fallback alguém nomeado em outra lane.
2. Se o alvo for Claude, prefira o handle nativo publicado quando `ListAgents`
   confirmar um único match. Sem handle publicado, compare a sessão Herdr
   resolvida com `ListAgents`: use id/ref compartilhado quando existir; senão,
   use `SendMessage` apenas se exatamente uma linha Claude tiver o mesmo `cwd`
   ou worktree exato. Mais de uma linha no mesmo checkout é ambígua e mantém o
   alvo Herdr. Assim CC↔CC continua imediato sem chutar entre sessões.
3. Para Cursor, Codex, ou Claude sem canal nativo, usa
   `herdr agent prompt <nome>` somente quando o alvo estiver `idle` ou `done`.
   Se estiver `working`, enfileire um único wake em background para quando ficar
   `idle`/`done`, com timeout de 30 minutos. Se estiver `blocked`/`unknown`, a
   sala já tem a mensagem — não acorde.
4. Com mais de um candidato, lista nome, plataforma, pane e status, e pergunta
   uma vez. Nunca acorda vários candidatos nem chuta.

Envie no máximo um wake. A resposta também vai primeiro para a sala e usa o
mesmo protocolo no caminho de volta. Wakes morrem com a sessão; a sala é o
registro que o próximo agente vai ler.

### Notificações automáticas
Um hook PostToolUse verifica mensagens novas automaticamente após cada tool call.
Se houver mensagens com @{name} ou @all, o conteúdo é injetado no seu contexto.
Quando receber uma notificação:
1. Aja conforme necessário
2. Atualize seu cursor: echo "ID" > {last_id_file}
3. Se pedirem algo, responda via send_message

### Aguardando resposta
1. **Acorde o alvo** (skill `peer-notify`) — sem isso ele pode nunca ler a sala
2. Se ainda houver trabalho independente, continue. O hook injeta respostas novas
3. Se a próxima ação depende da resposta, **encerre o turno**. Não rode
   `collab watch` e não faça polling de `get_messages`. Encerrar é o que te
   deixa `idle`, e só `idle`/`done` recebem wake Herdr
4. Quando a resposta chegar (wake ou hook), atualize {last_id_file} e prossiga

Você é autônomo. O supervisor monitora a sala mas não é intermediário. Interaja direto com os outros agentes. Só envolva @andre quando precisar de decisão de produto/negócio."""

print(context)
PYEOF
)

if [ -z "$CONTEXT" ]; then
  exit 0
fi

CONTEXT_ESCAPED=$(echo "$CONTEXT" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))")

cat << ENDJSON
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": ${CONTEXT_ESCAPED}
  }
}
ENDJSON

exit 0
