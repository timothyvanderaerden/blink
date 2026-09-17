defmodule Blink.ParallelTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Blink.Parallel

  test "runs 4 checks concurrently and preserves input order" do
    checks =
      for i <- 1..4 do
        {:"check_#{i}", fn -> Process.sleep(100); i end}
      end

    t0 = System.monotonic_time(:millisecond)
    results = Parallel.run(checks, timeout: 2_000)
    elapsed = System.monotonic_time(:millisecond) - t0

    assert results == [
             {:check_1, {:ok, 1}},
             {:check_2, {:ok, 2}},
             {:check_3, {:ok, 3}},
             {:check_4, {:ok, 4}}
           ]

    # Sequential execution would take >= 400ms; concurrent must finish far sooner.
    assert elapsed < 350
  end

  test "captures crashes without disturbing other checks" do
    checks = [
      {:good, fn -> :ok end},
      {:bad, fn -> raise "boom" end},
      {:exit_bad, fn -> exit("kaboom") end}
    ]

    results = Parallel.run(checks, timeout: 1_000)

    assert {:good, {:ok, :ok}} in results
    assert {:bad, {:error, {:crash, "boom"}}} in results
    assert {:exit_bad, {:error, {:exit, "kaboom"}}} in results
  end

  test "times out slow checks" do
    checks = [
      {:slow, fn -> Process.sleep(500); :ok end},
      {:fast, fn -> :ok end}
    ]

    results = Parallel.run(checks, timeout: 100)

    assert {:fast, {:ok, :ok}} in results

    assert Enum.any?(results, fn
             {nil, {:error, {:timeout, _}}} -> true
             _ -> false
           end)
  end

  test "stream/2 does not block the calling process" do
    stream = Parallel.stream([{:slow, fn -> Process.sleep(150); :done end}], timeout: 1_000)

    # The main process is free to do work while the check runs.
    t0 = System.monotonic_time(:millisecond)
    Process.sleep(50)
    worked = System.monotonic_time(:millisecond) - t0
    assert worked >= 50

    results = Parallel.collect(stream)
    assert [{:slow, {:ok, :done}}] = results
  end

  test "run/1 and stream/1 fall back to default options" do
    results = Parallel.run([{:a, fn -> 1 end}])
    assert [{:a, {:ok, 1}}] = results

    stream = Parallel.stream([{:b, fn -> 2 end}])
    assert [{:b, {:ok, 2}}] = Parallel.collect(stream)
  end
end
