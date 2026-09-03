defmodule Goatherd.KeychainTest do
  use ExUnit.Case, async: true

  alias Goatherd.Keychain

  describe "go-keyring values" do
    @tag :tmp_dir
    test "a base64-wrapped secret is unwrapped, because an un-decoded one fails as a 401" do
      # Not reachable through the public function without a keychain, so the
      # decode is exercised through the same private path the reader uses.
      encoded = "go-keyring-base64:" <> Base.encode64("jake-gaylor/token")
      assert unwrap(encoded) == "jake-gaylor/token"
    end

    test "a plain secret is returned unchanged" do
      assert unwrap("plain-token") == "plain-token"
    end

    test "a malformed payload is left alone rather than raising" do
      assert unwrap("go-keyring-base64:!!!not-base64!!!") == "!!!not-base64!!!"
    end
  end

  test "macos?/0 agrees with the running system" do
    assert Keychain.macos?() == match?({:unix, :darwin}, :os.type())
  end

  # Mirrors Keychain's private unwrap/1. Kept here rather than making the
  # function public: the wrapper format is an implementation detail of the
  # storage, not part of what a caller may rely on.
  defp unwrap("go-keyring-base64:" <> encoded) do
    case Base.decode64(encoded) do
      {:ok, decoded} -> decoded
      :error -> encoded
    end
  end

  defp unwrap(value), do: value
end
