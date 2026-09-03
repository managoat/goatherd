defmodule Goatherd.Driver do
  @moduledoc """
  One turn, driven from this process.

  The shape is the smallest thing that can honestly be called a control plane:
  create a sandbox, provision it, spawn the ACP adapter as a *detachable*
  command, hand its stdin to a `Managoat.ACP.Peer` as the peer's writer, and
  forward the sandbox's stdout messages into the peer until it reports the
  turn done. Everything the peer reports is rendered as it arrives and appended
  to a transcript file.

  Detachable is the load-bearing option. It means the adapter keeps running in
  the sandbox when this process exits, which is what lets `goatherd attach`
  rejoin a turn whose driver was interrupted, and what makes the pointer file
  in `Goatherd.State` sufficient as durable state.

  ## Why the driver is the CLI process rather than a GenServer

  There is exactly one turn per invocation and the terminal is its only
  consumer. A supervised process would add a mailbox between the peer and the
  screen without adding a way to recover from anything: if this process dies
  the turn is unattended either way, and the sandbox — not this — is what
  holds the state that matters.
  """

  alias Goatherd.{Config, Provision, Render, State}
  alias Goatherd.Runs.Run
  alias Managoat.ACP.{Blocks, Peer}
  alias Managoat.Runtimes
  alias Managoat.Sandbox

  # How long the driver waits with nothing at all arriving before it gives up
  # and leaves the turn running remotely. Generous: a long tool call is
  # silent, and abandoning a turn that was about to answer is worse than
  # waiting.
  @idle_timeout_ms 20 * 60 * 1000

  @type result :: {:ok, Run.t()} | {:error, term()}

  @doc """
  Start a new run: fresh sandbox, first turn.

  Options: `:quiet`, `:yes` (answer every permission with the agent's first
  allow option), `:rm` (destroy the sandbox when the turn ends rather than
  leaving it up for a follow-up turn).
  """
  @spec start(String.t(), Config.t(), keyword()) :: result()
  def start(prompt, %Config{} = config, opts \\ []) do
    id = Run.new_id()

    run = %Run{
      id: id,
      sandbox: Run.sandbox_name(id),
      provider: :sprites,
      runtime: config.runtime,
      prompt: prompt,
      cwd: Runtimes.ACP.cwd(config.runtime),
      status: :starting,
      created_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      workdir: File.cwd!(),
      transcript: Path.join(Goatherd.transcript_dir(), "#{id}.ndjson")
    }

    State.put(run)
    render = Render.new(quiet: opts[:quiet])

    Render.header(render, "run #{id} · #{config.runtime} · sandbox #{run.sandbox}")

    with {:ok, handle} <- create(run, render),
         {:ok, sprite_env} <- provision(handle, config, render),
         {:ok, command} <- spawn_adapter(handle, config, sprite_env),
         {:ok, peer} <- open_peer(command, config, prompt, opts) do
      State.merge(id, %{status: "running"})
      loop(context(run, handle, command, peer, render, opts))
    else
      {:error, reason} ->
        State.merge(id, %{status: "failed"})
        {:error, reason}
    end
  end

  defp context(run, handle, command, peer, render, opts) do
    %{
      run: run,
      handle: handle,
      command: command,
      peer: peer,
      render: render,
      opts: opts,
      stderr: "",
      replayed: nil
    }
  end

  # Bounded: an adapter that fails in a loop can produce megabytes, and only
  # the end of it says anything.
  @stderr_keep 4_000
  defp keep_tail(buffer, data) do
    combined = buffer <> to_string(data)

    if byte_size(combined) > @stderr_keep do
      binary_part(combined, byte_size(combined) - @stderr_keep, @stderr_keep)
    else
      combined
    end
  end

  @doc """
  Send another turn to a run whose sandbox is still up.

  A new connection is opened and the agent's own session is resumed, so the
  agent keeps its context. That is `mode: :continue` plus the session id the
  first turn recorded — the same path Fountain takes after a deploy.
  """
  @spec continue(Run.t(), String.t(), Config.t(), keyword()) :: result()
  def continue(%Run{session_id: nil}, _prompt, _config, _opts),
    do: {:error, "that run never opened a session, so there is nothing to continue"}

  def continue(%Run{} = run, prompt, %Config{} = config, opts) do
    # The runtime is a property of the run, not of the herd file in front of
    # us: the session we are about to resume was opened by that runtime's
    # adapter, and spawning a different one against it resumes nothing.
    config = %{config | runtime: run.runtime || config.runtime}
    render = Render.new(quiet: opts[:quiet])
    Render.header(render, "run #{run.id} · continue")

    with {:ok, handle} <- adopt(run),
         {:ok, sprite_env} <- rebuild_env(config),
         {:ok, command} <- spawn_adapter(handle, config, sprite_env),
         {:ok, peer} <-
           open_peer(command, config, prompt, Keyword.put(opts, :resume, run.session_id)) do
      State.merge(run.id, %{status: "running", prompt: prompt})
      loop(context(run, handle, command, peer, render, opts))
    end
  end

  @doc """
  Rejoin a turn that is still in flight in its sandbox.

  Finds the adapter's detachable session, attaches to it and starts a peer in
  `attach:` mode with the prompt id the original driver recorded. Without that
  id the peer cannot tell the prompt's answer from a replayed handshake
  response, which is why `:prompt_id` is persisted the moment it is known.
  """
  @spec attach(Run.t(), keyword()) :: result()
  def attach(%Run{prompt_id: nil}, _opts),
    do: {:error, "that run has no outstanding prompt to attach to"}

  def attach(%Run{} = run, opts) do
    render = Render.new(quiet: opts[:quiet])
    Render.header(render, "run #{run.id} · attaching")

    with {:ok, handle} <- adopt(run),
         {:ok, session} <- newest_session(handle),
         {:ok, command} <- Sandbox.attach(handle, session, owner: self()),
         {:ok, peer} <-
           Peer.start(
             owner: self(),
             writer: writer(command),
             ref: make_ref(),
             prompt: run.prompt,
             mode: :continue,
             session_id: run.session_id,
             cwd: run.cwd,
             attach: run.prompt_id
           ) do
      ctx = context(run, handle, command, peer, render, opts)
      loop(%{ctx | replayed: seen_lines(run)})
    end
  end

  # A sandbox that replays on attach replays the *tail* — Sprites sends one
  # 16 KiB chunk starting mid-line — and `Managoat.ACP.Peer` drops the partial
  # first line but leaves de-duplication to its owner, by content. We are the
  # owner: without this, `goatherd attach` re-renders and re-appends every
  # tool call the interrupted driver already showed.
  #
  # The set is consulted only until the first line we have never seen, which
  # is where the replay ends and the live stream begins. Bounding it there
  # matters: an agent legitimately repeats itself, and a set consulted for the
  # whole turn would swallow a genuine second identical tool call.
  defp seen_lines(%Run{transcript: nil}), do: nil

  defp seen_lines(%Run{transcript: path}) do
    case File.read(path) do
      {:ok, body} -> body |> String.split("\n", trim: true) |> MapSet.new()
      _ -> nil
    end
  end

  # ── setup ────────────────────────────────────────────────────────────────

  defp create(%Run{} = run, render) do
    Render.stage(render, "sandbox", "started")

    case Sandbox.create(run.provider, run.sandbox) do
      {:ok, handle} ->
        Render.stage(render, "sandbox", "done")
        {:ok, handle}

      {:error, reason} ->
        Render.stage(render, "sandbox", "failed")
        {:error, {:sandbox_create, reason}}
    end
  end

  defp adopt(%Run{} = run) do
    handle = Sandbox.build_handle(run.provider, run.sandbox)

    case Sandbox.get(handle) do
      {:ok, _info} -> {:ok, handle}
      {:error, :not_found} -> {:error, "sandbox #{run.sandbox} is gone"}
      {:error, reason} -> {:error, {:sandbox_get, reason}}
    end
  end

  defp provision(handle, config, render) do
    on_stage = fn name, status -> Render.stage(render, name, status) end
    Provision.run(handle, config, Goatherd.Auth.inference_credentials(), on_stage)
  end

  defp rebuild_env(config) do
    {:ok, runtime_mod} = Runtimes.for_runtime(config.runtime)

    {:ok,
     Provision.sprite_env(
       config,
       runtime_mod,
       Config.agent(config),
       Goatherd.Auth.inference_credentials()
     )}
  end

  defp spawn_adapter(handle, %Config{runtime: runtime}, sprite_env) do
    {bin, args} = Runtimes.ACP.command(runtime)

    # `stdin: true` is not optional on this path and its absence does not look
    # like an error: an ACP adapter whose stdin is closed reads EOF and exits
    # 0, which arrives here as a healthy command that ended before the turn.
    # Stdin stays open for the whole turn because it is the return path for
    # permission answers and cancellation, not just the prompt.
    trace(
      "== ",
      "spawn #{bin} env=" <>
        Enum.map_join(sprite_env, ",", fn {k, v} -> "#{k}:#{byte_size(v)}" end)
    )

    case Sandbox.spawn(handle, bin, args,
           owner: self(),
           env: sprite_env,
           dir: Sandbox.host_path(handle, Runtimes.ACP.cwd(runtime)),
           stdin: true,
           detachable: true
         ) do
      {:ok, command} -> {:ok, command}
      {:error, reason} -> {:error, {:adapter_spawn, reason}}
    end
  end

  defp open_peer(command, %Config{} = config, prompt, opts) do
    resume = opts[:resume]

    Peer.start(
      owner: self(),
      writer: writer(command),
      ref: make_ref(),
      prompt: prompt,
      mode: if(resume, do: :continue, else: :run),
      session_id: resume,
      cwd: Runtimes.ACP.cwd(config.runtime),
      model: config.model,
      mcp_servers: Runtimes.ACP.mcp_servers(Config.agent(config)),
      permission_policy: policy(config, opts)
    )
  end

  # The writer must be total: a command whose transport has gone answers
  # `{:error, _}` rather than raising, so the peer reports one failure instead
  # of dying with a turn in flight.
  defp writer(command) do
    fn iodata ->
      trace(">> ", IO.iodata_to_binary(iodata))
      Sandbox.write_stdin(command, iodata)
    end
  end

  @doc """
  Append one framed line to the wire trace when `GOATHERD_TRACE` names a file.

  A protocol conversation is the one thing here that cannot be reconstructed
  after the fact from what the terminal showed: the render path deliberately
  drops everything that is not a block, which is most of what goes wrong.
  """
  @spec trace(String.t(), binary()) :: :ok
  def trace(direction, data) do
    case System.get_env("GOATHERD_TRACE") do
      nil -> :ok
      path -> File.write!(path, [direction, String.trim_trailing(data), "\n"], [:append])
    end
  end

  @doc """
  The effective per-tool permission policy.

  Default is Fountain's: allow everything except running commands, and ask
  about those. `--yes` flattens it to allow-all, which is what an unattended
  run needs and what a watched one should not have.
  """
  @spec policy(Config.t(), keyword()) :: map()
  def policy(%Config{permissions: permissions}, opts) do
    cond do
      opts[:yes] -> %{"default" => "auto_allow"}
      permissions == %{} -> %{"default" => "auto_allow", "execute" => "ask"}
      true -> Map.new(permissions, fn {k, v} -> {to_string(k), to_string(v)} end)
    end
  end

  # `list_sessions/1` promises a list, not an order — sorting here rather than
  # taking the head is the difference between attaching to this turn's adapter
  # and attaching to one a previous turn left behind on the same sandbox.
  defp newest_session(handle) do
    case Sandbox.list_sessions(handle) do
      {:ok, []} ->
        {:error, "the sandbox has no detachable session; the adapter has exited"}

      {:ok, sessions} ->
        {:ok, sessions |> Enum.max_by(&session_age/1) |> Map.fetch!(:id)}

      {:error, reason} ->
        {:error, {:list_sessions, reason}}
    end
  end

  @doc """
  Sort key for picking the session to attach to: last activity, else creation.

  Comparable across the shapes an adapter may use — a `DateTime`, an ISO 8601
  string, or nothing at all — because the field is not in the behaviour's
  contract and only the ordering matters here.
  """
  @spec session_age(map()) :: String.t()
  def session_age(session) do
    case Map.get(session, :last_activity_at) || Map.get(session, :created_at) do
      %DateTime{} = at -> DateTime.to_iso8601(at)
      at when is_binary(at) -> at
      _ -> ""
    end
  end

  # ── the loop ─────────────────────────────────────────────────────────────

  defp loop(ctx) do
    receive do
      {:stdout, %{ref: ref}, data} when ref == ctx.command.ref ->
        trace("<< ", data)
        Peer.stdout(ctx.peer, data)
        loop(ctx)

      # The adapter's own diagnostics. Never protocol, so never fed to the
      # peer — but kept, because when a turn fails the adapter has usually
      # already said why on stderr and discarding it leaves only the
      # protocol-level symptom.
      {:stderr, %{ref: ref}, data} when ref == ctx.command.ref ->
        trace("!! ", data)
        loop(%{ctx | stderr: keep_tail(ctx.stderr, data)})

      {:exit, %{ref: ref}, code} when ref == ctx.command.ref ->
        finish(ctx, {:error, "the agent adapter exited (#{code}) before the turn ended"})

      {:error, %{ref: ref}, reason} when ref == ctx.command.ref ->
        finish(ctx, {:error, {:transport, reason}})

      {:acp, _ref, payload} ->
        case handle_acp(ctx, payload) do
          {:cont, ctx} -> loop(ctx)
          {:halt, result} -> finish(ctx, result)
        end
    after
      @idle_timeout_ms ->
        Render.note(
          "\nnothing for #{div(@idle_timeout_ms, 60_000)} minutes — leaving the turn running."
        )

        Render.note("rejoin it with: goatherd attach #{ctx.run.id}")
        {:ok, ctx.run}
    end
  end

  defp handle_acp(ctx, {:lines, _stream, data}) do
    {fresh, replayed} = drop_replayed(String.split(data, "\n", trim: true), ctx.replayed)

    Enum.each(fresh, &append_transcript(ctx.run, &1 <> "\n"))

    render =
      fresh
      |> Enum.flat_map(&Blocks.from_line/1)
      |> Enum.reduce(ctx.render, &Render.block(&2, &1))

    {:cont, %{ctx | render: render, replayed: replayed}}
  end

  defp handle_acp(ctx, {:session, session_id}) do
    State.merge(ctx.run.id, %{session_id: session_id})
    {:cont, %{ctx | run: %{ctx.run | session_id: session_id}}}
  end

  defp handle_acp(ctx, {:prompt_sent, id}) do
    State.merge(ctx.run.id, %{prompt_id: id})
    {:cont, %{ctx | run: %{ctx.run | prompt_id: id}}}
  end

  defp handle_acp(ctx, {:permission_ask, request_id, tool, options}) do
    {:cont, %{ctx | render: ask_permission(ctx, request_id, tool, options)}}
  end

  defp handle_acp(ctx, {:permission_denied, tool, verdict}) do
    render = Render.break(ctx.render)
    Render.note("  denied #{tool || "tool"} (#{verdict})")
    {:cont, %{ctx | render: render}}
  end

  defp handle_acp(ctx, {:model_rejected, requested, detail}) do
    render = Render.break(ctx.render)
    Render.note("  model #{requested} refused: #{detail} — the agent picked its own")
    {:cont, %{ctx | render: render}}
  end

  defp handle_acp(_ctx, {:done, stop_reason, usage}) do
    {:halt, {:done, stop_reason, usage}}
  end

  defp handle_acp(_ctx, {:failed, reason}), do: {:halt, {:error, reason}}

  # `handshake_ms` and `cycle_end` are accounting for a host that keeps turn
  # records. There is no turn record here, and a line about either would be
  # noise in a transcript a human is reading.
  defp handle_acp(ctx, _payload), do: {:cont, ctx}

  @doc """
  Split a replayed prefix off the front of an attached stream.

  Returns the lines to act on and the set to carry forward. `nil` for the set
  means "replay is over" — reached as soon as a line arrives that we have not
  seen, which is where the sandbox's buffer ends and the live stream begins.

  Bounded there on purpose: an agent legitimately repeats itself, and a set
  consulted for the whole turn would swallow a genuine second identical tool
  call.
  """
  @spec drop_replayed([String.t()], MapSet.t() | nil) :: {[String.t()], MapSet.t() | nil}
  def drop_replayed(lines, nil), do: {lines, nil}

  def drop_replayed(lines, seen) do
    case Enum.split_while(lines, &MapSet.member?(seen, &1)) do
      {_dropped, []} -> {[], seen}
      {_dropped, rest} -> {rest, nil}
    end
  end

  defp ask_permission(ctx, request_id, tool, options) do
    render = Render.break(ctx.render)

    cond do
      ctx.opts[:yes] ->
        answer(ctx, request_id, first_allow(options))
        render

      options == [] ->
        Peer.deny_permission(ctx.peer, request_id)
        render

      true ->
        prompt_for_option(ctx, request_id, tool, options)
        render
    end
  end

  defp prompt_for_option(ctx, request_id, tool, options) do
    IO.puts("")
    IO.puts("  #{tool || "the agent"} wants permission:")

    options
    |> Enum.with_index(1)
    |> Enum.each(fn {option, index} ->
      IO.puts("    #{index}) #{option["name"] || option["optionId"]}")
    end)

    choice = IO.gets("  choose [1-#{length(options)}, or enter to deny]: ")

    case parse_choice(choice, options) do
      {:ok, option} -> answer(ctx, request_id, option["optionId"])
      :deny -> Peer.deny_permission(ctx.peer, request_id)
    end
  end

  defp parse_choice(input, options) when is_binary(input) do
    case input |> String.trim() |> Integer.parse() do
      {n, ""} when n >= 1 -> pick(options, n - 1)
      _ -> :deny
    end
  end

  # stdin closed (a piped run) is a denial, not a crash.
  defp parse_choice(_, _), do: :deny

  defp pick(options, index) do
    case Enum.at(options, index) do
      nil -> :deny
      option -> {:ok, option}
    end
  end

  defp answer(ctx, request_id, nil), do: Peer.deny_permission(ctx.peer, request_id)

  defp answer(ctx, request_id, option_id) do
    Peer.answer_permission(ctx.peer, request_id, option_id)
  end

  # The agent supplies the options and their order; a client must never invent
  # one. "First allow-shaped option" is the most permissive thing that is still
  # only choosing from what was offered.
  defp first_allow(options) do
    option =
      Enum.find(options, fn option ->
        kind = to_string(option["kind"] || "")
        String.starts_with?(kind, "allow")
      end) || List.first(options)

    option && option["optionId"]
  end

  # ── teardown ─────────────────────────────────────────────────────────────

  defp finish(ctx, {:done, stop_reason, usage}) do
    Render.footer(ctx.render, stop_reason, usage)
    State.merge(ctx.run.id, %{status: "done", stop_reason: stop_reason})
    close(ctx)
    Render.note(closing_note(ctx))
    {:ok, %{ctx.run | status: :done, stop_reason: stop_reason}}
  end

  defp finish(ctx, {:error, reason}) do
    Render.break(ctx.render)
    State.merge(ctx.run.id, %{status: "failed"})
    close(ctx)

    case String.trim(ctx.stderr) do
      "" -> {:error, reason}
      tail -> {:error, "#{inspect(reason)}\n\nthe agent adapter said:\n#{tail}"}
    end
  end

  defp close(ctx) do
    Peer.close(ctx.peer)
    Sandbox.stop_command(ctx.command)

    if ctx.opts[:rm] do
      Sandbox.destroy(ctx.handle)
      State.merge(ctx.run.id, %{status: "done", sandbox_destroyed: true})
    end

    :ok
  end

  defp closing_note(ctx) do
    if ctx.opts[:rm] do
      "sandbox destroyed."
    else
      "sandbox #{ctx.run.sandbox} is still up — `goatherd say #{ctx.run.id} \"…\"` to keep going, `goatherd rm #{ctx.run.id}` to destroy it."
    end
  end

  defp append_transcript(%Run{transcript: nil}, _data), do: :ok

  defp append_transcript(%Run{transcript: path}, data) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, data, [:append])
  end
end
