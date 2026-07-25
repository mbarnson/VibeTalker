import { spawn } from "node:child_process";
import { existsSync, realpathSync } from "node:fs";
import { dirname, isAbsolute, relative, resolve, sep } from "node:path";
import {
  type BashOperations,
  createBashTool,
  createEditTool,
  createFindTool,
  createGrepTool,
  createLsTool,
  createReadTool,
  createWriteTool,
  type ExtensionAPI,
} from "@earendil-works/pi-coding-agent";

const workspace = realpathSync.native(process.cwd());
const toolManifest = ["read", "bash", "edit", "write", "grep", "find", "ls"] as const;

function nearestExistingPath(path: string): string {
  let candidate = path;
  while (!existsSync(candidate)) {
    const parent = dirname(candidate);
    if (parent === candidate) break;
    candidate = parent;
  }
  return realpathSync.native(candidate);
}

function resolveInsideWorkspace(rawPath: string): string {
  const absolute = isAbsolute(rawPath) ? resolve(rawPath) : resolve(workspace, rawPath);
  const existingAncestor = nearestExistingPath(absolute);
  const ancestorRelative = relative(workspace, existingAncestor);
  if (
    ancestorRelative === ".." ||
    ancestorRelative.startsWith(`..${sep}`) ||
    isAbsolute(ancestorRelative)
  ) {
    throw new Error(`Path is outside the VibeTalker workspace: ${rawPath}`);
  }
  if (existsSync(absolute)) {
    const resolvedTarget = realpathSync.native(absolute);
    const targetRelative = relative(workspace, resolvedTarget);
    if (
      targetRelative === ".." ||
      targetRelative.startsWith(`..${sep}`) ||
      isAbsolute(targetRelative)
    ) {
      throw new Error(`Path resolves outside the VibeTalker workspace: ${rawPath}`);
    }
  }
  return absolute;
}

function fixedSandboxProfile(): string {
  const escapedWorkspace = workspace.replaceAll("\\", "\\\\").replaceAll('"', '\\"');
  return [
    "(version 1)",
    "(deny default)",
    "(allow process*)",
    "(allow sysctl-read)",
    "(allow mach-lookup)",
    "(allow file-read*)",
    `(allow file-write* (subpath "${escapedWorkspace}") (subpath "/private/tmp"))`,
    "(deny network*)",
  ].join("\n");
}

function sandboxedBashOperations(): BashOperations {
  return {
    async exec(command, cwd, { onData, signal, timeout }) {
      resolveInsideWorkspace(cwd);
      return new Promise((resolvePromise, reject) => {
        const child = spawn(
          "/usr/bin/sandbox-exec",
          ["-p", fixedSandboxProfile(), "/bin/zsh", "--no-rcs", "-c", command],
          {
            cwd: workspace,
            detached: true,
            env: { HOME: workspace, PATH: "/usr/bin:/bin", TMPDIR: "/private/tmp" },
            stdio: ["ignore", "pipe", "pipe"],
          },
        );
        let timedOut = false;
        const timeoutHandle =
          timeout && timeout > 0
            ? setTimeout(() => {
                timedOut = true;
                if (child.pid) process.kill(-child.pid, "SIGKILL");
              }, timeout * 1000)
            : undefined;
        const abort = () => {
          if (child.pid) process.kill(-child.pid, "SIGKILL");
        };
        signal?.addEventListener("abort", abort, { once: true });
        child.stdout.on("data", onData);
        child.stderr.on("data", onData);
        child.on("error", reject);
        child.on("close", (code) => {
          if (timeoutHandle) clearTimeout(timeoutHandle);
          signal?.removeEventListener("abort", abort);
          if (signal?.aborted) reject(new Error("aborted"));
          else if (timedOut) reject(new Error(`timeout:${timeout}`));
          else resolvePromise({ exitCode: code });
        });
      });
    },
  };
}

export default function vibetalkerToolPolicy(pi: ExtensionAPI) {
  const pathTools = [
    { tool: createReadTool(workspace), keys: ["path"] },
    { tool: createEditTool(workspace), keys: ["path"] },
    { tool: createWriteTool(workspace), keys: ["path"] },
    { tool: createGrepTool(workspace), keys: ["path"] },
    { tool: createFindTool(workspace), keys: ["path"] },
    { tool: createLsTool(workspace), keys: ["path"] },
  ] as const;

  for (const { tool, keys } of pathTools) {
    pi.registerTool({
      ...tool,
      async execute(id, params, signal, onUpdate) {
        for (const key of keys) {
          const value = (params as Record<string, unknown>)[key];
          if (typeof value === "string") resolveInsideWorkspace(value);
        }
        return tool.execute(id, params as never, signal, onUpdate);
      },
    });
  }

  pi.registerTool(
    createBashTool(workspace, { operations: sandboxedBashOperations() }),
  );

  pi.on("session_start", (_event, context) => {
    const actual = new Set(pi.getAllTools().map((tool) => tool.name));
    const missing = toolManifest.filter((name) => !actual.has(name));
    const unknown = [...actual].filter(
      (name) => !toolManifest.includes(name as (typeof toolManifest)[number]),
    );
    if (missing.length || unknown.length) {
      throw new Error(
        `VibeTalker tool manifest mismatch; missing=${missing.join(",")} unknown=${unknown.join(",")}`,
      );
    }
    context.ui.setStatus(
      "vibetalker-policy",
      `Workspace-only tools active: ${toolManifest.join(", ")}`,
    );
  });
}
