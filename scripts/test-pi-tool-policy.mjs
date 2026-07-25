#!/usr/bin/env node

import assert from "node:assert/strict";
import {
  mkdtemp,
  readFile,
  rm,
  symlink,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const repoRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const policyPath = join(
  repoRoot,
  "Vendor",
  "pi-mono",
  "vibetalker-tool-policy.ts",
);
const workspace = await mkdtemp(join(tmpdir(), "vibetalker-policy-workspace-"));
const outsideRoot = "/private/var/tmp";
const outsideFile = join(outsideRoot, `vibetalker-policy-${process.pid}.txt`);

process.chdir(workspace);

const registeredTools = new Map();
const handlers = new Map();
const statuses = [];
const api = {
  registerTool(tool) {
    registeredTools.set(tool.name, tool);
  },
  on(event, handler) {
    handlers.set(event, handler);
  },
  getAllTools() {
    return [...registeredTools.values()];
  },
};

try {
  const policyModule = await import(pathToFileURL(policyPath));
  policyModule.default(api);

  assert.deepEqual(
    [...registeredTools.keys()].sort(),
    ["bash", "edit", "find", "grep", "ls", "read", "write"],
    "the extension must expose exactly the pinned seven-tool manifest",
  );

  const sessionStart = handlers.get("session_start");
  assert.equal(typeof sessionStart, "function");
  sessionStart({}, {
    ui: {
      setStatus(key, value) {
        statuses.push({ key, value });
      },
    },
  });
  assert.match(statuses[0]?.value ?? "", /read, bash, edit, write, grep, find, ls/);

  const write = registeredTools.get("write");
  await write.execute(
    "inside-write",
    { path: "inside.txt", content: "inside\n" },
    undefined,
    () => {},
  );
  assert.equal(await readFile(join(workspace, "inside.txt"), "utf8"), "inside\n");

  await assert.rejects(
    write.execute(
      "outside-write",
      { path: outsideFile, content: "escape\n" },
      undefined,
      () => {},
    ),
    /outside the VibeTalker workspace/,
  );

  await symlink(outsideRoot, join(workspace, "outside-link"));
  await assert.rejects(
    write.execute(
      "symlink-write",
      { path: "outside-link/escape.txt", content: "escape\n" },
      undefined,
      () => {},
    ),
    /outside the VibeTalker workspace/,
  );

  const bash = registeredTools.get("bash");
  await bash.execute(
    "inside-bash",
    { command: "printf 'shell-inside\\n' > shell-inside.txt" },
    undefined,
    () => {},
  );
  assert.equal(
    await readFile(join(workspace, "shell-inside.txt"), "utf8"),
    "shell-inside\n",
  );

  await assert.rejects(
    bash.execute(
      "outside-bash",
      { command: `printf 'escape\\n' > ${JSON.stringify(outsideFile)}` },
      undefined,
      () => {},
    ),
    /Command exited with code/,
  );

  await assert.rejects(
    bash.execute(
      "network-bash",
      { command: "/usr/bin/nc -z -w 1 1.1.1.1 443" },
      undefined,
      () => {},
    ),
    /Command exited with code/,
  );

  console.log(JSON.stringify({
    status: "passed",
    tools: [...registeredTools.keys()],
    workspace,
    checks: [
      "manifest",
      "inside-file-write",
      "outside-file-write-denied",
      "symlink-escape-denied",
      "inside-command-write",
      "outside-command-write-denied",
      "command-network-denied",
    ],
  }));
} finally {
  await rm(workspace, { recursive: true, force: true });
  await rm(outsideFile, { force: true });
}
