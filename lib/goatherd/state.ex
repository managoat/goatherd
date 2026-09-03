defmodule Goatherd.State do
  @moduledoc """
  The pointer file — the only thing goatherd keeps between invocations.

  A run is durable because the *sandbox* is durable: it holds the filesystem,
  the git checkout and a detachable ACP session that keeps running when this
  process exits. So the record here is deliberately thin: enough to find that
  sandbox again and rejoin its session, and nothing that would go stale if the
  remote state moved on.

  It is a JSON object at `$XDG_STATE_HOME/goatherd/state.json`, written whole
  under a lock-free rename. Concurrent runs are the normal case — fanning out
  is the point — so every write re-reads, merges and renames rather than
  holding the file open.
  """

  alias Goatherd.Runs.Run

  @doc "Every run, newest first."
  @spec list() :: [Run.t()]
  def list do
    read()
    |> Map.values()
    |> Enum.map(&Run.from_map/1)
    |> Enum.sort_by(& &1.created_at, :desc)
  end

  @doc "One run by id, or by unambiguous id prefix."
  @spec fetch(String.t()) :: {:ok, Run.t()} | {:error, String.t()}
  def fetch(id) do
    runs = list()

    case Enum.filter(runs, &String.starts_with?(&1.id, id)) do
      [run] ->
        {:ok, run}

      [] ->
        {:error, "no run matching #{id}"}

      many ->
        {:error, "#{id} matches #{length(many)} runs: #{Enum.map_join(many, ", ", & &1.id)}"}
    end
  end

  @doc "Insert or replace a run."
  @spec put(Run.t()) :: :ok
  def put(%Run{} = run) do
    update(fn all -> Map.put(all, run.id, Run.to_map(run)) end)
  end

  @doc "Merge fields into a stored run. A run that is gone is not recreated."
  @spec merge(String.t(), map()) :: :ok
  def merge(id, fields) do
    update(fn all ->
      case Map.fetch(all, id) do
        {:ok, stored} -> Map.put(all, id, Map.merge(stored, stringify(fields)))
        :error -> all
      end
    end)
  end

  @doc "Forget a run. The sandbox it named is not touched."
  @spec delete(String.t()) :: :ok
  def delete(id), do: update(&Map.delete(&1, id))

  defp update(fun) do
    File.mkdir_p!(Goatherd.state_dir())
    all = fun.(read())
    tmp = path() <> ".#{System.unique_integer([:positive])}.tmp"
    File.write!(tmp, Jason.encode_to_iodata!(all, pretty: true))
    File.rename!(tmp, path())
    :ok
  end

  defp read do
    with {:ok, body} <- File.read(path()),
         {:ok, map} when is_map(map) <- Jason.decode(body) do
      map
    else
      _ -> %{}
    end
  end

  defp path, do: Path.join(Goatherd.state_dir(), "state.json")

  defp stringify(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end
end
