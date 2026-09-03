defmodule Goatherd.ConfigTest do
  use ExUnit.Case, async: true

  alias Goatherd.Config

  describe "from_map/2" do
    test "defaults to claude with nothing configured" do
      assert {:ok, config} = Config.from_map(%{})
      assert config.runtime == "claude"
      assert config.repos == []
      assert config.env == []
    end

    test "refuses a runtime that does not exist, rather than provisioning for it" do
      assert {:error, message} = Config.from_map(%{"runtime" => "cursor"})
      assert message =~ "unsupported runtime"
    end

    test "accepts a repo as a bare url or as a mapping" do
      {:ok, config} =
        Config.from_map(%{
          "repos" => [
            "https://example.com/a.git",
            %{"url" => "https://example.com/b", "branch" => "next"}
          ]
        })

      assert [%{"url" => "https://example.com/a.git"}, %{"branch" => "next"}] = config.repos
    end

    test "refuses a repo entry with no url" do
      assert {:error, message} = Config.from_map(%{"repos" => [%{"branch" => "main"}]})
      assert message =~ "needs a url"
    end

    test "env values are stringified so a YAML number survives as a variable" do
      {:ok, config} = Config.from_map(%{"env" => %{"PORT" => 4000}})
      assert config.env == [{"PORT", "4000"}]
    end
  end

  describe "agent/1" do
    test "carries exactly the keys Managoat.Runtimes reads" do
      {:ok, config} = Config.from_map(%{"runtime" => "claude", "system" => "be terse"})
      agent = Config.agent(config)

      assert %{runtime: "claude", system: "be terse", name: "goatherd"} = agent
      assert Map.keys(agent) |> Enum.sort() == [:mcp_servers, :model, :name, :runtime, :system]
    end
  end

  describe "load/1" do
    @tag :tmp_dir
    test "finds the nearest herd file above the working directory", %{tmp_dir: dir} do
      File.write!(Path.join(dir, ".goatherd.yml"), "runtime: codex\n")
      nested = Path.join(dir, "a/b")
      File.mkdir_p!(nested)

      assert {:ok, config} = Config.load(nested)
      assert config.runtime == "codex"
      assert config.source == Path.join(dir, ".goatherd.yml")
    end

    @tag :tmp_dir
    test "a malformed file is an error, never a silent fall back to defaults", %{tmp_dir: dir} do
      File.write!(Path.join(dir, ".goatherd.yml"), "runtime: [this is not a string\n")
      assert {:error, _} = Config.load(dir)
    end

    @tag :tmp_dir
    test "no herd file anywhere is not an error", %{tmp_dir: dir} do
      assert {:ok, %Config{source: nil, runtime: "claude"}} = Config.load(dir)
    end
  end
end
