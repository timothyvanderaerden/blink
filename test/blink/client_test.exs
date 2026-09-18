defmodule Blink.ClientTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Blink.Client
  alias Blink.Test.Fixtures

  setup do
    bypass = Bypass.open()
    on_exit(fn -> Bypass.down(bypass) end)
    [bypass: bypass]
  end

  defp config(bypass) do
    %{endpoint: "http://127.0.0.1:#{bypass.port}/v1", model: "qwen2.5:1.5b"}
  end

  defp messages do
    [
      %{"role" => "system", "content" => "json only"},
      %{"role" => "user", "content" => "hi"}
    ]
  end

  test "sends a logprobs request and parses the completion", %{bypass: bypass} do
    test_pid = self()

    Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request, raw})

      Plug.Conn.put_resp_content_type(conn, "application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(Fixtures.chat_body(Fixtures.triage_content(), Fixtures.high_confidence_tokens()))
      )
    end)

    assert {:ok, params, logprob_entries} = Client.complete(config(bypass), messages())

    assert_receive {:request, raw}

    req = Jason.decode!(raw)
    assert req["model"] == "qwen2.5:1.5b"
    assert req["logprobs"] == true
    assert req["top_logprobs"] == 5
    assert req["temperature"] == 0
    assert req["response_format"] == %{"type" => "json_object"}
    assert req["messages"] == messages()

    assert params["intent"] == "simple_query"
    assert length(logprob_entries) == 7
    assert hd(logprob_entries)["token"] == "{"
  end

  test "honours config and option overrides", %{bypass: bypass} do
    test_pid = self()

    Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request, raw})

      Plug.Conn.put_resp_content_type(conn, "application/json")
      |> Plug.Conn.resp(200, Jason.encode!(Fixtures.chat_body("{}", [])))
    end)

    conf = %{
      endpoint: "http://127.0.0.1:#{bypass.port}/v1/",
      model: "llama3.2:3b",
      temperature: 0.2,
      extra_body: %{"seed" => 42}
    }

    assert {:ok, _, _} = Client.complete(conf, messages(), top_logprobs: 9)

    assert_receive {:request, raw}
    req = Jason.decode!(raw)
    assert req["model"] == "llama3.2:3b"
    assert req["temperature"] == 0.2
    assert req["top_logprobs"] == 9
    assert req["seed"] == 42
  end

  test "sends :extra_headers from the config", %{bypass: bypass} do
    test_pid = self()

    Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
      send(test_pid, {:headers, Plug.Conn.get_req_header(conn, "authorization")})

      Plug.Conn.put_resp_content_type(conn, "application/json")
      |> Plug.Conn.resp(200, Jason.encode!(Fixtures.chat_body("{}", [])))
    end)

    conf = %{
      endpoint: "http://127.0.0.1:#{bypass.port}/v1",
      model: "qwen2.5:1.5b",
      extra_headers: [{"Authorization", "Bearer sk-from-config"}]
    }

    assert {:ok, _, _} = Client.complete(conf, messages())
    assert_receive {:headers, ["Bearer sk-from-config"]}
  end

  test "option :extra_headers overrides the config", %{bypass: bypass} do
    test_pid = self()

    Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
      send(test_pid, {:headers, Plug.Conn.get_req_header(conn, "authorization")})

      Plug.Conn.put_resp_content_type(conn, "application/json")
      |> Plug.Conn.resp(200, Jason.encode!(Fixtures.chat_body("{}", [])))
    end)

    conf = %{
      endpoint: "http://127.0.0.1:#{bypass.port}/v1",
      model: "qwen2.5:1.5b",
      extra_headers: [{"Authorization", "Bearer sk-from-config"}]
    }

    assert {:ok, _, _} =
             Client.complete(conf, messages(),
               extra_headers: [{"Authorization", "Bearer sk-from-opts"}]
             )

    assert_receive {:headers, ["Bearer sk-from-opts"]}
  end

  test "returns :http_error for non-2xx responses", %{bypass: bypass} do
    Fixtures.stub(bypass, %{"error" => "bad request"}, 400)

    assert {:error, {:http_error, 400, body}} = Client.complete(config(bypass), messages())
    assert body["error"] == "bad request"
  end

  test "returns :invalid_json when the whole body is not JSON", %{bypass: bypass} do
    Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
      {:ok, _raw, conn} = Plug.Conn.read_body(conn)

      Plug.Conn.put_resp_content_type(conn, "text/plain")
      |> Plug.Conn.resp(200, "not json at all")
    end)

    assert {:error, :invalid_json} = Client.complete(config(bypass), messages())
  end

  test "decodes binary bodies when the response is not application/json", %{bypass: bypass} do
    Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
      {:ok, _raw, conn} = Plug.Conn.read_body(conn)

      Plug.Conn.put_resp_content_type(conn, "text/plain")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(Fixtures.chat_body(Fixtures.triage_content(), Fixtures.high_confidence_tokens()))
      )
    end)

    assert {:ok, params, entries} = Client.complete(config(bypass), messages())
    assert params["intent"] == "simple_query"
    assert length(entries) == 7
  end

  test "wraps Req body-decode failures as :request_error", %{bypass: bypass} do
    Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
      {:ok, _raw, conn} = Plug.Conn.read_body(conn)

      Plug.Conn.put_resp_content_type(conn, "application/json")
      |> Plug.Conn.resp(200, "not json at all")
    end)

    assert {:error, {:request_error, %Jason.DecodeError{}}} =
             Client.complete(config(bypass), messages())
  end

  test "returns :no_choices when the body has no choices", %{bypass: bypass} do
    Fixtures.stub(bypass, %{"choices" => []})
    assert {:error, :no_choices} = Client.complete(config(bypass), messages())
  end

  test "returns :empty_content when the assistant content is missing", %{bypass: bypass} do
    body = %{
      "choices" => [
        %{"index" => 0, "message" => %{"role" => "assistant"}, "logprobs" => %{"content" => []}}
      ]
    }

    Fixtures.stub(bypass, body)
    assert {:error, :empty_content} = Client.complete(config(bypass), messages())
  end

  test "returns :invalid_json when the content is not JSON", %{bypass: bypass} do
    Fixtures.stub(bypass, Fixtures.chat_body("this is not json", []))
    assert {:error, :invalid_json} = Client.complete(config(bypass), messages())
  end

  test "returns :unexpected_json when the content is a JSON array", %{bypass: bypass} do
    Fixtures.stub(bypass, Fixtures.chat_body("[1, 2, 3]", []))
    assert {:error, {:unexpected_json, [1, 2, 3]}} = Client.complete(config(bypass), messages())
  end

  test "strips markdown code fences from the content", %{bypass: bypass} do
    fenced = "```json\n" <> Fixtures.triage_content() <> "\n```"
    Fixtures.stub(bypass, Fixtures.chat_body(fenced, Fixtures.high_confidence_tokens()))

    assert {:ok, params, _} = Client.complete(config(bypass), messages())
    assert params["intent"] == "simple_query"
  end

  test "returns :transport_error when the endpoint is unreachable" do
    conf = %{endpoint: "http://127.0.0.1:9/v1", model: "qwen2.5:1.5b"}

    assert {:error, {:transport_error, _reason}} =
             Client.complete(conf, messages(), timeout: 1_000)
  end

  describe "decode_content/1" do
    test "decodes a plain JSON object" do
      assert {:ok, %{"a" => 1}} = Client.decode_content(~s({"a": 1}))
    end

    test "decodes fenced JSON" do
      assert {:ok, %{"a" => 1}} = Client.decode_content("```json\n{\"a\": 1}\n```")
    end

    test "rejects nil" do
      assert {:error, :empty_content} = Client.decode_content(nil)
    end

    test "rejects non-binary input" do
      assert {:error, :empty_content} = Client.decode_content(123)
    end

    test "rejects non-object JSON" do
      assert {:error, {:unexpected_json, [1]}} = Client.decode_content("[1]")
    end

    test "rejects invalid JSON" do
      assert {:error, :invalid_json} = Client.decode_content("{nope")
    end
  end
end
