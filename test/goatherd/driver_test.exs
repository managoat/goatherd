defmodule Goatherd.DriverTest do
  use ExUnit.Case, async: true

  alias Goatherd.Driver

  describe "drop_replayed/2" do
    test "with no set, every line is live" do
      assert Driver.drop_replayed(["a", "b"], nil) == {["a", "b"], nil}
    end

    test "drops a replayed prefix and keeps the live tail" do
      seen = MapSet.new(["a", "b"])
      assert {["c"], nil} = Driver.drop_replayed(["a", "b", "c"], seen)
    end

    test "a chunk that is entirely replay carries the set forward" do
      seen = MapSet.new(["a", "b"])
      assert {[], ^seen} = Driver.drop_replayed(["a", "b"], seen)
    end

    test "stops de-duplicating at the first new line, so a genuine repeat survives" do
      # The agent running the same tool twice is normal. Once the live stream
      # has started, an identical line is content, not replay.
      seen = MapSet.new(["tool"])
      assert {["new", "tool"], nil} = Driver.drop_replayed(["tool", "new", "tool"], seen)
    end
  end

  describe "policy/2" do
    test "defaults to allowing everything except running commands" do
      {:ok, config} = Goatherd.Config.from_map(%{})
      assert Driver.policy(config, []) == %{"default" => "auto_allow", "execute" => "ask"}
    end

    test "--yes flattens to allow-all, which is what unattended means" do
      {:ok, config} = Goatherd.Config.from_map(%{})
      assert Driver.policy(config, yes: true) == %{"default" => "auto_allow"}
    end

    test "a herd file policy is used verbatim, with keys stringified" do
      {:ok, config} = Goatherd.Config.from_map(%{"permissions" => %{"default" => "auto_deny"}})
      assert Driver.policy(config, []) == %{"default" => "auto_deny"}
    end
  end
end
