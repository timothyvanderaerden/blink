defmodule Blink.ResultTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Blink.Result

  test "handled_locally?/1" do
    assert Result.handled_locally?(%Result{status: :handled_locally})
    refute Result.handled_locally?(%Result{status: :escalate_to_system_2})
  end

  test "defaults to a blank result" do
    result = %Result{}

    assert result.status == nil
    assert result.data == nil
    assert result.confidence == nil
    assert result.low_confidence? == nil
    assert result.intent == nil
    assert result.requires_system_2 == nil
    assert result.reason == nil
    assert result.schema == nil
    assert result.model == nil
    assert result.latency_ms == nil
    assert result.winner == nil
    assert result.checks == nil
  end
end
