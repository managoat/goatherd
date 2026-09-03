defmodule Goatherd.Runs.Run do
  @moduledoc """
  One run: a sandbox, the ACP session inside it, and how to talk about it in a
  terminal.

  `status` is what *this* tool last observed, not a live fact. The sandbox is
  the authority — `goatherd ps` re-checks it — because a run whose driver was
  killed at the wrong moment would otherwise be recorded as running forever.
  """

  @type status :: :starting | :running | :done | :failed
  @type t :: %__MODULE__{
          id: String.t(),
          sandbox: String.t(),
          provider: atom(),
          runtime: String.t(),
          session_id: String.t() | nil,
          prompt_id: integer() | nil,
          prompt: String.t(),
          cwd: String.t(),
          status: status(),
          stop_reason: String.t() | nil,
          created_at: String.t(),
          workdir: String.t() | nil,
          transcript: String.t() | nil
        }

  defstruct [
    :id,
    :sandbox,
    :runtime,
    :session_id,
    :prompt_id,
    :prompt,
    :cwd,
    :stop_reason,
    :created_at,
    :workdir,
    :transcript,
    provider: :sprites,
    status: :starting
  ]

  @doc "A short, typeable, sortable run id."
  @spec new_id() :: String.t()
  def new_id do
    8 |> :crypto.strong_rand_bytes() |> Base.encode32(case: :lower, padding: false)
  end

  @doc "The sandbox name a run gets. Prefixed so `sprites ls` stays readable."
  @spec sandbox_name(String.t()) :: String.t()
  def sandbox_name(id), do: "goatherd-" <> id

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = run) do
    run
    |> Map.from_struct()
    |> Map.new(fn {k, v} -> {to_string(k), encode(v)} end)
  end

  @spec from_map(map()) :: t()
  def from_map(map) do
    %__MODULE__{
      id: map["id"],
      sandbox: map["sandbox"],
      provider: atom(map["provider"], :sprites),
      runtime: map["runtime"],
      session_id: map["session_id"],
      prompt_id: map["prompt_id"],
      prompt: map["prompt"] || "",
      cwd: map["cwd"],
      status: atom(map["status"], :starting),
      stop_reason: map["stop_reason"],
      created_at: map["created_at"],
      workdir: map["workdir"],
      transcript: map["transcript"]
    }
  end

  defp encode(value) when is_atom(value) and not is_nil(value) and not is_boolean(value),
    do: Atom.to_string(value)

  defp encode(value), do: value

  # Only ever called on values this module wrote, so the set is closed and
  # `String.to_existing_atom/1` is the safe conversion.
  defp atom(nil, default), do: default

  defp atom(value, default) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> default
  end

  defp atom(_, default), do: default
end
