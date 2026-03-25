#!/usr/bin/env bash
# Collab MCP — SessionStart hook
# Reads collab.json (project root) and team.json (~/.config/collab/) to inject
# agent identity + team context into the session.
# If collab.json doesn't exist, exits silently.

COLLAB_JSON="collab.json"
TEAM_JSON="$HOME/.config/collab/team.json"

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

context = f"""{team_section}
## Collab Room — Comunicação entre agentes

Você tem acesso a um sistema de chat entre agentes via MCP (collab).
Tools disponíveis: create_room, join_room, send_message, get_messages, list_rooms, list_participants.

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
4. Crie os arquivos de estado:
   - echo "ROOM_ID" > .collab-room
   - echo "{name}" > .collab-name
   - Após cada get_messages, atualize: echo "LAST_MSG_ID" > .collab-last-id

### Quando comunicar (send_message)
Envie mensagem proativamente quando:
{communicate_lines}
- Estiver bloqueado esperando algo de outro agente
- Precisar de uma decisão do supervisor (@andre)
- Completar sua tarefa (informe @all)

Formato: use @nome pra direcionar. Seja objetivo — inclua nomes de endpoints, campos, tipos, branches.

### Notificações automáticas
Um hook PostToolUse verifica mensagens novas automaticamente após cada tool call.
Se houver mensagens com @{name} ou @all, o conteúdo é injetado no seu contexto.
Quando receber uma notificação:
1. Aja conforme necessário
2. Atualize .collab-last-id: echo "ID" > .collab-last-id
3. Se pedirem algo, responda via send_message

### Aguardando resposta
Quando enviar uma mensagem que precisa de resposta, NÃO pare e NÃO pergunte ao usuário.
1. Continue trabalhando em outra parte da tarefa — o hook detecta respostas automaticamente
2. Se não tiver mais nada pra fazer, faça polling: get_messages com since_id a cada ~30s
3. Quando a resposta chegar, atualize .collab-last-id e prossiga

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
