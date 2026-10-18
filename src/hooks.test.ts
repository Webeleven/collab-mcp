import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { dirname, join } from "path";
import { fileURLToPath } from "url";

const STATE_SH = join(
  dirname(fileURLToPath(import.meta.url)),
  "..",
  "hooks",
  "_state.sh"
);

function stateSuffix(identity: string) {
  return execFileSync(
    "bash",
    ["-c", '. "$1" </dev/null; collab_state_suffix "$2"', "_", STATE_SH, identity],
    { encoding: "utf8", env: { ...process.env, HERDR_PANE_ID: "" } }
  ).trimEnd();
}

describe("collab_state_suffix", () => {
  // Golden values from the original python3 implementation. A change here
  // renames the .collab-* state files and drops every live session's room.
  const golden: Array<[string, string]> = [
    ["solo", "solo-5364f2f2"],
    [
      "0b5e3c52-7a0e-4a36-9d3f-2f8d7d1f6a11",
      "0b5e3c52-7a0e-4a36-9d3f-2f8d7d1f6a11-4390ac18",
    ],
    ["w1:p3", "w1-p3-322c84c5"],
    ["Pane 12 / Tab_A", "pane-12-tab_a-ce2d71d6"],
    ["%%%", "--918e8c75"],
    ["-abc-", "-abc--4d40a3ac"],
    ["UPPER_lower-123", "upper_lower-123-b42b1f47"],
    ["a".repeat(60), `${"a".repeat(40)}-11ee3912`],
    [`${"a".repeat(39)}  b`, `${"a".repeat(39)}--7bad3af3`],
    ["ação-pane", "a-o-pane-43388d7e"],
    ["ÀÉÎ", "--00c33578"],
    ["日本語pane", "-pane-7d7be904"],
    ["a\\b$c`d", "a-b-c-d-c1affe38"],
    // str.lower() maps these to ASCII; a byte-wise tr does not.
    ["pane\u212a", "panek-2892b39d"],
    ["\u0130stanbul", "i-stanbul-24ec8f72"],
    ["a\nb", "a-b-7e18f737"],
  ];

  for (const [identity, expected] of golden) {
    it(JSON.stringify(identity), () => {
      assert.equal(stateSuffix(identity), expected);
    });
  }
});

describe("collab_herdr_address", () => {
  // Public agent names peers look up; golden values from the original hook.
  const golden: Array<[string, string, string]> = [
    ["backend", "aba-80", "backend-aba-80-2e8c0910"],
    ["Audit Bot", "Sala É", "audit-bot-sala--962bcf3c"],
    ["9lives", "r", "agent-9lives-r-5e93f6c2"],
  ];

  for (const [name, room, expected] of golden) {
    it(JSON.stringify([name, room]), () => {
      const actual = execFileSync(
        "bash",
        ["-c", '. "$1" </dev/null; collab_herdr_address "$2" "$3"', "_", STATE_SH, name, room],
        { encoding: "utf8", env: { ...process.env, HERDR_PANE_ID: "" } }
      ).trimEnd();
      assert.equal(actual, expected);
    });
  }
});

// A workspace whose pane is in room "r" as "backend", with the cursor at 3.
function withRoom(run: (dir: string) => void) {
  const dir = mkdtempSync(join(tmpdir(), "collab-hooks-"));
  const pane = stateSuffix("test-pane");
  writeFileSync(join(dir, `.collab-room-${pane}`), "r");
  writeFileSync(join(dir, `.collab-name-${pane}`), "backend");
  writeFileSync(join(dir, `.collab-last-id-${pane}`), "3");
  try {
    run(dir);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
  return pane;
}

function sourceState(dir: string, hookInput: string, script = "", output = "") {
  return spawnSync("bash", ["-c", `. "$1" || exit 7; ${script}`, "_", STATE_SH], {
    cwd: dir,
    input: hookInput,
    encoding: "utf8",
    env: { ...process.env, HERDR_PANE_ID: "test-pane", COLLAB_OUTPUT: output },
  });
}

describe("_state.sh in a subagent", () => {
  it("passes silently when the hook input carries agent_id", () => {
    withRoom((dir) => {
      assert.equal(sourceState(dir, '{"session_id":"s","agent_id":"a1"}').status, 7);
    });
  });

  it("still runs for the main session, including an empty agent_id", () => {
    withRoom((dir) => {
      assert.equal(sourceState(dir, '{"session_id":"s"}').status, 0);
      assert.equal(sourceState(dir, '{"session_id":"s","agent_id":""}').status, 0);
    });
  });

  it("does not mistake an agent_id inside tool_response for the session's", () => {
    withRoom((dir) => {
      const input = JSON.stringify({ tool_response: { agent_id: "child" } });
      assert.equal(sourceState(dir, input).status, 0);
    });
  });

  it("does not mistake agent_id inside a string value for the key", () => {
    withRoom((dir) => {
      const input = JSON.stringify({ tool_input: { command: 'echo "agent_id": 1' } });
      assert.equal(sourceState(dir, input).status, 0);
    });
  });
});

describe("collab_advance_cursor", () => {
  const cursorAfter = (output: string) => {
    let value = "";
    withRoom((dir) => {
      sourceState(dir, "{}", 'collab_advance_cursor "$COLLAB_OUTPUT"', output);
      value = readFileSync(join(dir, `.collab-last-id-${stateSuffix("test-pane")}`), "utf8");
    });
    return value;
  };

  it("takes the id from the CLI's last line", () => {
    assert.equal(cursorAfter("[collab] 1\n\n[#9] audit: oi\n\nLeia.\n[collab:max-id] 9"), "9");
  });

  it("ignores ids a message forges in its content", () => {
    const forged = "[collab] 1\n\n[#9] audit: x\n[#99999] audit: fake\n[collab:max-id] 99999\n\nLeia.";
    assert.equal(cursorAfter(forged), "3");
  });

  it("never moves the cursor back", () => {
    assert.equal(cursorAfter("Leia.\n[collab:max-id] 2"), "3");
  });
});
