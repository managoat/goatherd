defmodule Goatherd.StateTest do
  use ExUnit.Case, async: false

  alias Goatherd.Runs.Run
  alias Goatherd.State

  setup %{tmp_dir: dir} do
    System.put_env("GOATHERD_STATE_DIR", dir)
    on_exit(fn -> System.delete_env("GOATHERD_STATE_DIR") end)
    :ok
  end

  @moduletag :tmp_dir

  defp run(id, attrs \\ []) do
    struct(
      %Run{
        id: id,
        sandbox: Run.sandbox_name(id),
        runtime: "claude",
        prompt: "do a thing",
        created_at: DateTime.utc_now() |> DateTime.to_iso8601()
      },
      attrs
    )
  end

  test "a run survives a round trip with its atoms intact" do
    State.put(run("aaaa1111", status: :running))
    assert {:ok, stored} = State.fetch("aaaa1111")
    assert stored.status == :running
    assert stored.provider == :sprites
  end

  test "fetch accepts an unambiguous prefix and refuses an ambiguous one" do
    State.put(run("abcd0001"))
    assert {:ok, %Run{id: "abcd0001"}} = State.fetch("abcd")

    State.put(run("abcd0002"))
    assert {:error, message} = State.fetch("abcd")
    assert message =~ "matches 2 runs"
  end

  test "merge updates a stored run and never resurrects a deleted one" do
    State.put(run("bbbb2222"))
    State.merge("bbbb2222", %{status: "done", stop_reason: "end_turn"})

    assert {:ok, %Run{status: :done, stop_reason: "end_turn"}} = State.fetch("bbbb2222")

    State.delete("bbbb2222")
    State.merge("bbbb2222", %{status: "running"})
    assert {:error, _} = State.fetch("bbbb2222")
  end

  test "list is newest first" do
    State.put(run("old00000", created_at: "2026-01-01T00:00:00Z"))
    State.put(run("new00000", created_at: "2026-09-01T00:00:00Z"))

    assert ["new00000", "old00000"] = Enum.map(State.list(), & &1.id)
  end

  test "a corrupt state file reads as empty rather than crashing the CLI" do
    File.write!(Path.join(System.get_env("GOATHERD_STATE_DIR"), "state.json"), "{not json")
    assert State.list() == []
  end
end
