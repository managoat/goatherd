# goatherd

Run coding agents in remote sandboxes, from your terminal. No server, no
account, no database.

```console
$ goatherd "find the flaky test in this suite and explain why it flakes" \
    --repo https://github.com/you/your-repo
run k3mo36wcsnsma · claude · sandbox goatherd-k3mo36wcsnsma
  · sandbox… ok
  · packages… ok
  · clone… ok
  · adapter… ok
  ⚒ Terminal  mix test --seed 0
  ⚒ Read File test/worker_test.exs
The flake is in `test/worker_test.exs:42` …
```

Every file, every `git`, every compiler runs on the remote machine. Your
laptop holds three things: a Sprites token, an inference credential, and a
small pointer file naming the sandboxes it started.

## Why this exists

[Fountain](https://github.com/BinaryBourbon/fountain) runs coding agents in
sandboxes as a hosted service — accounts, a database, billing, a web UI, a
fleet of workers keeping turns alive. Underneath that service is a stack of
Apache-2.0 libraries that carry the actual work:
[`managoat_sandbox`](https://github.com/managoat/managoat_sandbox) (the
machine), [`managoat_runtimes`](https://github.com/managoat/managoat_runtimes)
(getting a coding agent into it, speaking ACP) and
[`managoat_acp`](https://github.com/managoat/managoat_acp) (the protocol
conversation).

goatherd is what is left when you keep those three and delete the service. It
is a single binary that does the provisioning and turn-driving a server used
to do, and it is roughly a thousand lines, because the libraries are the
product and this is the control plane.

## Install

```console
brew install elixir            # an Erlang runtime is all the binary needs
git clone https://github.com/managoat/goatherd && cd goatherd
mix deps.get && mix escript.build
./goatherd doctor
```

## Credentials are found, not configured

```console
$ goatherd doctor
goatherd 0.1.0
  sprites token: ~/.sprites + login keychain (117 bytes)
  inference claude_code_oauth_token: present (108 bytes)
  herd file: none (using defaults)
  sprites reachable: 12 sandboxes on the account
```

If you already run the `sprites` CLI and Claude Code on this machine,
goatherd needs nothing configured: both keep their credentials in the login
keychain and it reads them there. Environment variables win when set, so CI
sets `SPRITES_TOKEN` and `ANTHROPIC_API_KEY` and behaves identically.

Using the Claude Code login means turns bill the Claude.ai subscription this
machine is signed in to. goatherd holds no credential of its own and meters
nothing, because it never sits between you and either vendor.

## The herd file

Everything is optional. `goatherd init` writes a commented one.

```yaml
# .goatherd.yml
runtime: claude              # claude | codex | gemini | opencode
model: anthropic/claude-opus-4-1
system: You are reviewing a Phoenix umbrella. Be terse.

repos:
  - url: https://github.com/you/your-repo

packages:
  apt: [ripgrep]

setup: |
  cd your-repo && mix deps.get

# Named, never valued — so this file is safe to commit. goatherd copies
# these out of your shell into the sandbox.
secrets: [GITHUB_TOKEN]

permissions:
  default: auto_allow
  execute: ask
```

It is found by walking up from the working directory, so a repo can carry its
own agent the way it carries its own CI config.

## Commands

| | |
|---|---|
| `goatherd "<prompt>"` | start a run in a fresh sandbox |
| `goatherd say <id> "<prompt>"` | another turn — the agent keeps its context |
| `goatherd attach <id>` | rejoin a turn still in flight |
| `goatherd ps` | runs, and whether their sandbox is still up |
| `goatherd logs <id>` | replay a transcript |
| `goatherd rm <id>` / `--all` | destroy sandboxes and forget the runs |
| `goatherd doctor` | what it found, and whether Sprites answers |

`--yes` auto-answers permission requests, `--rm` destroys the sandbox when the
turn ends, `-r/--repo` clones one without a herd file.

## What it is for, and what it is not

A turn runs in the sandbox but is **driven from your terminal**. Close the
laptop and nothing is consuming the agent's output; a permission request
nobody answers is denied when it times out. goatherd is for turns you watch.

That is the honest boundary. `goatherd attach` rejoins a turn whose driver was
interrupted — the adapter is spawned as a detachable session, so it keeps
running remotely — and an unattended run wants `--yes`. But if you want agents
that work while you sleep, that other people can watch, that answer email or
run on a schedule, you want a server, and Fountain is that server.

**Sandboxes cost money and goatherd will not clean up after you.** There is no
reaper, no fleet ceiling and no credit gate — those are things the hosted
service has and this deliberately does not. A run keeps its sandbox so the
next `say` is instant. `goatherd ps` shows what is up; `goatherd rm --all`
takes it all down.

## Debugging

`GOATHERD_TRACE=/tmp/wire.log` records both directions of the ACP conversation.
The render path drops everything that is not a block, which is most of what
goes wrong. `GOATHERD_LOG=debug` turns the libraries' own logs back on.

## Status

Built and verified live against Sprites with the `claude` runtime: fresh
sandbox, package install, `git clone`, tool use, streamed output, a second
turn resuming the agent's session from a separate invocation, `attach` after
killing a driver mid-turn, and teardown. The other three runtimes reach the
same code path through the same library and are not yet exercised here.

Apache-2.0.
