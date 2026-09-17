defmodule Blink.Test.Fixtures do
  @moduledoc false

  @doc "A single logprob entry as found in `logprobs.content`."
  def token(token, logprob) do
    %{"token" => token, "logprob" => logprob, "top_logprobs" => []}
  end

  @doc """
  Tokens for a confident triage answer.

  Kept (non-structural) tokens: -0.02, -0.03, -0.02, -0.04
  => confidence exp(-0.0275) ≈ 0.9729
  """
  def high_confidence_tokens do
    [
      token("{", -0.01),
      token("\"intent\"", -0.02),
      token(": ", -0.01),
      token("\"simple_query\"", -0.03),
      token(", \"requires_system_2\": ", -0.02),
      token("false", -0.04),
      token("}", -0.01)
    ]
  end

  @doc """
  Tokens for an uncertain triage answer.

  Kept (non-structural) tokens: -0.02, -1.5, -0.02, -1.6
  => confidence exp(-0.785) ≈ 0.4561
  """
  def low_confidence_tokens do
    [
      token("{", -0.01),
      token("\"intent\"", -0.02),
      token(": ", -0.01),
      token("\"unclear\"", -1.5),
      token(", \"requires_system_2\": ", -0.02),
      token("true", -1.6),
      token("}", -0.01)
    ]
  end

  @doc "A full OpenAI-compatible chat completion body."
  def chat_body(content, logprob_entries, model \\ "qwen2.5:1.5b") do
    %{
      "id" => "chatcmpl-test",
      "object" => "chat.completion",
      "created" => 1_700_000_000,
      "model" => model,
      "choices" => [
        %{
          "index" => 0,
          "message" => %{"role" => "assistant", "content" => content},
          "logprobs" => %{"content" => logprob_entries},
          "finish_reason" => "stop"
        }
      ],
      "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 20, "total_tokens" => 30}
    }
  end

  @doc "JSON content for the Triage schema."
  def triage_content(intent \\ "simple_query", requires_system_2 \\ false) do
    Jason.encode!(%{
      "intent" => intent,
      "requires_system_2" => requires_system_2,
      "extracted_entities" => [],
      "reasoning_summary" => "deterministic test decision"
    })
  end

  @doc "JSON content for the Safety schema."
  def safety_content(safe \\ true, flags \\ []) do
    Jason.encode!(%{"safe" => safe, "flags" => flags})
  end

  @doc "Registers a one-shot expectation on the bypass server."
  def stub(bypass, body, status \\ 200) do
    Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
      {:ok, _raw, conn} = Plug.Conn.read_body(conn)

      Plug.Conn.put_resp_content_type(conn, "application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end)
  end
end
