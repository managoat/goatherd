defmodule Goatherd.Config do
  @moduledoc """
  The herd file: one YAML document describing the agent and the machine it
  wants, resolved from the working directory upward.

  This is the artifact that makes a run reproducible and reviewable. It is
  deliberately the same information a Fountain agent plus environment carries —
  runtime, model, system prompt, packages, repositories, a setup script,
  environment variables and a permission policy — flattened into one file,
  because with a single user there is nothing for the agent/environment split
  to buy.

      # .goatherd.yml
      runtime: claude
      model: anthropic/claude-opus-4-1
      system: You are reviewing a Phoenix umbrella. Be terse.
      packages:
        apt: [ripgrep]
      repos:
        - url: https://github.com/managoat/goatherd
      setup: |
        cd goatherd && mix deps.get
      env:
        MIX_ENV: test
      secrets: [GITHUB_TOKEN]
      permissions:
        default: auto_allow
        execute: ask

  `secrets` names variables to copy out of *your* environment into the
  sandbox. They are named, never listed with values, so the file is safe to
  commit — which is the point of naming them here rather than putting them in
  `env`.

  Every key is optional. With no file at all you get claude, no repository and
  an empty sandbox, which is a useful thing to be able to type.
  """

  @default_runtime "claude"
  @filename ".goatherd.yml"

  @type t :: %__MODULE__{
          runtime: String.t(),
          model: String.t() | nil,
          system: String.t() | nil,
          name: String.t() | nil,
          packages: map(),
          repos: [map()],
          setup: String.t() | nil,
          env: [{String.t(), String.t()}],
          secrets: [String.t()],
          permissions: map(),
          mcp_servers: map(),
          source: String.t() | nil
        }

  defstruct runtime: @default_runtime,
            model: nil,
            system: nil,
            name: nil,
            packages: %{},
            repos: [],
            setup: nil,
            env: [],
            secrets: [],
            permissions: %{},
            mcp_servers: %{},
            source: nil

  @doc """
  Load the nearest herd file at or above `dir`, or the defaults when there is
  none. A malformed file is an error, never a silent fall back to defaults —
  a typo in YAML that quietly ran a different agent would be the worst
  possible failure mode for a tool that spends money.
  """
  @spec load(String.t()) :: {:ok, t()} | {:error, String.t()}
  def load(dir \\ File.cwd!()) do
    case find(Path.expand(dir)) do
      nil -> {:ok, %__MODULE__{}}
      path -> parse_file(path)
    end
  end

  @doc "The path of the nearest herd file at or above `dir`, or nil."
  @spec find(String.t()) :: String.t() | nil
  def find(dir) do
    candidate = Path.join(dir, @filename)
    parent = Path.dirname(dir)

    cond do
      File.regular?(candidate) -> candidate
      parent == dir -> nil
      true -> find(parent)
    end
  end

  defp parse_file(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, doc} when is_map(doc) -> from_map(doc, path)
      {:ok, nil} -> {:ok, %__MODULE__{source: path}}
      {:ok, _} -> {:error, "#{path}: expected a YAML mapping at the top level"}
      {:error, %{message: message}} -> {:error, "#{path}: #{message}"}
      {:error, reason} -> {:error, "#{path}: #{inspect(reason)}"}
    end
  end

  @doc "Build a config from an already-decoded YAML mapping."
  @spec from_map(map(), String.t() | nil) :: {:ok, t()} | {:error, String.t()}
  def from_map(doc, source \\ nil) do
    with {:ok, runtime} <- runtime(doc),
         {:ok, repos} <- repos(doc) do
      {:ok,
       %__MODULE__{
         runtime: runtime,
         model: string(doc["model"]),
         system: string(doc["system"]),
         name: string(doc["name"]),
         packages: doc["packages"] || %{},
         repos: repos,
         setup: string(doc["setup"]),
         env: env_pairs(doc["env"]),
         secrets: List.wrap(doc["secrets"]) |> Enum.map(&to_string/1),
         permissions: doc["permissions"] || %{},
         mcp_servers: doc["mcp_servers"] || doc["mcpServers"] || %{},
         source: source
       }}
    end
  end

  # `Managoat.Runtimes.for_runtime/1` is the authority on what exists; asking
  # it here means an unknown runtime is refused before a sandbox is billed for.
  defp runtime(doc) do
    name = string(doc["runtime"]) || @default_runtime

    case Managoat.Runtimes.for_runtime(name) do
      {:ok, _mod} -> {:ok, name}
      {:error, message} -> {:error, message}
    end
  end

  defp repos(doc) do
    doc
    |> Map.get("repos", [])
    |> List.wrap()
    |> Enum.reduce_while({:ok, []}, fn
      url, {:ok, acc} when is_binary(url) ->
        {:cont, {:ok, acc ++ [%{"url" => url}]}}

      %{"url" => url} = repo, {:ok, acc} when is_binary(url) ->
        {:cont, {:ok, acc ++ [repo]}}

      other, _ ->
        {:halt, {:error, "repos: each entry needs a url, got #{inspect(other)}"}}
    end)
  end

  defp env_pairs(nil), do: []

  defp env_pairs(map) when is_map(map),
    do: Enum.map(map, fn {k, v} -> {to_string(k), to_string(v)} end)

  defp env_pairs(_), do: []

  defp string(nil), do: nil
  defp string(""), do: nil
  defp string(value) when is_binary(value), do: value
  defp string(value), do: to_string(value)

  @doc """
  The agent map the `Managoat.Runtimes` callbacks read. The library types this
  as a plain map with five optional keys, so this is the whole translation.
  """
  @spec agent(t()) :: Managoat.Runtimes.agent()
  def agent(%__MODULE__{} = config) do
    %{
      runtime: config.runtime,
      model: config.model,
      system: config.system,
      name: config.name || "goatherd",
      mcp_servers: config.mcp_servers
    }
  end
end
