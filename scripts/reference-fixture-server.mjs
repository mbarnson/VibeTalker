#!/usr/bin/env node

import { createServer } from "node:http";

const host = "127.0.0.1";
const port = Number.parseInt(process.env.VIBETALKER_FIXTURE_PORT ?? "8002", 10);
const reference =
  process.env.VIBETALKER_FIXTURE_REFERENCE ??
  "The VibeTalker Gate 1 reference fixture says the verification word is cobalt.";

const server = createServer((request, response) => {
  if (request.method !== "POST" || request.url !== "/v1/chat/completions") {
    response.writeHead(404, { "content-type": "application/json" });
    response.end(JSON.stringify({ error: "not found" }));
    return;
  }

  let body = "";
  request.setEncoding("utf8");
  request.on("data", (chunk) => {
    body += chunk;
  });
  request.on("end", () => {
    try {
      const payload = JSON.parse(body);
      const model =
        typeof payload.model === "string" ? payload.model : "gate1-fixture";
      response.writeHead(200, { "content-type": "application/json" });
      response.end(
        JSON.stringify({
          id: "vibetalker-gate1-fixture",
          object: "chat.completion",
          created: Math.floor(Date.now() / 1000),
          model,
          choices: [
            {
              index: 0,
              message: { role: "assistant", content: reference },
              finish_reason: "stop",
            },
          ],
          usage: {
            prompt_tokens: 0,
            completion_tokens: 0,
            total_tokens: 0,
          },
        }),
      );
    } catch (error) {
      response.writeHead(400, { "content-type": "application/json" });
      response.end(JSON.stringify({ error: String(error) }));
    }
  });
});

server.listen(port, host, () => {
  console.log(`Reference fixture listening on http://${host}:${port}/v1`);
});
