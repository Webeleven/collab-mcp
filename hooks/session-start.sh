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
# A subagent shares its parent's pane: cleaning here would drop the parent's room.
[ -z "$COLLAB_SUBAGENT" ] && [ -n "$PANE" ] || exit 0
COLLAB_PANE=$PANE
export COLLAB_PANE
rm -f ".collab-room-$COLLAB_PANE" ".collab-name-$COLLAB_PANE" \
      ".collab-last-id-$COLLAB_PANE" ".collab-herdr-$COLLAB_PANE"

if [ ! -f "$COLLAB_JSON" ]; then
  exit 0
fi

# Generate full context via python (easier to handle JSON + string building)
CONTEXT=$("$COLLAB_PYTHON" << 'PYEOF'
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
   - O cursor {last_id_file} é dos hooks; só grave nele um id maior que o atual
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

**Anuncie seus dois endereços na primeira mensagem da sala.** Vários agentes da
mesma plataforma podem estar no mesmo repo, então papel e `cwd` não identificam
ninguém — o room id é o que o par/trio compartilha.

- **Handle Claude nativo**, o que outro Claude Code usa para te acordar: carregue
  `ListAgents` e `SendMessage` de uma vez (`ToolSearch` com
  `select:ListAgents,SendMessage`), chame `ListAgents` e anuncie a linha que ele
  marca como esta sessão, no formato `Handle Claude nativo: <nome> [<ref>]`.
  Anuncie de novo depois de retomar a sessão ou de um `/rename`. Só subagente,
  Cursor ou Codex anunciam que não têm handle nativo.
- **Endereço Herdr**, para Cursor, Codex e outras máquinas: depois que você
  gravar `{room_file}` e `{name_file}`, o hook PostToolUse registra um endereço
  normalizado no Herdr e guarda o resultado em `{herdr_file}`. Leia e anuncie
  exatamente esse endereço. Sem Herdr, não tente ler nem criar esse arquivo.

O endereço Herdr sempre usa um prefixo legível de 23 caracteres + `-` + 8 hex
do SHA-256 do par original `[papel, room]`. O sufixo dos arquivos usa slug +
hash da identidade original do pane ou `session_id`, evitando colisões após a
normalização; `solo` é apenas o último fallback.

Se o conteúdo começar com `taken:`, outro agente já ocupa esse papel nesta sala.
Diga isso na sala em vez de assumir que você está endereçável.

O wake segue a plataforma do **destinatário**, não as ferramentas do remetente:

1. **Claude Code nesta máquina: nativo.** `SendMessage` para o handle que o alvo
   anunciou na sala ou no kickoff, depois que `ListAgents` mostrar uma única
   linha com esse nome ou `[ref]`. Alvo `working` serve: a mensagem espera o
   próximo turno dele. Pane Herdr num brief identifica o agente, não escolhe o
   transporte.
2. **Herdr só onde o nativo não alcança:** Cursor, Codex, outra máquina, ou
   Claude sem handle anunciado. `herdr agent prompt <nome>` com o alvo `idle`
   ou `done`; Cursor/Codex `working` recebe um único wake em background para
   quando ficar `idle`/`done`, com timeout de 30 minutos; `blocked`/`unknown`
   não recebe wake.
3. **Nunca digite num pane onde uma pessoa pode estar escrevendo:** linha do
   `herdr agent list` com `"focused": true`, ou alvo de papel `lead` ou `andre`.
   A sala já tem a mensagem; pule o wake e diga isso.
4. Com mais de um candidato, lista nome, plataforma, pane e status, e pergunta
   uma vez. Nunca acorda vários candidatos nem chuta.

Envie no máximo um wake. A resposta também vai primeiro para a sala e usa o
mesmo protocolo no caminho de volta. Wakes morrem com a sessão; a sala é o
registro que o próximo agente vai ler.

### Notificações automáticas
Um hook PostToolUse verifica mensagens novas automaticamente após cada tool call.
Se houver mensagens com @{name} ou @all, o conteúdo é injetado no seu contexto.
Cada mensagem é injetada uma vez só: o hook avança o cursor em {last_id_file}.
Quando receber uma notificação:
1. Aja conforme necessário
2. Se pedirem algo, responda via send_message

### Aguardando resposta
1. **Acorde o alvo** (skill `peer-notify`) — sem isso ele pode nunca ler a sala
2. Se ainda houver trabalho independente, continue. O hook injeta respostas novas
3. Se a próxima ação depende da resposta, **encerre o turno**. Não rode
   `collab watch` e não faça polling de `get_messages`. A resposta chega pelo
   wake nativo, por um wake Herdr quando você estiver `idle`, ou pelo hook
4. Quando a resposta chegar, prossiga

Você é autônomo. O supervisor monitora a sala mas não é intermediário. Interaja direto com os outros agentes. Só envolva @andre quando precisar de decisão de produto/negócio."""

print(context)
PYEOF
)

if [ -z "$CONTEXT" ]; then
  exit 0
fi

CONTEXT_ESCAPED=$(echo "$CONTEXT" | "$COLLAB_PYTHON" -c "import sys,json; print(json.dumps(sys.stdin.read()))")

cat << ENDJSON
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": ${CONTEXT_ESCAPED}
  }
}
ENDJSON

exit 0
