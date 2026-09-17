defmodule Blink.GateTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Blink.{Gate, Test.Fixtures}
  alias Blink.Test.Schemas.{Safety, Triage}

  setup do
    bypass = Bypass.open()
    on_exit(fn -> Bypass.down(bypass) end)
    [bypass: bypass]
  end

  defp config(bypass, overrides \\ []) do
    Map.merge(
      %{
        endpoint: "http://127.0.0.1:#{bypass.port}/v1",
        model: "qwen2.5:1.5b",
        min_confidence: 0.70
      },
      Map.new(overrides)
    )
  end

  test "high confidence + valid schema is handled locally", %{bypass: bypass} do
    Fixtures.stub(
      bypass,
      Fixtures.chat_body(Fixtures.triage_content(), Fixtures.high_confidence_tokens())
    )

    assert {:ok, result} = Gate.run("What is the weather?", Triage, config(bypass))

    assert %Blink.Result{
             status: :handled_locally,
             data: %Triage{intent: "simple_query", requires_system_2: false},
             confidence: confidence,
             low_confidence?: false,
             intent: "simple_query",
             requires_system_2: false,
             reason: nil,
             schema: Triage,
             model: "qwen2.5:1.5b",
             latency_ms: latency
           } = result

    assert confidence > 0.9
    assert latency >= 0
    assert Blink.Result.handled_locally?(result)
  end

  test "low confidence escalates to System 2", %{bypass: bypass} do
    Fixtures.stub(
      bypass,
      Fixtures.chat_body(Fixtures.triage_content("unclear", true), Fixtures.low_confidence_tokens())
    )

    assert {:ok, result} = Gate.run("Hm, tricky question", Triage, config(bypass))

    assert result.status == :escalate_to_system_2
    assert result.reason == :low_confidence
    assert result.low_confidence? == true
    assert result.requires_system_2 == true
    assert result.data.intent == "unclear"
    refute Blink.Result.handled_locally?(result)
  end

  test "schema validation failure escalates to System 2", %{bypass: bypass} do
    Fixtures.stub(
      bypass,
      Fixtures.chat_body(Fixtures.triage_content("bogus_intent"), Fixtures.high_confidence_tokens())
    )

    assert {:ok, result} = Gate.run("Whatever", Triage, config(bypass))

    assert result.status == :escalate_to_system_2
    assert result.data == nil
    assert result.requires_system_2 == true
    assert {:schema_invalid, errors} = result.reason
    assert {"is invalid", [validation: :inclusion, enum: _]} = errors[:intent]
  end

  test "client errors surface as {:error, {:client_error, reason}}", %{bypass: bypass} do
    _ = bypass

    assert {:error, {:client_error, {:transport_error, _}}} =
             Gate.run("hi", Triage, config(%{port: 9}))
  end

  test "invalid JSON content surfaces as a client error", %{bypass: bypass} do
    Fixtures.stub(bypass, Fixtures.chat_body("not json", []))

    assert {:error, {:client_error, :invalid_json}} = Gate.run("hi", Triage, config(bypass))
  end

  test "schemas without an intent field yield nil intent", %{bypass: bypass} do
    Fixtures.stub(
      bypass,
      Fixtures.chat_body(Fixtures.safety_content(), Fixtures.high_confidence_tokens())
    )

    assert {:ok, result} = Gate.run("Is this safe?", Safety, config(bypass))

    assert result.status == :handled_locally
    assert result.intent == nil
    assert result.data.safe == true
    assert result.data.flags == []
  end

  test "requires_system_2 falls back to the status when the field is absent", %{bypass: bypass} do
    Fixtures.stub(
      bypass,
      Fixtures.chat_body(Fixtures.safety_content(), Fixtures.low_confidence_tokens())
    )

    assert {:ok, result} = Gate.run("Is this safe?", Safety, config(bypass))
    assert result.status == :escalate_to_system_2
    assert result.requires_system_2 == true
  end

  describe "build_messages/2 and system_prompt/1" do
    test "builds a strict JSON-only system prompt with the schema fields" do
      [system, user] = Gate.build_messages("the prompt", Triage)

      assert system["role"] == "system"
      assert user == %{"role" => "user", "content" => "the prompt"}

      prompt = system["content"]
      assert prompt =~ "JSON object"
      assert prompt =~ "intent"
      assert prompt =~ "requires_system_2"
      assert prompt =~ "extracted_entities"
      assert prompt =~ "reasoning_summary"
    end
  end
end
