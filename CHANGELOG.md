# Changelog

## 0.1.0

First release.

- `goatherd "<prompt>"` provisions a Sprites sandbox, installs the runtime's
  ACP adapter, drives one turn and renders it to the terminal.
- `say`, `attach`, `ps`, `logs`, `rm`, `doctor`, `init`.
- Credentials are read from the workstation's existing logins — the sprites
  CLI's keychain item and Claude Code's — with environment variables taking
  precedence.
- `.goatherd.yml`: runtime, model, system prompt, packages, repositories,
  setup script, environment, named secrets and a permission policy.
- `GOATHERD_TRACE` records both directions of the ACP conversation.

Verified live against Sprites on the `claude` runtime.
