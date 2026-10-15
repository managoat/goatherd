# Mimic copies the modules the vendored Managoat.* tests stub or expect on:
# the Sprites SDK and the seams the sandbox facade dispatches through.
Mimic.copy(Managoat.Sandbox)
Mimic.copy(Managoat.Sandbox.Sprites)
Mimic.copy(Managoat.Sandbox.ExecDeadline)
Mimic.copy(Managoat.Sandbox.Sprites.Client)
Mimic.copy(Sprites)
Mimic.copy(Sprites.Filesystem)
Mimic.copy(Req)

# Managoat.Sandbox.Retry sleeps between attempts; 1ms keeps the retry-path
# tests fast without changing the logic under test.
Application.put_env(:managoat_sandbox, Managoat.Sandbox.Retry, base_ms: 1)

# test/live/ talks to a real Sprites account and is billed: `mix test --only
# live` runs it, with the credentials it names.
ExUnit.start(exclude: [:live])
