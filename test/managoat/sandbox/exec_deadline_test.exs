defmodule Managoat.Sandbox.ExecDeadlineTest do
  use ExUnit.Case, async: true

  alias Managoat.Sandbox.ExecDeadline

  test "finite deadlines keep the original timeout and use monotonic milliseconds" do
    before = System.monotonic_time(:millisecond)
    assert {100, expires_at} = deadline = ExecDeadline.new(100)
    assert expires_at >= before + 100
    assert expires_at <= System.monotonic_time(:millisecond) + 100
    assert ExecDeadline.remaining(deadline) in 1..100
    assert ExecDeadline.check(deadline) == :ok
    assert ExecDeadline.error(deadline) == {:error, {:unavailable, {:exec_timeout, 100}}}
  end

  test "zero and expired deadlines refuse work while infinity stays unbounded" do
    assert ExecDeadline.remaining(ExecDeadline.new(0)) == 0

    assert ExecDeadline.check({10, System.monotonic_time(:millisecond) - 1}) ==
             {:error, {:unavailable, {:exec_timeout, 10}}}

    deadline = ExecDeadline.new(:infinity)
    assert ExecDeadline.remaining(deadline) == :infinity
    assert ExecDeadline.check(deadline) == :ok
  end
end

defmodule Managoat.Sandbox.ExecCollectionDeadlineTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Managoat.Sandbox.ExecDeadline
  alias Managoat.Sandbox.Sprites, as: SpritesAdapter

  for adapter <- [SpritesAdapter] do
    @adapter adapter

    for {frame, merge_stderr} <- [{:stdout, false}, {:stderr, false}, {:stderr, true}] do
      @frame frame
      @merge_stderr merge_stderr
      test "#{inspect(adapter)} #{@frame} output (merge=#{@merge_stderr}) cannot renew timeout" do
        stub_start(@adapter, fn owner, ref ->
          spawn(fn ->
            for _ <- 1..12 do
              send(owner, {@frame, %{ref: ref}, "chunk"})
              Process.sleep(10)
            end

            send(owner, {:exit, %{ref: ref}, 0})
          end)
        end)

        assert {:error, {:unavailable, {:exec_timeout, 40}}} =
                 @adapter.exec(@adapter.build_handle("deadline-test"), "probe", [],
                   timeout: 40,
                   stderr_to_stdout: @merge_stderr
                 )

        assert_receive {:collector, pid, monitor}
        assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
      end
    end

    test "#{inspect(adapter)} stops queued frames before another receive when budget expires" do
      # Move only the collector's view of remaining time. The deadline object
      # must be the same for each frame, and frames already in the mailbox must
      # not win against an expired budget as they would with `receive after 0`.
      deadline = {1_000, System.monotonic_time(:millisecond) + 1_000}
      expect(ExecDeadline, :new, fn 1_000 -> deadline end)
      {:ok, frames} = Agent.start_link(fn -> 0 end)

      stub(ExecDeadline, :remaining, fn ^deadline ->
        Agent.get_and_update(frames, fn
          3 -> {0, 3}
          n -> {1_000, n + 1}
        end)
      end)

      stub_start(@adapter, fn owner, ref ->
        for _ <- 1..10, do: send(owner, {:stdout, %{ref: ref}, "queued"})
        send(owner, {:exit, %{ref: ref}, 0})
        spawn(fn -> Process.sleep(:infinity) end)
      end)

      assert {:error, {:unavailable, {:exec_timeout, 1_000}}} =
               @adapter.exec(@adapter.build_handle("deadline-test"), "probe", [], timeout: 1_000)

      assert Agent.get(frames, & &1) == 3
      assert_receive {:collector, pid, monitor}
      assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
    end

    test "#{inspect(adapter)} does not accept queued success after startup exhausts the deadline" do
      stub_start(@adapter, fn owner, ref ->
        Process.sleep(20)
        send(owner, {:stdout, %{ref: ref}, "too late"})
        send(owner, {:exit, %{ref: ref}, 0})
        spawn(fn -> Process.sleep(:infinity) end)
      end)

      assert {:error, {:unavailable, {:exec_timeout, 1}}} =
               @adapter.exec(@adapter.build_handle("deadline-test"), "probe", [], timeout: 1)
    end

    test "#{inspect(adapter)} rechecks the deadline after receiving terminal success" do
      # The terminal frame can become runnable before the deadline and only be
      # handled after it. Neither startup nor a successful receive grants time.
      {:ok, checks} = Agent.start_link(fn -> 0 end)
      initial_checks = 1

      stub(ExecDeadline, :check, fn deadline ->
        n = Agent.get_and_update(checks, &{&1, &1 + 1})
        if n < initial_checks, do: :ok, else: ExecDeadline.error(deadline)
      end)

      stub_start(@adapter, fn owner, ref ->
        send(owner, {:exit, %{ref: ref}, 0})
        spawn(fn -> Process.sleep(:infinity) end)
      end)

      assert {:error, {:unavailable, {:exec_timeout, 1_000}}} =
               @adapter.exec(@adapter.build_handle("deadline-test"), "probe", [], timeout: 1_000)
    end

    test "#{inspect(adapter)} zero timeout does not dispatch" do
      stub(Sprites, :spawn, fn _, _, _, _ -> flunk("must not dispatch") end)

      assert {:error, {:unavailable, {:exec_timeout, 0}}} =
               @adapter.exec(@adapter.build_handle("deadline-test"), "probe", [], timeout: 0)
    end

    test "#{inspect(adapter)} accepts timely finite success and preserves infinity" do
      stub_start(@adapter, fn owner, ref ->
        send(owner, {:stdout, %{ref: ref}, "out"})
        send(owner, {:stderr, %{ref: ref}, "err"})
        send(owner, {:exit, %{ref: ref}, 3})
        spawn(fn -> :ok end)
      end)

      for timeout <- [1_000, :infinity] do
        assert {:ok, "outerr", 3} =
                 @adapter.exec(@adapter.build_handle("deadline-test"), "probe", [],
                   timeout: timeout,
                   stderr_to_stdout: true
                 )
      end
    end
  end

  defp stub_start(SpritesAdapter, start) do
    stub(Managoat.Sandbox.Sprites.Client, :get!, fn -> %Sprites.Client{token: "test-token"} end)

    stub(Sprites, :spawn, fn _sprite, _command, _args, opts ->
      ref = make_ref()
      pid = start.(opts[:owner], ref)
      track_collector(pid)
      {:ok, %Sprites.Command{ref: ref, pid: pid}}
    end)
  end

  defp track_collector(pid) do
    send(self(), {:collector, pid, Process.monitor(pid)})
    on_exit(fn -> Process.exit(pid, :kill) end)
  end
end
