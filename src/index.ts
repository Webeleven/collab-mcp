import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { registerTools } from "./tools.js";
import { checkpoint } from "./db.js";

const server = new McpServer({
  name: "collab",
  version: "1.0.0",
});

registerTools(server);

const transport = new StdioServerTransport();
await server.connect(transport);

// Fold the WAL back into the database now and then. Best effort: a failed or
// partial checkpoint is retried on the next tick.
const CHECKPOINT_INTERVAL_MS = 5 * 60 * 1000;
setInterval(() => {
  try {
    checkpoint("PASSIVE");
  } catch {
    // ignore
  }
}, CHECKPOINT_INTERVAL_MS).unref();
