# ghsb Cloudflare Sandbox

Isolated preview/dev environments for [Architecture A](../README.md#ghsb).

Coding agents run in **Herdr** on your machine (Ghostty). This Worker clones the PR branch into a Cloudflare Sandbox container, installs deps, starts the dev server, and returns **preview/dev URLs** used by `ghsb finish` (Playwright video + review links).

## Setup

```sh
cd sandbox
npm install
# Docker must be running for deploy (builds the container image)
npx wrangler login
npx wrangler secret put GHSB_API_TOKEN   # optional but recommended
npx wrangler secret put GITHUB_TOKEN     # for private repos
npm run deploy
```

Export the Worker URL:

```sh
# e.g. in ~/.zshrc
export GHSB_API_URL="https://ghsb-sandbox.<you>.workers.dev"
export GHSB_API_TOKEN="…"   # same value as the secret
```

## Local dev

```sh
npm run dev
# Docker required; first boot builds the image
export GHSB_API_URL="http://127.0.0.1:8787"
```

## API

| Method | Path | Body | Purpose |
|--------|------|------|---------|
| POST | `/sessions` | `{ id, repo, branch, issue? }` | Clone, install, start dev, expose port |
| GET | `/sessions/:id` | | Health / listing |
| DELETE | `/sessions/:id` | | Destroy sandbox |
| POST | `/sessions/:id/exec` | `{ command }` | Run shell command |
| WS | `/sessions/:id/terminal` | | Browser terminal |

## Wire to CLI

```sh
ghsb --cf "Add dark mode"
# or after GHSB_API_URL is set:
ghsb --cf -i 42
ghsb finish
```
