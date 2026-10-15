# Changelog

## Unreleased

- `Managoat.Sandbox`, `Managoat.Runtimes` and `Managoat.ACP` are vendored into
  `lib/managoat/` from the final releases of their archived repositories
  (managoat_sandbox 0.5.6, managoat_runtimes 0.5.7, managoat_acp 0.6.0)
  instead of being hex dependencies. That moves goatherd off 0.2.1 / 0.2.1 /
  0.1.2 and onto every fix shipped since. The Sprites adapter is the only
  sandbox kept; E2B, Daytona and the OpenTelemetry tracer were left out. The
  libraries' tests come with them, and their test fakes live in
  `test/support/`.

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
