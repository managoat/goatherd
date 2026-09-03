defmodule Goatherd.CLI do
  @moduledoc """
  The command line: argument parsing, application startup and exit codes.

  An escript starts no applications and never runs `config/runtime.exs`, so
  both jobs are done here explicitly and in one place — `boot/0` starts the
  three libraries and hands the Sprites adapter its token. Everything above
  this module can then assume a configured runtime.
  """

  alias Goatherd.{Auth, Config, Driver, Render, State}
  alias Goatherd.Runs.Run
  alias Managoat.ACP.Blocks
  alias Managoat.Sandbox

  @version Mix.Project.config()[:version]

  @switches [
    quiet: :boolean,
    yes: :boolean,
    rm: :boolean,
    runtime: :string,
    model: :string,
    repo: :keep,
    setup: :string,
    all: :boolean,
    help: :boolean,
    version: :boolean
  ]

  @aliases [q: :quiet, y: :yes, r: :repo, m: :model, h: :help, v: :version]

  @doc "Entry point. Never raises; every failure is a message and an exit code."
  @spec main([String.t()]) :: no_return()
  def main(argv) do
    {opts, args, invalid} = OptionParser.parse(argv, strict: @switches, aliases: @aliases)

    cond do
      invalid != [] ->
        Render.error("unknown option #{invalid |> List.first() |> elem(0)}")
        halt(2)

      opts[:version] ->
        IO.puts("goatherd #{@version}")
        halt(0)

      opts[:help] || args == [] ->
        IO.puts(usage())
        halt(if(args == [], do: 1, else: 0))

      true ->
        run_dispatch(args, opts)
    end
  end

  # `goatherd ps | head` closes stdout while we are still writing to it, and
  # an unhandled write to a terminated device is a crash dump where the user
  # expects three lines and a prompt. A closed pipe is the reader saying it
  # has enough, which is success.
  defp run_dispatch(args, opts) do
    dispatch(args, opts)
  rescue
    ErlangError -> halt(0)
  catch
    :exit, _ -> halt(0)
  end

  defp dispatch(["run" | rest], opts), do: run(Enum.join(rest, " "), opts)
  defp dispatch(["say", id | rest], opts), do: say(id, Enum.join(rest, " "), opts)
  defp dispatch(["attach", id], opts), do: attach(id, opts)
  defp dispatch(["ps"], opts), do: ps(opts)
  defp dispatch(["logs", id], _opts), do: logs(id)
  defp dispatch(["rm" | rest], opts), do: rm(rest, opts)
  defp dispatch(["doctor"], _opts), do: doctor()
  defp dispatch(["init"], _opts), do: init()

  # A bare prompt is the commonest thing anyone types, so `goatherd "fix the
  # flaky test"` means `goatherd run "…"`. Only reached when the first word is
  # not a command, so no command name can be shadowed by a prompt.
  defp dispatch(args, opts), do: run(Enum.join(args, " "), opts)

  # ── commands ─────────────────────────────────────────────────────────────

  defp run("", _opts) do
    Render.error(~s(nothing to do: goatherd run "your prompt"))
    halt(2)
  end

  defp run(prompt, opts) do
    boot!()

    with {:ok, config} <- load_config(opts),
         :ok <- check_secrets(config) do
      case Driver.start(prompt, config, driver_opts(opts)) do
        {:ok, _run} -> halt(0)
        {:error, reason} -> fail(reason)
      end
    else
      {:error, message} -> fail(message)
    end
  end

  defp say(id, "", _opts) do
    Render.error(~s(nothing to say: goatherd say #{id} "your prompt"))
    halt(2)
  end

  defp say(id, prompt, opts) do
    boot!()

    # The herd file is read from the directory the run was *started* in, not
    # from wherever the shell happens to be now. `goatherd say` from another
    # repo would otherwise pick up that repo's herd file and drive the wrong
    # agent at a session it does not own.
    with {:ok, run} <- State.fetch(id),
         {:ok, config} <- load_config(opts, run.workdir) do
      case Driver.continue(run, prompt, config, driver_opts(opts)) do
        {:ok, _run} -> halt(0)
        {:error, reason} -> fail(reason)
      end
    else
      {:error, message} -> fail(message)
    end
  end

  defp attach(id, opts) do
    boot!()

    case State.fetch(id) do
      {:ok, run} ->
        case Driver.attach(run, driver_opts(opts)) do
          {:ok, _run} -> halt(0)
          {:error, reason} -> fail(reason)
        end

      {:error, message} ->
        fail(message)
    end
  end

  # `ps` asks the provider rather than trusting the pointer file: a run whose
  # driver was killed is recorded as running, and the sandbox is the authority
  # on whether it still exists.
  defp ps(_opts) do
    boot!()

    case State.list() do
      [] ->
        IO.puts(~s(no runs yet. try: goatherd "what is in this repo?"))
        halt(0)

      runs ->
        live = live_names()

        IO.puts(header_row())

        Enum.each(runs, fn run ->
          IO.puts(row(run, MapSet.member?(live, run.sandbox)))
        end)

        halt(0)
    end
  end

  defp logs(id) do
    case State.fetch(id) do
      {:ok, run} -> replay(run)
      {:error, message} -> fail(message)
    end
  end

  defp replay(run) do
    case run.transcript && File.read(run.transcript) do
      {:ok, body} ->
        body
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&Blocks.from_line/1)
        |> Enum.reduce(Render.new(), &Render.block(&2, &1))
        |> Render.break()

        halt(0)

      _ ->
        Render.error("no transcript for #{run.id}")
        halt(1)
    end
  end

  defp rm(ids, opts) do
    boot!()
    runs = if opts[:all], do: State.list(), else: Enum.flat_map(ids, &resolve/1)

    if runs == [] do
      Render.error("nothing to remove: goatherd rm <id>, or goatherd rm --all")
      halt(2)
    end

    Enum.each(runs, &destroy/1)
    halt(0)
  end

  defp resolve(id) do
    case State.fetch(id) do
      {:ok, run} -> [run]
      {:error, message} -> Render.error(message) && []
    end
  end

  defp destroy(run) do
    handle = Sandbox.build_handle(run.provider, run.sandbox)

    case Sandbox.destroy(handle) do
      :ok ->
        State.delete(run.id)
        IO.puts("removed #{run.id} (#{run.sandbox})")

      {:error, reason} ->
        Render.error("#{run.id}: #{inspect(reason)}")
    end
  end

  defp doctor do
    IO.puts("goatherd #{@version}")
    Enum.each(Auth.describe(), &IO.puts("  " <> &1))

    case Config.load() do
      {:ok, %Config{source: nil}} ->
        IO.puts("  herd file: none (using defaults)")

      {:ok, %Config{source: path, runtime: runtime}} ->
        IO.puts("  herd file: #{path} (#{runtime})")

      {:error, message} ->
        IO.puts("  herd file: INVALID — #{message}")
    end

    IO.puts("  state: #{Goatherd.state_dir()}")

    boot!()

    case Sandbox.list_all_names(:sprites) do
      {:ok, names} ->
        IO.puts("  sprites reachable: #{MapSet.size(names)} sandboxes on the account")

      {:error, reason} ->
        IO.puts("  sprites UNREACHABLE — #{inspect(reason)}")
    end

    halt(0)
  end

  defp init do
    path = Path.join(File.cwd!(), ".goatherd.yml")

    if File.exists?(path) do
      Render.error("#{path} already exists")
      halt(1)
    end

    File.write!(path, template())
    IO.puts("wrote #{path}")
    halt(0)
  end

  # ── plumbing ─────────────────────────────────────────────────────────────

  @doc """
  Start the libraries and configure the Sprites adapter.

  Public because `mix run` and the test suite need the same startup an escript
  gets, and duplicating it is how the two drift.
  """
  @spec boot() :: :ok | {:error, String.t()}
  def boot do
    Logger.configure(level: log_level())

    Enum.each([:yaml_elixir, :managoat_sandbox, :managoat_acp, :managoat_runtimes], fn app ->
      {:ok, _} = Application.ensure_all_started(app)
    end)

    case Auth.sprites_token() do
      {:ok, token} ->
        Application.put_env(:managoat_sandbox, Managoat.Sandbox.Sprites,
          token: token,
          base_url: Auth.sprites_base_url()
        )

        :ok

      {:error, message} ->
        {:error, message}
    end
  end

  defp boot! do
    case boot() do
      :ok -> :ok
      {:error, message} -> fail(message)
    end
  end

  # Library logs are diagnostics for a server operator, not output for someone
  # watching an agent work. GOATHERD_LOG turns them back on.
  defp log_level do
    case System.get_env("GOATHERD_LOG") do
      nil -> :warning
      level -> String.to_existing_atom(level)
    end
  rescue
    ArgumentError -> :warning
  end

  defp load_config(opts, dir \\ nil) do
    with {:ok, config} <- Config.load(config_dir(dir)) do
      config =
        config
        |> override(:runtime, opts[:runtime])
        |> override(:model, opts[:model])
        |> override(:setup, opts[:setup])
        |> add_repos(Keyword.get_values(opts, :repo))

      {:ok, config}
    end
  end

  # A recorded working directory that has since been deleted is not an error:
  # the run's sandbox is remote and still perfectly usable.
  defp config_dir(nil), do: File.cwd!()

  defp config_dir(dir), do: if(File.dir?(dir), do: dir, else: File.cwd!())

  defp override(config, _key, nil), do: config
  defp override(config, key, value), do: Map.put(config, key, value)

  defp add_repos(config, []), do: config

  defp add_repos(config, urls),
    do: %{config | repos: config.repos ++ Enum.map(urls, &%{"url" => &1})}

  # A secret named but not present is refused before a sandbox exists, because
  # discovering it after provisioning means paying for a sandbox to learn it.
  defp check_secrets(config) do
    case Goatherd.Provision.missing_secrets(config) do
      [] ->
        :ok

      missing ->
        {:error,
         "the herd file names secrets this shell does not have: #{Enum.join(missing, ", ")}"}
    end
  end

  defp driver_opts(opts) do
    [quiet: opts[:quiet] || false, yes: opts[:yes] || false, rm: opts[:rm] || false]
  end

  defp live_names do
    case Sandbox.list_all_names(:sprites) do
      {:ok, names} -> names
      _ -> MapSet.new()
    end
  end

  defp header_row do
    pad("RUN", 15) <> pad("RUNTIME", 9) <> pad("STATUS", 9) <> pad("AGE", 6) <> "PROMPT"
  end

  defp row(%Run{} = run, live?) do
    status = if live?, do: to_string(run.status), else: "gone"

    pad(run.id, 15) <>
      pad(run.runtime || "?", 9) <>
      pad(status, 9) <> pad(age(run.created_at), 6) <> String.slice(run.prompt, 0, 48)
  end

  defp pad(text, width), do: String.pad_trailing(to_string(text), width)

  defp age(nil), do: "?"

  defp age(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, started, _} -> humanise(DateTime.diff(DateTime.utc_now(), started))
      _ -> "?"
    end
  end

  defp humanise(seconds) do
    cond do
      seconds < 60 -> "#{seconds}s"
      seconds < 3600 -> "#{div(seconds, 60)}m"
      seconds < 86_400 -> "#{div(seconds, 3600)}h"
      true -> "#{div(seconds, 86_400)}d"
    end
  end

  defp fail(reason) do
    Render.error(message_for(reason))
    halt(1)
  end

  defp message_for(reason) when is_binary(reason), do: reason
  defp message_for(reason), do: inspect(reason)

  defp halt(code) do
    # Give buffered stdout a chance to flush before the VM stops.
    :ok = IO.write("")
    System.halt(code)
  end

  defp template do
    """
    # goatherd — everything here is optional.
    runtime: claude

    # repos:
    #   - url: https://github.com/you/your-repo

    # packages:
    #   apt: [ripgrep]

    # setup: |
    #   cd your-repo && mix deps.get

    # Named, never valued: goatherd copies these out of your shell.
    # secrets: [GITHUB_TOKEN]

    # permissions:
    #   default: auto_allow
    #   execute: ask
    """
  end

  defp usage do
    """
    goatherd #{@version} — run coding agents in remote sandboxes, from your terminal

    USAGE
      goatherd "<prompt>"             start a run (same as `goatherd run`)
      goatherd run "<prompt>"         start a run in a fresh sandbox
      goatherd say <id> "<prompt>"    another turn on an existing run
      goatherd attach <id>            rejoin a turn still in flight
      goatherd ps                     runs, and whether their sandbox is still up
      goatherd logs <id>              replay a run's transcript
      goatherd rm <id> | --all        destroy sandboxes and forget the runs
      goatherd doctor                 check credentials and reachability
      goatherd init                   write a .goatherd.yml here

    OPTIONS
      -m, --model <provider/model>    override the herd file
          --runtime <name>            claude | codex | gemini | opencode
      -r, --repo <url>                clone this repo in the sandbox (repeatable)
          --setup <script>            shell to run after cloning
      -y, --yes                       auto-answer permission requests
          --rm                        destroy the sandbox when the turn ends
      -q, --quiet                     results only
      -h, --help  -v, --version

    Credentials are found, not configured: SPRITES_TOKEN or the sprites CLI's
    keychain item, and ANTHROPIC_API_KEY or the Claude Code login on this
    machine. `goatherd doctor` says which it found.
    """
  end
end
