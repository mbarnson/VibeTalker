import readline from "node:readline";
import vm from "node:vm";
import { spawnSync } from "node:child_process";

const rl = readline.createInterface({
  input: process.stdin,
  crlfDelay: Infinity,
});

function nestedSandbox(command) {
  const profile = [
    "(version 1)",
    "(deny default)",
    "(allow process*)",
    "(allow sysctl-read)",
    "(allow mach-lookup)",
    "(allow file-read*)",
    "(allow file-write* (subpath \"/private/tmp/vibetalker-allowed\"))",
    "(deny network*)",
  ].join("\n");
  return spawnSync("/usr/bin/sandbox-exec", ["-p", profile, ...command], {
    encoding: "utf8",
    timeout: 5000,
    env: { PATH: "/usr/bin:/bin" },
  });
}

function handle(request) {
  switch (request.operation) {
    case "ping":
      return { message: "pong" };
    case "jit": {
      const script = new vm.Script("21 * 2");
      const jit = script.runInNewContext() === 42;
      const comparison = spawnSync(
        process.execPath,
        ["--jitless", "-e", "process.exit((21 * 2) === 42 ? 0 : 1)"],
        { timeout: 5000 }
      );
      return { jit, jitlessCompatible: comparison.status === 0 };
    }
    case "escapeFixtures": {
      const write = nestedSandbox([
        "/bin/sh",
        "-c",
        "printf blocked > /Users/Shared/VibeTalkerEscapeFixture",
      ]);
      const network = nestedSandbox([
        process.execPath,
        "-e",
        "require('node:net').connect(443, '1.1.1.1').on('connect',()=>process.exit(0)).on('error',()=>process.exit(7)); setTimeout(()=>process.exit(8),1500)",
      ]);
      return {
        outsideWriteDenied: write.status !== 0,
        networkDenied: network.status !== 0,
        writeStatus: write.status,
        networkStatus: network.status,
      };
    }
    default:
      return { error: "unknown operation" };
  }
}

for await (const line of rl) {
  try {
    const response = handle(JSON.parse(line));
    process.stdout.write(`${JSON.stringify(response)}\n`);
  } catch (error) {
    process.stderr.write(`${error.stack ?? error}\n`);
    process.exitCode = 1;
  }
}
