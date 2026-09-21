import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "child_process";
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
