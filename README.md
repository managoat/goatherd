# goatherd

Run coding agents in remote [Sprites](https://sprites.dev) sandboxes from your
terminal. No server, account, or database of its own.

```console
goatherd "find the flaky test and explain it" \
  --repo https://github.com/you/your-repo
```

Files, Git, and tools stay in the sandbox. Runs persist for follow-up turns.

## Install

```console
brew install elixir
git clone https://github.com/managoat/goatherd
cd goatherd
mix deps.get && mix escript.build
./goatherd doctor
```

Goatherd uses `SPRITES_TOKEN` or your Sprites CLI login, plus the appropriate
inference API key or your Claude Code login.

## Use

```console
goatherd "review this repository" -r https://github.com/you/your-repo
goatherd say <id> "now fix the issues"
goatherd logs <id>
goatherd rm <id>
```

Run `goatherd init` to create an optional `.goatherd.yml`:

```yaml
runtime: claude # claude | codex | gemini | opencode
model: anthropic/claude-opus-4-1
repos:
  - url: https://github.com/you/your-repo
packages:
  apt: [ripgrep]
setup: cd your-repo && mix deps.get
secrets: [GITHUB_TOKEN]
permissions:
  default: auto_allow
  execute: ask
```

Goatherd finds this file by walking up from the current directory. Secret names
are safe to commit; their values are copied from your environment.

## Commands

| Command | Action |
|---|---|
| `goatherd "<prompt>"` | Start a run |
| `goatherd say <id> "<prompt>"` | Continue a run |
| `goatherd attach <id>` | Rejoin an active turn |
| `goatherd ps` | List runs |
| `goatherd logs <id>` | Replay a transcript |
| `goatherd rm <id>` / `--all` | Destroy sandboxes |
| `goatherd doctor` | Check credentials and connectivity |

See `goatherd --help` for options.

Sandboxes cost money and are not cleaned up automatically. Use `--rm` for
one-shot runs or `goatherd rm --all` when finished. Turns are driven from your
terminal; use `--yes` if a run will be unattended.

Built on
[`managoat_sandbox`](https://github.com/managoat/managoat_sandbox),
[`managoat_runtimes`](https://github.com/managoat/managoat_runtimes), and
[`managoat_acp`](https://github.com/managoat/managoat_acp). Apache-2.0.
