defmodule Goatherd.Keychain do
  @moduledoc """
  Read secrets the workstation has already stored, rather than asking for them
  again.

  This is the whole reason goatherd needs no configuration on a machine that
  already runs the tools it drives: the Sprites CLI and Claude Code both keep
  their credentials in the login keychain, and both are readable by the user
  who owns them.

  macOS only. On any other platform every lookup answers `:error`, which the
  callers in `Goatherd.Auth` treat as "not there" and fall back to an
  environment variable — so a Linux user sets `SPRITES_TOKEN` by hand and
  everything else behaves identically.
  """

  @doc """
  Read a generic password by service, optionally narrowed by account.

  `security` prints the secret on stdout, so this never goes through a shell
  string: the arguments are passed as a list and the output is never logged.
  A missing item is `:error`, not an exception — a caller distinguishing
  "no credential" from "broken keychain" would have nothing different to do.
  """
  @spec generic_password(String.t(), String.t() | nil) :: {:ok, String.t()} | :error
  def generic_password(service, account \\ nil) do
    if macos?() do
      args =
        case account do
          nil -> ["find-generic-password", "-s", service, "-w"]
          acct -> ["find-generic-password", "-a", acct, "-s", service, "-w"]
        end

      case System.cmd("security", args, stderr_to_stdout: false) do
        {out, 0} -> {:ok, out |> String.trim() |> unwrap()}
        _ -> :error
      end
    else
      :error
    end
  rescue
    # `security` absent or not executable. Same answer as a missing item.
    ErlangError -> :error
  end

  @doc "True on Darwin, where the `security` binary exists."
  @spec macos?() :: boolean()
  def macos?, do: match?({:unix, :darwin}, :os.type())

  # Go's `99designs/keyring` — which both the Sprites CLI and a good deal of
  # the Go ecosystem use — stores any secret that is not plain ASCII as
  # base64 behind this marker. macOS `security` hands back what was stored, so
  # the marker arrives verbatim and an undecoded value fails authentication
  # with a 401 that says nothing about why.
  @go_keyring_prefix "go-keyring-base64:"

  defp unwrap(@go_keyring_prefix <> encoded) do
    case Base.decode64(encoded) do
      {:ok, decoded} -> decoded
      :error -> encoded
    end
  end

  defp unwrap(value), do: value
end
