defmodule Goatherd.ProvisionTest do
  use ExUnit.Case, async: true

  alias Goatherd.{Config, Provision}

  setup do
    System.put_env("GOATHERD_TEST_SECRET", "s3cret")
    on_exit(fn -> System.delete_env("GOATHERD_TEST_SECRET") end)
    :ok
  end

  describe "sprite_env/4" do
    test "credentials are delivered, and a module that is merely unloaded does not lose them" do
      # The regression this file exists for: `function_exported?/3` answers
      # false for an unloaded module, so dispatching optional callbacks
      # through it silently dropped every credential and the failure surfaced
      # as an authentication error inside the agent, minutes later.
      :code.purge(Managoat.Runtimes.Claude)
      :code.delete(Managoat.Runtimes.Claude)

      {:ok, config} = Config.from_map(%{})

      env =
        Provision.sprite_env(
          config,
          Managoat.Runtimes.Claude,
          Config.agent(config),
          %{anthropic_api_key: "sk-test"}
        )

      assert {"ANTHROPIC_API_KEY", "sk-test"} in env
    end

    test "a named secret is lifted out of the local environment by name" do
      {:ok, config} = Config.from_map(%{"secrets" => ["GOATHERD_TEST_SECRET"]})
      env = Provision.sprite_env(config, Managoat.Runtimes.Claude, Config.agent(config), %{})

      assert {"GOATHERD_TEST_SECRET", "s3cret"} in env
    end

    test "credentials win over a herd file trying to shadow them" do
      {:ok, config} = Config.from_map(%{"env" => %{"ANTHROPIC_API_KEY" => "not-yours"}})

      env =
        Provision.sprite_env(
          config,
          Managoat.Runtimes.Claude,
          Config.agent(config),
          %{anthropic_api_key: "sk-real"}
        )

      assert {"ANTHROPIC_API_KEY", "sk-real"} in env
      refute {"ANTHROPIC_API_KEY", "not-yours"} in env
    end
  end

  describe "missing_secrets/1" do
    test "names what this shell cannot supply, so a sandbox is never billed to find out" do
      {:ok, config} =
        Config.from_map(%{"secrets" => ["GOATHERD_TEST_SECRET", "NOT_SET_ANYWHERE"]})

      assert Provision.missing_secrets(config) == ["NOT_SET_ANYWHERE"]
    end
  end
end
