defmodule Goatherd.Auth do
  @moduledoc """
  Where goatherd's two credentials come from.

  Both have the same precedence: an environment variable wins, and the
  workstation's existing login is the fallback. That ordering is what makes
  the tool scriptable (CI sets variables) without making it tedious
  (a laptop that already runs `sprites` and `claude` sets nothing).

  ## Sprites

  The Sprites CLI writes `~/.sprites/sprites.json`, whose `current_selection`
  names a URL and an org, and whose org entry carries a `keyring_key`. The
  token itself is a generic password in the login keychain under the service
  `sprites-cli:manual-tokens`, with that key as the account.

  ## Inference

  `Managoat.Runtimes` asks for a map of `%{provider_atom => plaintext}` and
  each runtime picks what it needs. We fill it from the environment, then from
  Claude Code's own keychain item, whose `claudeAiOauth.accessToken` is a
  `CLAUDE_CODE_OAUTH_TOKEN` — it bills the subscription the laptop is already
  signed in to rather than an API key, which is the point: goatherd adds no
  metering of its own because it never holds a credential of its own.

  An expired OAuth token is treated as absent. Goatherd does not refresh it —
  refreshing is Claude Code's job and doing it here would race the tool that
  owns the item.
  """

  alias Goatherd.Keychain

  @sprites_service "sprites-cli:manual-tokens"
  @claude_service "Claude Code-credentials"

  @doc """
  The Sprites API token, or `{:error, reason}` with a sentence a human can act
  on. Never returns the token in an error.
  """
  @spec sprites_token() :: {:ok, String.t()} | {:error, String.t()}
  def sprites_token do
    case System.get_env("SPRITES_TOKEN") do
      token when is_binary(token) and token != "" -> {:ok, token}
      _ -> sprites_token_from_cli()
    end
  end

  @doc "Base URL for the Sprites API, from the CLI's selection when present."
  @spec sprites_base_url() :: String.t()
  def sprites_base_url do
    with nil <- System.get_env("SPRITES_BASE_URL"),
         {:ok, %{"current_selection" => %{"url" => url}}} <- sprites_config() do
      url
    else
      url when is_binary(url) -> url
      _ -> "https://api.sprites.dev"
    end
  end

  defp sprites_token_from_cli do
    with {:ok, config} <- sprites_config(),
         {:ok, key} <- keyring_key(config),
         {:ok, token} <- Keychain.generic_password(@sprites_service, key) do
      {:ok, token}
    else
      _ ->
        {:error,
         "no Sprites token: set SPRITES_TOKEN, or sign in with the sprites CLI so " <>
           "~/.sprites/sprites.json and the login keychain carry one"}
    end
  end

  defp sprites_config do
    path = Path.join(System.user_home!(), ".sprites/sprites.json")

    with {:ok, body} <- File.read(path),
         {:ok, json} <- Jason.decode(body) do
      {:ok, json}
    else
      _ -> :error
    end
  end

  defp keyring_key(%{"current_selection" => %{"url" => url, "org" => org}, "urls" => urls}) do
    case get_in(urls, [url, "orgs", org, "keyring_key"]) do
      key when is_binary(key) -> {:ok, key}
      _ -> :error
    end
  end

  defp keyring_key(_), do: :error

  @doc """
  The inference credentials map `Managoat.Runtimes` callbacks read.

  Keys are the four the library names: `:anthropic_api_key`,
  `:claude_code_oauth_token`, `:openai_api_key`, `:gemini_api_key`. A provider
  with no credential is absent rather than nil, which is what the library's
  `default_env/2` implementations expect.
  """
  @spec inference_credentials() :: %{atom() => String.t()}
  def inference_credentials do
    %{}
    |> put_present(:anthropic_api_key, System.get_env("ANTHROPIC_API_KEY"))
    |> put_present(:openai_api_key, System.get_env("OPENAI_API_KEY"))
    |> put_present(:gemini_api_key, System.get_env("GEMINI_API_KEY"))
    |> put_present(
      :claude_code_oauth_token,
      System.get_env("CLAUDE_CODE_OAUTH_TOKEN") || claude_subscription_token()
    )
  end

  @doc """
  Claude Code's subscription access token from the login keychain, or nil.

  Nil when the item is missing, unparseable, or expired — an expired token
  reaching a runtime produces an authentication failure halfway through a
  turn, which is a much worse error than "no credential" reported before a
  sandbox is created.
  """
  @spec claude_subscription_token() :: String.t() | nil
  def claude_subscription_token do
    with {:ok, body} <- Keychain.generic_password(@claude_service),
         {:ok, %{"claudeAiOauth" => oauth}} <- Jason.decode(body),
         token when is_binary(token) <- oauth["accessToken"],
         false <- expired?(oauth["expiresAt"]) do
      token
    else
      _ -> nil
    end
  end

  @doc """
  A one-line description of where each credential came from, for `goatherd
  doctor`. Values are never included, only their source and length.
  """
  @spec describe() :: [String.t()]
  def describe do
    sprites =
      case sprites_token() do
        {:ok, token} -> "sprites token: #{source(:sprites)} (#{byte_size(token)} bytes)"
        {:error, msg} -> "sprites token: MISSING — #{msg}"
      end

    creds = inference_credentials()

    inference =
      if creds == %{} do
        ["inference: MISSING — set ANTHROPIC_API_KEY, or sign in to Claude Code on this machine"]
      else
        Enum.map(creds, fn {k, v} -> "inference #{k}: present (#{byte_size(v)} bytes)" end)
      end

    [sprites | inference]
  end

  defp source(:sprites) do
    if System.get_env("SPRITES_TOKEN"), do: "SPRITES_TOKEN", else: "~/.sprites + login keychain"
  end

  defp expired?(ms) when is_integer(ms), do: ms <= System.system_time(:millisecond)
  defp expired?(_), do: false

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
