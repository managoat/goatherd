defmodule Goatherd.Provision do
  @moduledoc """
  Turn a bare sandbox into one a coding agent can work in.

  The order is Fountain's, because the order is the part that was learned the
  hard way rather than designed: packages first (an `apt` that runs after a
  network policy is applied cannot reach the archives), then the env file,
  then repositories, then the user's setup script, then the ACP adapter, then
  the runtime's own config and bootstrap. Each step is skipped when the herd
  file asks for nothing, so the cheapest possible run — no packages, no repo,
  no setup — is three calls.

  Everything here happens on the remote machine. Nothing is read from or
  written to the local filesystem: goatherd never uploads a working tree, and
  a repository arrives by `git clone` inside the sandbox exactly as it would
  on a server.
  """

  alias Goatherd.Config
  alias Managoat.Runtimes
  alias Managoat.Sandbox

  @home "/home/sprite"
  @env_file "/home/sprite/.env"

  @type progress :: (String.t(), String.t() -> any())

  @doc """
  Provision `handle` for `config`, reporting each stage through `on_stage`.

  Returns the `sprite_env` pairs the ACP spawn must carry — the union of the
  herd file's `env`, the named secrets lifted from this shell, and the
  runtime's credential variables. The caller needs them because the adapter is
  spawned after provisioning, not by it.
  """
  @spec run(Sandbox.Handle.t(), Config.t(), map(), progress()) ::
          {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def run(handle, %Config{} = config, inference_credentials, on_stage \\ fn _, _ -> :ok end) do
    {:ok, runtime_mod} = Runtimes.for_runtime(config.runtime)
    agent = Config.agent(config)
    sprite_env = sprite_env(config, runtime_mod, agent, inference_credentials)

    with :ok <- stage(on_stage, "packages", fn -> packages(handle, config, sprite_env) end),
         :ok <- stage(on_stage, "env", fn -> env_file(handle, sprite_env) end),
         :ok <- stage(on_stage, "clone", fn -> clone(handle, config, sprite_env) end),
         :ok <- stage(on_stage, "setup", fn -> setup(handle, config, sprite_env) end),
         :ok <- stage(on_stage, "adapter", fn -> adapter(handle, config, sprite_env) end),
         :ok <-
           stage(on_stage, "config", fn ->
             runtime_config(handle, runtime_mod, config, agent, sprite_env)
           end) do
      {:ok, sprite_env}
    end
  end

  @doc """
  The environment every command in the sandbox runs with.

  Three sources, in increasing precedence: the herd file's `env`, the secrets
  it named lifted out of the local process environment, and the runtime's own
  credential variables. Credentials last because a herd file must not be able
  to shadow the token the run is authenticated with.
  """
  @spec sprite_env(Config.t(), module(), map(), map()) :: [{String.t(), String.t()}]
  def sprite_env(%Config{} = config, runtime_mod, agent, inference_credentials) do
    secrets =
      for name <- config.secrets,
          value = System.get_env(name),
          is_binary(value) and value != "",
          do: {name, value}

    credentials = maybe(runtime_mod, :default_env, [agent, inference_credentials], [])

    (config.env ++ secrets ++ credentials)
    |> Enum.reverse()
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.reverse()
  end

  @doc "Names of the secrets a herd file asked for that this shell cannot supply."
  @spec missing_secrets(Config.t()) :: [String.t()]
  def missing_secrets(%Config{secrets: names}) do
    Enum.reject(names, fn name ->
      value = System.get_env(name)
      is_binary(value) and value != ""
    end)
  end

  defp stage(on_stage, name, fun) do
    on_stage.(name, "started")

    case fun.() do
      :ok ->
        on_stage.(name, "done")
        :ok

      {:error, reason} ->
        on_stage.(name, "failed")
        {:error, {String.to_atom(name), reason}}
    end
  end

  defp packages(_handle, %Config{packages: p}, _env) when p == %{}, do: :ok

  defp packages(handle, %Config{packages: packages}, env) do
    apt = packages |> Map.get("apt", []) |> List.wrap()
    npm = packages |> Map.get("npm", []) |> List.wrap()

    scripts =
      [
        apt != [] &&
          "sudo apt-get update -qq && sudo apt-get install -y -qq #{Enum.join(apt, " ")}",
        npm != [] && "npm install -g --no-progress --silent #{Enum.join(npm, " ")}"
      ]
      |> Enum.filter(& &1)

    Enum.reduce_while(scripts, :ok, fn script, :ok ->
      case Sandbox.exec(handle, "bash", ["-lc", script], env: env, timeout: 300_000) do
        {:ok, _out, 0} -> {:cont, :ok}
        {:ok, out, code} -> {:halt, {:error, {:exit, code, tail(out)}}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # Written for a setup script to `source`, exactly as Fountain does. Values
  # are single-quoted with embedded quotes escaped, so a secret containing
  # shell metacharacters cannot become a command.
  defp env_file(_handle, []), do: :ok

  defp env_file(handle, env) do
    body =
      Enum.map_join(env, "\n", fn {key, value} ->
        "export #{key}='#{String.replace(value, "'", "'\\''")}'"
      end) <> "\n"

    case Sandbox.write_file(handle, @env_file, body, mode: 0o600) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      other -> other
    end
  end

  defp clone(_handle, %Config{repos: []}, _env), do: :ok

  defp clone(handle, %Config{repos: repos}, env) do
    Enum.reduce_while(repos, :ok, fn repo, :ok ->
      case clone_one(handle, repo, env) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp clone_one(handle, %{"url" => url} = repo, env) do
    dir = repo["dir"] || url |> Path.basename() |> String.replace_suffix(".git", "")
    branch = repo["branch"]
    depth = if repo["full"], do: "", else: "--depth 1"
    branch_arg = if branch, do: "--branch #{branch}", else: ""

    # A token in the environment is used through git's credential helper
    # rather than interpolated into the URL, so it never lands in
    # `.git/config` or a process listing inside the sandbox.
    script = """
    set -e
    cd #{@home}
    if [ -d "#{dir}/.git" ]; then exit 0; fi
    if [ -n "${GITHUB_TOKEN:-}" ]; then
      git config --global credential.helper '!f() { echo "username=x-access-token"; echo "password=$GITHUB_TOKEN"; }; f'
    fi
    git clone #{depth} #{branch_arg} "#{url}" "#{dir}"
    """

    case Sandbox.exec(handle, "bash", ["-lc", script], env: env, timeout: 300_000) do
      {:ok, _out, 0} -> :ok
      {:ok, out, code} -> {:error, {:clone_exit, code, tail(out)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp setup(_handle, %Config{setup: nil}, _env), do: :ok

  defp setup(handle, %Config{setup: script}, env) do
    body = "set -e\ncd #{@home}\n[ -f #{@env_file} ] && . #{@env_file}\n" <> script

    case Sandbox.exec(handle, "bash", ["-lc", body], env: env, timeout: 900_000) do
      {:ok, _out, 0} -> :ok
      {:ok, out, code} -> {:error, {:setup_exit, code, tail(out)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp adapter(handle, %Config{runtime: runtime}, env) do
    Runtimes.ACP.install(handle, runtime, env)
  end

  defp runtime_config(handle, runtime_mod, %Config{runtime: runtime} = config, agent, env) do
    with :ok <- maybe(runtime_mod, :write_config, [handle, agent]),
         :ok <- Runtimes.Instructions.write(handle, runtime, instructions_agent(config)) do
      maybe(runtime_mod, :prepare_sandbox, [handle, agent, env])
    end
  end

  # `Instructions.write/3` only writes when the agent map carries a `:system`,
  # so an agent with no system prompt correctly writes no file.
  defp instructions_agent(%Config{system: nil}), do: nil
  defp instructions_agent(%Config{} = config), do: Config.agent(config)

  # `function_exported?/3` answers **false for a module that is merely not
  # loaded yet**, which in a release or an escript is the normal state of a
  # module nobody has called. Skipping the ensure_loaded turns every optional
  # callback into a silent no-op: the run still succeeds, the credential env
  # comes back empty, and the agent fails much later with "Authentication
  # required" — a symptom that points nowhere near here. Measured, not
  # theorised: it cost an afternoon.
  defp maybe(mod, fun, args, default \\ :ok) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, fun, length(args)) do
      apply(mod, fun, args)
    else
      default
    end
  end

  defp tail(output) do
    output |> to_string() |> String.slice(-800, 800) |> to_string()
  end
end
