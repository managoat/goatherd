defmodule Goatherd.Render do
  @moduledoc """
  Draw an ACP block stream on a terminal.

  `Managoat.ACP.Blocks` already did the hard part: four vendor output formats
  arrive here as one small set of block maps, so this module is presentation
  and nothing else. It holds one piece of state — whether the last thing
  printed was assistant text — because agent messages arrive as many chunks
  and a newline between every chunk would shred every paragraph.

  Colour is suppressed when stdout is not a terminal or `NO_COLOR` is set, so
  piping a run into a file gives clean text.
  """

  defstruct in_text?: false, quiet?: false

  @type t :: %__MODULE__{}

  @doc "A fresh renderer. `quiet?: true` prints results and errors only."
  @spec new(keyword()) :: t()
  def new(opts \\ []), do: %__MODULE__{quiet?: Keyword.get(opts, :quiet, false)}

  @doc "Render one block, returning the renderer for the next."
  @spec block(t(), map()) :: t()
  def block(state, %{kind: :text, body: body}) do
    IO.write(body)
    %{state | in_text?: true}
  end

  def block(%{quiet?: true} = state, %{kind: :thinking}), do: state

  def block(state, %{kind: :thinking, body: body}) do
    state = break(state)
    IO.write(dim(String.trim_trailing(body)) <> "\n")
    state
  end

  def block(%{quiet?: true} = state, %{kind: :tool_use}), do: state

  def block(state, %{kind: :tool_use} = block) do
    state = break(state)
    name = block[:name] || "tool"
    summary = block[:summary]
    line = if summary && summary != name, do: "#{name} #{dim(summary)}", else: name
    IO.write(color("  " <> glyph(:tool) <> " ", :cyan) <> line <> "\n")
    state
  end

  def block(%{quiet?: true} = state, %{kind: :tool_result, error?: false}), do: state

  def block(state, %{kind: :tool_result} = block) do
    state = break(state)

    if block[:error?] do
      IO.write(color("  ! ", :red) <> dim(one_line(block[:body])) <> "\n")
    else
      case one_line(block[:body]) do
        "" -> :ok
        body -> IO.write(dim("    " <> body) <> "\n")
      end
    end

    state
  end

  def block(state, %{kind: :raw, body: body}) do
    state = break(state)
    IO.write(dim("  ? " <> one_line(body)) <> "\n")
    state
  end

  # `:permission_request` blocks are answered by the driver, which prints its
  # own prompt. Rendering them here as well would show the question twice.
  def block(state, _block), do: state

  @doc "End any run of assistant text so the next line starts clean."
  @spec break(t()) :: t()
  def break(%{in_text?: true} = state) do
    IO.write("\n")
    %{state | in_text?: false}
  end

  def break(state), do: state

  @doc "A provisioning stage, drawn as one updating line per stage."
  @spec stage(t(), String.t(), String.t()) :: t()
  def stage(%{quiet?: true} = state, _name, _status), do: state

  def stage(state, name, "started") do
    IO.write(dim("  · #{name}…"))
    state
  end

  def stage(state, _name, "done") do
    IO.write(dim(" ok") <> "\n")
    state
  end

  def stage(state, _name, "failed") do
    IO.write(color(" failed", :red) <> "\n")
    state
  end

  @doc "A framing line above the turn."
  @spec header(t(), String.t()) :: t()
  def header(%{quiet?: true} = state, _text), do: state

  def header(state, text) do
    IO.write(dim(text) <> "\n")
    state
  end

  @doc "The closing line: stop reason and what the tokens cost."
  @spec footer(t(), String.t(), map() | nil) :: t()
  def footer(state, stop_reason, usage) do
    state = break(state)
    IO.write("\n" <> dim(String.trim(stop_reason <> "  " <> usage_line(usage))) <> "\n")
    state
  end

  @doc "An error, always shown, always on stderr."
  @spec error(String.t()) :: :ok
  def error(message), do: IO.puts(:stderr, color("error: ", :red) <> message)

  @doc "A note, always shown."
  @spec note(String.t()) :: :ok
  def note(message), do: IO.puts(dim(message))

  defp usage_line(usage) when is_map(usage) do
    parts =
      for key <- ["inputTokens", "outputTokens", "cachedInputTokens"],
          value = usage[key],
          is_integer(value) and value > 0,
          do: "#{short(key)} #{value}"

    Enum.join(parts, "  ")
  end

  defp usage_line(_), do: ""

  defp short("inputTokens"), do: "in"
  defp short("outputTokens"), do: "out"
  defp short("cachedInputTokens"), do: "cached"

  defp one_line(nil), do: ""

  defp one_line(body) do
    body
    |> to_string()
    |> String.split("\n", trim: true)
    |> Enum.join(" ")
    |> String.slice(0, 160)
  end

  defp glyph(:tool), do: "⚒"

  @doc "True when it is safe to emit ANSI escapes."
  @spec color?() :: boolean()
  def color? do
    is_nil(System.get_env("NO_COLOR")) and IO.ANSI.enabled?()
  end

  defp dim(text), do: color(text, :light_black)

  defp color(text, code) do
    if color?(), do: IO.ANSI.format([code, text, :reset]) |> IO.iodata_to_binary(), else: text
  end
end
