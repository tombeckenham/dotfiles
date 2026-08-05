/**
 * ghsb Cloudflare Sandbox Worker (Architecture A)
 *
 * Provisions an isolated container per session: clone branch, install deps,
 * start dev server, expose preview URL. Coding agents run in Herdr locally;
 * this is the remote compute for preview/dev links.
 *
 * Endpoints:
 *   POST   /sessions          { id, repo, branch, issue }
 *   GET    /sessions/:id
 *   DELETE /sessions/:id
 *   POST   /sessions/:id/exec { command }
 */

import { getSandbox, proxyToSandbox, type Sandbox } from "@cloudflare/sandbox";

export { Sandbox } from "@cloudflare/sandbox";

export interface Env {
  Sandbox: DurableObjectNamespace<Sandbox>;
  GHSB_API_TOKEN?: string;
  GITHUB_TOKEN?: string;
  DEV_PORT?: string;
}

type CreateBody = {
  id: string;
  repo: string;
  branch: string;
  issue?: number;
  installCommand?: string;
  devCommand?: string;
  port?: number;
};

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data, null, 2), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function unauthorized(): Response {
  return json({ error: "unauthorized" }, 401);
}

function checkAuth(request: Request, env: Env): boolean {
  if (!env.GHSB_API_TOKEN) return true;
  const header = request.headers.get("Authorization") || "";
  const token = header.startsWith("Bearer ") ? header.slice(7) : "";
  return token === env.GHSB_API_TOKEN;
}

function detectInstallAndDev(packageJson: string | null): {
  install: string;
  dev: string;
} {
  if (!packageJson) {
    return { install: "echo 'no package.json'", dev: "echo 'no dev server'" };
  }
  let pkg: { scripts?: Record<string, string>; packageManager?: string } = {};
  try {
    pkg = JSON.parse(packageJson);
  } catch {
    return { install: "npm install", dev: "npm run dev -- --host 0.0.0.0" };
  }
  const scripts = pkg.scripts || {};
  const has = (n: string) => Boolean(scripts[n]);

  // Prefer lockfile-agnostic detection via packageManager field later; try common cmds.
  const install = "npm install";
  let dev = "npm run dev -- --host 0.0.0.0 --port 3000";
  if (has("dev")) dev = "npm run dev -- --host 0.0.0.0 --port 3000";
  else if (has("start")) dev = "npm run start -- --host 0.0.0.0 --port 3000";
  else if (has("preview")) dev = "npm run preview -- --host 0.0.0.0 --port 3000";

  return { install, dev };
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    // Required for CF sandbox preview URL routing
    const proxyResponse = await proxyToSandbox(request, env);
    if (proxyResponse) return proxyResponse;

    const url = new URL(request.url);
    const path = url.pathname.replace(/\/$/, "") || "/";

    // Health (unauthenticated)
    if (path === "/" || path === "/health") {
      return json({ ok: true, service: "ghsb-sandbox" });
    }

    if (!checkAuth(request, env)) return unauthorized();

    // POST /sessions
    if (path === "/sessions" && request.method === "POST") {
      let body: CreateBody;
      try {
        body = (await request.json()) as CreateBody;
      } catch {
        return json({ error: "invalid json" }, 400);
      }
      if (!body.id || !body.repo || !body.branch) {
        return json({ error: "id, repo, branch required" }, 400);
      }

      const sandbox = getSandbox(env.Sandbox, body.id);
      const port = body.port ?? Number(env.DEV_PORT || 3000);
      const cloneUrl = env.GITHUB_TOKEN
        ? `https://x-access-token:${env.GITHUB_TOKEN}@github.com/${body.repo}.git`
        : `https://github.com/${body.repo}.git`;

      // Fresh workspace
      await sandbox.exec("rm -rf /workspace/repo && mkdir -p /workspace/repo");

      const clone = await sandbox.exec(
        `git clone --depth 1 --branch ${shellQuote(body.branch)} ${shellQuote(cloneUrl)} /workspace/repo`,
      );
      if (!clone.success) {
        // Branch might need full fetch
        const cloneDefault = await sandbox.exec(
          `git clone --depth 50 ${shellQuote(cloneUrl)} /workspace/repo && cd /workspace/repo && git checkout ${shellQuote(body.branch)}`,
        );
        if (!cloneDefault.success) {
          return json(
            {
              error: "clone failed",
              stdout: clone.stdout,
              stderr: clone.stderr + "\n" + cloneDefault.stderr,
            },
            500,
          );
        }
      }

      // Detect package manager from lockfiles
      const ls = await sandbox.exec(
        "ls -la /workspace/repo && test -f /workspace/repo/package.json && cat /workspace/repo/package.json || true",
      );
      const hasBun = (await sandbox.exec("test -f /workspace/repo/bun.lockb -o -f /workspace/repo/bun.lock")).success;
      const hasPnpm = (await sandbox.exec("test -f /workspace/repo/pnpm-lock.yaml")).success;
      const hasYarn = (await sandbox.exec("test -f /workspace/repo/yarn.lock")).success;

      let install = body.installCommand;
      let dev = body.devCommand;
      if (!install || !dev) {
        const detected = detectInstallAndDev(
          ls.stdout.includes("{") ? ls.stdout.slice(ls.stdout.indexOf("{")) : null,
        );
        if (!install) {
          if (hasBun) install = "cd /workspace/repo && bun install";
          else if (hasPnpm) install = "cd /workspace/repo && corepack enable && pnpm install";
          else if (hasYarn) install = "cd /workspace/repo && yarn install";
          else install = `cd /workspace/repo && ${detected.install}`;
        }
        if (!dev) {
          if (hasBun) dev = `cd /workspace/repo && bun run dev -- --host 0.0.0.0 --port ${port}`;
          else if (hasPnpm)
            dev = `cd /workspace/repo && pnpm dev --host 0.0.0.0 --port ${port}`;
          else dev = `cd /workspace/repo && ${detected.dev.replace("3000", String(port))}`;
        }
      }

      const installResult = await sandbox.exec(install, { timeout: 300_000 });
      if (!installResult.success) {
        return json(
          {
            error: "install failed",
            command: install,
            stdout: installResult.stdout,
            stderr: installResult.stderr,
          },
          500,
        );
      }

      // Start dev server as background process
      await sandbox.startProcess(dev);

      // Wait briefly for bind
      await sandbox.exec("sleep 3");

      let previewUrl = "";
      let devUrl = "";
      try {
        const exposed = await sandbox.exposePort(port, { hostname: url.hostname });
        // SDK shapes vary slightly across versions
        const exposedAny = exposed as { url?: string; exposedAt?: string; previewUrl?: string };
        previewUrl = exposedAny.url || exposedAny.exposedAt || exposedAny.previewUrl || "";
        devUrl = previewUrl;
      } catch (e) {
        // Preview exposure may fail on local dev without tunnel support
        previewUrl = "";
        devUrl = `sandbox://${body.id}:${port}`;
      }

      let terminalUrl = "";
      try {
        // Some SDK versions expose terminal helper paths via worker route
        terminalUrl = `${url.origin}/sessions/${encodeURIComponent(body.id)}/terminal`;
      } catch {
        /* ignore */
      }

      return json({
        id: body.id,
        sandboxId: body.id,
        repo: body.repo,
        branch: body.branch,
        issue: body.issue ?? null,
        previewUrl,
        devUrl,
        terminalUrl,
        port,
        install,
        dev,
      });
    }

    // GET /sessions/:id
    const sessionMatch = path.match(/^\/sessions\/([^/]+)$/);
    if (sessionMatch && request.method === "GET") {
      const id = decodeURIComponent(sessionMatch[1]);
      const sandbox = getSandbox(env.Sandbox, id);
      const pwd = await sandbox.exec("pwd && ls /workspace/repo 2>/dev/null | head -20");
      return json({
        id,
        sandboxId: id,
        alive: pwd.success,
        stdout: pwd.stdout,
      });
    }

    // DELETE /sessions/:id
    if (sessionMatch && request.method === "DELETE") {
      const id = decodeURIComponent(sessionMatch[1]);
      const sandbox = getSandbox(env.Sandbox, id);
      try {
        await sandbox.destroy();
      } catch {
        await sandbox.exec("rm -rf /workspace/repo");
      }
      return json({ ok: true, id });
    }

    // POST /sessions/:id/exec
    const execMatch = path.match(/^\/sessions\/([^/]+)\/exec$/);
    if (execMatch && request.method === "POST") {
      const id = decodeURIComponent(execMatch[1]);
      const { command } = (await request.json()) as { command?: string };
      if (!command) return json({ error: "command required" }, 400);
      const sandbox = getSandbox(env.Sandbox, id);
      const result = await sandbox.exec(command, { timeout: 120_000 });
      return json({
        stdout: result.stdout,
        stderr: result.stderr,
        exitCode: result.exitCode,
        success: result.success,
      });
    }

    // WebSocket terminal passthrough
    const termMatch = path.match(/^\/sessions\/([^/]+)\/terminal$/);
    if (termMatch && request.headers.get("Upgrade")?.toLowerCase() === "websocket") {
      const id = decodeURIComponent(termMatch[1]);
      const sandbox = getSandbox(env.Sandbox, id);
      return sandbox.terminal(request, { cols: 120, rows: 40 });
    }

    return json({ error: "not found", path }, 404);
  },
};

function shellQuote(s: string): string {
  return `'${s.replace(/'/g, `'\\''`)}'`;
}
