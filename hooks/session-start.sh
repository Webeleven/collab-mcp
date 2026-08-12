#!/usr/bin/env bash
# Collab MCP — SessionStart hook
# Reads collab.json (project root) and team.json (~/.config/collab/) to inject
# agent identity + team context into the session.
# If collab.json doesn't exist, exits silently.

COLLAB_JSON="collab.json"
TEAM_JSON="$HOME/.config/collab/team.json"

# Clean up stale state from previous sessions
rm -f .collab-room .collab-name .collab-last-id

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
4. Crie os arquivos de estado:
   - echo "ROOM_ID" > .collab-room
   - echo "{name}" > .collab-name
   - Após cada get_messages, atualize: echo "LAST_MSG_ID" > .collab-last-id
5. **Pingue quem abriu a sala** avisando que você assumiu (ver "Ping
   direto"). Ele pode estar parado e não ver sua entrada.

### Quando comunicar (send_message)
Envie mensagem proativamente quando:
{communicate_lines}
- Estiver bloqueado esperando algo de outro agente
- Precisar de uma decisão do supervisor (@andre)
- Completar sua tarefa (informe @all)

Formato: use @nome pra direcionar. Seja objetivo — inclua nomes de endpoints, campos, tipos, branches.

### Ping direto (SendMessage) — acorda quem a sala não acorda

A sala **registra**; o ping **entrega**. Um agente parado NÃO lê a sala
sozinho, e um agente ocupado só lê quando lembra. Se a sua mensagem precisa
de ação, poste na sala **e** pingue.

`ListAgents` lista as sessões vivas. Para pingar:
`SendMessage({{to: "<nome> [ref]", message: "..."}})`

`SendMessage` também costuma vir deferred — carregue com `ToolSearch`
`select:SendMessage` antes da primeira chamada. Se der
`InputValidationError`, é isso: carregue e repita. Não conclua que o ping
é indisponível.

O **`[ref]` entre colchetes é obrigatório na primeira chamada** — só o nome
é recusado, e o próprio erro devolve o ref certo para reenviar na hora.

1. **Não sabe quem pingar? Pingue mesmo assim.** Escolha o candidato mais
   provável (o nome da sessão costuma carregar o repo ou a worktree) e abra
   se identificando: "sou o `{name}`, trabalhando em <contexto>; se você não
   é <alvo>, ignora e me avisa". Um ping errado custa uma linha lida; travar
   esperando o @andre custa a sessão inteira.
   **NUNCA pare para perguntar "qual agente eu pingo?".**
2. **Recebeu um ping? Guarde o `from=`.** É o endereço de retorno e a única
   forma garantida de contato — o nome do peer desaparece do `ListAgents`
   assim que a sessão dele termina, mas o `from=` continua respondendo.
3. **Ao responder na sala, pingue de volta.** Quem te perguntou pode estar
   parado esperando, e não vai ver a resposta sozinho.
4. O que exige resposta vai **na sala e no ping**. O ping morre com a
   sessão; a sala sobrevive — é nela que o próximo agente vai ler o que
   ficou decidido.

### Notificações automáticas
Um hook PostToolUse verifica mensagens novas automaticamente após cada tool call.
Se houver mensagens com @{name} ou @all, o conteúdo é injetado no seu contexto.
Quando receber uma notificação:
1. Aja conforme necessário
2. Atualize .collab-last-id: echo "ID" > .collab-last-id
3. Se pedirem algo, responda via send_message

### Aguardando resposta
Quando enviar uma mensagem que precisa de resposta, NÃO pare e NÃO pergunte ao usuário.
1. **Pingue o alvo** (ver "Ping direto") — sem isso ele pode nunca ler a sala
2. Continue trabalhando em outra parte da tarefa — o hook detecta respostas automaticamente
3. Se não tiver mais nada pra fazer, faça polling: get_messages com since_id a cada ~30s
4. Quando a resposta chegar, atualize .collab-last-id e prossiga

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
