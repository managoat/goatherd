defmodule Goatherd do
  @moduledoc """
  Run coding agents in remote sandboxes from your terminal.

  Goatherd is Fountain's control plane with the server taken out. The sandbox
  is still a real remote machine — Sprites — and every file, every `git`, every
  compiler runs in it. What is missing is the deployed service between you and
  it: no account, no database, no web UI, no billing. Your laptop holds three
  things and nothing else: a Sprites token, an inference credential, and a
  pointer file naming the sandboxes it started.

  The work is done by three libraries that already exist:
  `Managoat.Sandbox` (the machine), `Managoat.Runtimes` (getting a coding agent
  into it, speaking ACP) and `Managoat.ACP` (the protocol conversation). This
  application is the part that was previously a Phoenix server: read a config,
  provision, drive one turn, render it to a terminal, remember the pointer.

  ## The ceiling, stated up front

  A turn runs in the sandbox but is *driven* from here. Close the laptop and
  nothing consumes the agent's output; a permission request nobody answers is
  denied when it times out. Goatherd is for turns you watch. `goatherd attach`
  rejoins one that is still in flight, and an unattended run wants
  `permissions.default: auto_allow`.
  """

  @doc "Directory holding the pointer file. Honours XDG_STATE_HOME."
  @spec state_dir() :: String.t()
  def state_dir do
    case System.get_env("GOATHERD_STATE_DIR") do
      nil ->
        base = System.get_env("XDG_STATE_HOME") || Path.join(System.user_home!(), ".local/state")
        Path.join(base, "goatherd")

      dir ->
        dir
    end
  end

  @doc "Where transcripts are written, one ndjson file per run."
  @spec transcript_dir() :: String.t()
  def transcript_dir, do: Path.join(state_dir(), "transcripts")
end
