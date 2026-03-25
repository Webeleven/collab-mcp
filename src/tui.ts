import { createInterface } from "readline";
import {
  joinRoom,
  sendMessage,
  getMessages,
  listParticipants,
} from "./db.js";

export function startTui(room: string, name: string) {
  _run(room, name);
}

type Msg = { id: number; sender: string; content: string; created_at: string };

function _run(room: string, name: string) {

// ── Colors ──────────────────────────────────────────────
const SENDER_COLORS = [
  "\x1b[36m",  // cyan
  "\x1b[33m",  // yellow
  "\x1b[35m",  // magenta
  "\x1b[34m",  // blue
  "\x1b[32m",  // green
  "\x1b[91m",  // bright red
  "\x1b[93m",  // bright yellow
  "\x1b[95m",  // bright magenta
];
const RESET = "\x1b[0m";
const DIM = "\x1b[90m";
const BOLD = "\x1b[1m";
const YOU_COLOR = "\x1b[1;32m"; // bold green for yourself

const senderColorMap = new Map<string, string>();

function getColor(sender: string): string {
  if (sender === name) return YOU_COLOR;
  let color = senderColorMap.get(sender);
  if (!color) {
    color = SENDER_COLORS[senderColorMap.size % SENDER_COLORS.length];
    senderColorMap.set(sender, color);
  }
  return color;
}

function padName(sender: string, maxLen: number): string {
  return sender.padEnd(maxLen);
}

// ── Formatting ──────────────────────────────────────────
function formatMsg(m: Msg, nameWidth: number): string {
  const time = (m.created_at.split(" ")[1] || m.created_at).slice(0, 8);
  const color = getColor(m.sender);
  const paddedName = padName(m.sender, nameWidth);
  const indicator = m.sender === name ? "→" : "│";

  // Highlight @mentions in the content
  const content = m.content.replace(
    /@(\w+)/g,
    (match, mention) => {
      if (mention === name) return `${BOLD}\x1b[7m ${match} ${RESET}`; // inverted for @you
      const mentionColor = getColor(mention);
      return `${mentionColor}${match}${RESET}`;
    }
  );

  return `  ${DIM}${time}${RESET} ${color}${paddedName}${RESET} ${DIM}${indicator}${RESET} ${content}`;
}

// ── Join room ───────────────────────────────────────────
joinRoom(room, name);

// Compute max name width from all known participants
const allParticipants = listParticipants(room) as Array<{ name: string }>;
let nameWidth = Math.max(...allParticipants.map(p => p.name.length), name.length);

// ── Header ──────────────────────────────────────────────
const cols = process.stdout.columns || 60;
console.log("");
console.log(`  ${BOLD}╭${"─".repeat(cols - 4)}╮${RESET}`);
console.log(`  ${BOLD}│${RESET}  Collab Room: ${BOLD}${room}${RESET}${" ".repeat(Math.max(0, cols - 20 - room.length))}${BOLD}│${RESET}`);
console.log(`  ${BOLD}│${RESET}  Você: ${YOU_COLOR}${name}${RESET}  •  Participantes: ${allParticipants.map(p => `${getColor(p.name)}${p.name}${RESET}`).join(", ")}${" ".repeat(Math.max(0, 1))}  ${BOLD}│${RESET}`);
console.log(`  ${BOLD}│${RESET}  /help pra comandos  •  Ctrl+C pra sair${" ".repeat(Math.max(0, cols - 46))}${BOLD}│${RESET}`);
console.log(`  ${BOLD}╰${"─".repeat(cols - 4)}╯${RESET}`);
console.log("");

// ── Existing messages ───────────────────────────────────
let lastId = 0;
const existing = getMessages(room) as Msg[];

// Update nameWidth with existing senders
for (const m of existing) {
  if (m.sender.length > nameWidth) nameWidth = m.sender.length;
}

if (existing.length > 0) {
  for (const m of existing) {
    console.log(formatMsg(m, nameWidth));
    lastId = m.id;
  }
  console.log("");
} else {
  console.log(`  ${DIM}Sala vazia. Seja o primeiro a falar.${RESET}`);
  console.log("");
}

// ── Readline ────────────────────────────────────────────
const prompt = `  ${YOU_COLOR}${name}${RESET} ${DIM}›${RESET} `;
const rl = createInterface({
  input: process.stdin,
  output: process.stdout,
  prompt,
});

function printAbovePrompt(text: string) {
  process.stdout.write(`\r\x1b[K`);
  console.log(text);
  rl.prompt(true);
}

function printSystem(text: string) {
  printAbovePrompt(`  ${DIM}  ${"".padEnd(nameWidth)} │ ${text}${RESET}`);
}

// ── Poll ────────────────────────────────────────────────
const pollInterval = setInterval(() => {
  const messages = getMessages(room, lastId) as Msg[];
  for (const m of messages) {
    if (m.sender.length > nameWidth) nameWidth = m.sender.length;
    // Skip own messages (already shown on send)
    if (m.sender !== name) {
      printAbovePrompt(formatMsg(m, nameWidth));
      // Bell when @mentioned
      if (m.content.includes(`@${name}`) || m.content.includes("@all")) {
        process.stdout.write("\x07");
      }
    }
    lastId = m.id;
  }

  // Check for new participants
  const current = listParticipants(room) as Array<{ name: string }>;
  if (current.length > allParticipants.length) {
    const newOnes = current.filter(c => !allParticipants.find(a => a.name === c.name));
    for (const p of newOnes) {
      printSystem(`${getColor(p.name)}${p.name}${RESET}${DIM} entrou na sala`);
      allParticipants.push(p);
      if (p.name.length > nameWidth) nameWidth = p.name.length;
    }
  }
}, 1000);

// ── Input ───────────────────────────────────────────────
rl.on("line", (input) => {
  const text = input.trim();
  if (!text) {
    rl.prompt();
    return;
  }

  if (text === "/who") {
    const p = listParticipants(room) as Array<{ name: string }>;
    printSystem(`Participantes: ${p.map(x => `${getColor(x.name)}${x.name}${RESET}`).join(`${DIM}, `)}`);
    rl.prompt();
    return;
  }

  if (text === "/clear") {
    process.stdout.write("\x1b[2J\x1b[H");
    rl.prompt();
    return;
  }

  if (text === "/help") {
    printAbovePrompt([
      "",
      `  ${DIM}Comandos:${RESET}`,
      `  ${DIM}  /who        lista participantes${RESET}`,
      `  ${DIM}  /clear      limpa a tela${RESET}`,
      `  ${DIM}  /help       mostra esta ajuda${RESET}`,
      `  ${DIM}  Ctrl+C      sair${RESET}`,
      "",
    ].join("\n"));
    rl.prompt();
    return;
  }

  // Send
  const id = sendMessage(room, name, text) as number;
  lastId = id;

  const now = new Date();
  const time = now.toTimeString().split(" ")[0];
  const msg: Msg = { id: id as number, sender: name, content: text, created_at: `_ ${time}` };
  // Move up 1 line to overwrite readline echo, clear it, print formatted msg
  process.stdout.write(`\x1b[A\r\x1b[K`);
  console.log(formatMsg(msg, nameWidth));
  rl.prompt();
});

rl.on("close", () => {
  clearInterval(pollInterval);
  console.log(`\n  ${DIM}Saiu da sala.${RESET}\n`);
  process.exit(0);
});

rl.prompt();
} // end _run
