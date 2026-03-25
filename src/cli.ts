#!/usr/bin/env node

import {
  createRoom,
  joinRoom,
  sendMessage,
  getMessages,
  listRooms,
  listParticipants,
} from "./db.js";

const [, , command, ...args] = process.argv;

const USAGE = `collab — CLI para comunicação entre agentes

Comandos:
  collab send <room> <sender> <message>     Envia mensagem
  collab read <room> [--since <id>]          Lê mensagens
  collab rooms                               Lista salas
  collab who <room>                          Lista participantes
  collab tui <room> [nome]                    Chat interativo (mensagens + input)
  collab watch <room> [--interval <s>]        Monitora mensagens em tempo real (tipo tail -f)
  collab check <room> <name> <since_id>      Checa mensagens novas pra @name (pra hooks)

Exemplos:
  collab send aba-80 andre "@backend Adiciona paginação no endpoint de notes"
  collab read aba-80
  collab read aba-80 --since 5
  collab tui aba-80
  collab tui aba-80 andre
  collab watch aba-80
  collab watch aba-80 --interval 1
  collab rooms
  collab who aba-80
  collab check aba-80 backend 10
`;

function die(msg: string): never {
  console.error(msg);
  process.exit(1);
}

switch (command) {
  case "send": {
    const [room, sender, ...messageParts] = args;
    if (!room || !sender || messageParts.length === 0) {
      die("Uso: collab send <room> <sender> <message>");
    }
    const content = messageParts.join(" ");
    joinRoom(room, sender);
    const id = sendMessage(room, sender, content);
    console.log(`#${id} enviada em "${room}".`);
    break;
  }

  case "read": {
    const [room, ...flags] = args;
    if (!room) die("Uso: collab read <room> [--since <id>]");
    let sinceId: number | undefined;
    const sinceIdx = flags.indexOf("--since");
    if (sinceIdx !== -1) {
      sinceId = parseInt(flags[sinceIdx + 1], 10);
      if (isNaN(sinceId)) die("--since precisa de um número");
    }
    const messages = getMessages(room, sinceId) as Array<{
      id: number;
      sender: string;
      content: string;
      created_at: string;
    }>;
    if (messages.length === 0) {
      console.log(sinceId ? `Sem mensagens novas desde #${sinceId}.` : "Sala vazia.");
    } else {
      for (const m of messages) {
        console.log(`[#${m.id}] ${m.sender} (${m.created_at}):`);
        console.log(`${m.content}\n`);
      }
    }
    break;
  }

  case "rooms": {
    const rooms = listRooms() as Array<{
      id: string;
      description: string | null;
      participant_count: number;
      message_count: number;
    }>;
    if (rooms.length === 0) {
      console.log("Nenhuma sala.");
    } else {
      for (const r of rooms) {
        console.log(
          `${r.id}${r.description ? ` — ${r.description}` : ""} (${r.participant_count} participantes, ${r.message_count} msgs)`
        );
      }
    }
    break;
  }

  case "who": {
    const [room] = args;
    if (!room) die("Uso: collab who <room>");
    const participants = listParticipants(room) as Array<{
      name: string;
      joined_at: string;
    }>;
    if (participants.length === 0) {
      console.log("Nenhum participante.");
    } else {
      for (const p of participants) {
        console.log(`${p.name} (desde ${p.joined_at})`);
      }
    }
    break;
  }

  case "tui": {
    const { startTui } = await import("./tui.js");
    const [room, name] = args;
    if (!room) die("Uso: collab tui <room> [nome]");
    startTui(room, name || "andre");
    break;
  }

  case "watch": {
    const [room, ...flags] = args;
    if (!room) die("Uso: collab watch <room> [--interval <s>]");
    let interval = 2;
    const intIdx = flags.indexOf("--interval");
    if (intIdx !== -1) {
      interval = parseFloat(flags[intIdx + 1]);
      if (isNaN(interval) || interval < 0.5) die("--interval mínimo 0.5s");
    }

    // Print existing messages first
    let lastId = 0;
    const existing = getMessages(room) as Array<{
      id: number;
      sender: string;
      content: string;
      created_at: string;
    }>;
    for (const m of existing) {
      console.log(`\x1b[90m${m.created_at}\x1b[0m \x1b[36m${m.sender}\x1b[0m: ${m.content}`);
      lastId = m.id;
    }
    if (existing.length > 0) console.log("---");
    console.log(`\x1b[90mMonitorando room "${room}" (Ctrl+C pra sair)...\x1b[0m\n`);

    // Poll for new messages
    const poll = () => {
      const messages = getMessages(room, lastId) as Array<{
        id: number;
        sender: string;
        content: string;
        created_at: string;
      }>;
      for (const m of messages) {
        console.log(`\x1b[90m${m.created_at}\x1b[0m \x1b[36m${m.sender}\x1b[0m: ${m.content}`);
        lastId = m.id;
      }
    };

    setInterval(poll, interval * 1000);
    break;
  }

  case "check": {
    // Used by hooks: checks for unread messages mentioning @name or @all
    const [room, name, sinceStr] = args;
    if (!room || !name || !sinceStr) {
      die("Uso: collab check <room> <name> <since_id>");
    }
    const sinceId = parseInt(sinceStr, 10);
    if (isNaN(sinceId)) die("since_id precisa ser um número");

    const messages = getMessages(room, sinceId, 100) as Array<{
      id: number;
      sender: string;
      content: string;
      created_at: string;
    }>;

    // Filter: messages from others that mention @name or @all
    const relevant = messages.filter(
      (m) =>
        m.sender !== name &&
        (m.content.includes(`@${name}`) || m.content.includes("@all"))
    );

    if (relevant.length === 0) {
      // Exit 0 = no news, hook passes silently
      process.exit(0);
    }

    // Print to both stdout (for hook scripts to capture) and stderr (for Claude Code direct)
    const msg = [
      `[collab] ${relevant.length} mensagem(ns) pra você no room "${room}":\n`,
      ...relevant.map((m) => `[#${m.id}] ${m.sender}: ${m.content}\n`),
      "Leia e responda com get_messages/send_message antes de continuar.",
    ].join("\n");
    process.stdout.write(msg + "\n");
    process.stderr.write(msg + "\n");
    process.exit(2);
    break;
  }

  default:
    console.log(USAGE);
    break;
}
