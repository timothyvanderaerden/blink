defmodule Blink.Test.SlowClient do
  @moduledoc false

  def complete(_config, _messages, _opts \\ []) do
    Process.sleep(500)
    {:ok, %{}, []}
  end
end

defmodule BlinkTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Blink.Test.Fixtures
  alias Blink.Test.Schemas.{Safety, Schema, Triage}

  setup do
    bypass = Bypass.open()
    on_exit(fn -> Bypass.down(bypass) end)
    [bypass: bypass]
  end

  defp config(bypass) do
    [
      endpoint: "http://127.0.0.1:#{bypass.port}/v1",
      model: "qwen2.5:1.5b",
      min_confidence: 0.70
    ]
  end

  # Bypass 2.x only offers one-shot expectations, so register the same
  # body-inspecting handler once per expected request.
  defp smart_route(bypass, handler, times) do
    for _ <- 1..times do
      Bypass.expect(bypass, "POST", "/v1/chat/completions", handler)
    end
  end

  defp respond(conn, body) do
    Plug.Conn.put_resp_content_type(conn, "application/json")
    |> Plug.Conn.resp(200, Jason.encode!(body))
  end

  defp system_of(conn) do
    {:ok, raw, _conn} = Plug.Conn.read_body(conn)
    req = Jason.decode!(raw)

    req["messages"]
    |> Enum.find(fn m -> m["role"] == "system" end)
    |> Map.get("content")
  end

  describe "evaluate/3" do
    test "returns a handled_locally result for a confident, valid answer", %{bypass: bypass} do
      Fixtures.stub(
        bypass,
        Fixtures.chat_body(Fixtures.triage_content(), Fixtures.high_confidence_tokens())
      )

      assert {:ok, result} =
               Blink.evaluate("What is the weather?", Triage, config(bypass))

      assert result.status == :handled_locally
      assert result.data.intent == "simple_query"
      assert result.confidence > 0.9
      assert result.latency_ms >= 0
    end

    test "passes :extra_headers through to the client", %{bypass: bypass} do
      test_pid = self()

      Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
        send(test_pid, {:headers, Plug.Conn.get_req_header(conn, "authorization")})

        respond(conn,
          Fixtures.chat_body(Fixtures.triage_content(), Fixtures.high_confidence_tokens())
        )
      end)

      assert {:ok, result} =
               Blink.evaluate("hi", Triage,
                 config(bypass) ++
                   [extra_headers: [{"Authorization", "Bearer sk-demo"}]]
               )

      assert result.status == :handled_locally
      assert_receive {:headers, ["Bearer sk-demo"]}
    end

    test "evaluate/2 uses the configured default endpoint" do
      bypass = Bypass.open()
      on_exit(fn ->
        Bypass.down(bypass)
        Application.delete_env(:blink, :default_endpoint)
      end)

      Application.put_env(:blink, :default_endpoint, "http://127.0.0.1:#{bypass.port}/v1")

      Fixtures.stub(
        bypass,
        Fixtures.chat_body(Fixtures.triage_content(), Fixtures.high_confidence_tokens())
      )

      assert {:ok, result} = Blink.evaluate("hi", Triage)
      assert result.status == :handled_locally
    end
  end

  describe "route/3" do
    test "routes across schemas and picks the handled winner", %{bypass: bypass} do
      smart_route(
        bypass,
        fn conn ->
          system = system_of(conn)

          body =
            if system =~ "safe" do
              Fixtures.chat_body(Fixtures.safety_content(), Fixtures.high_confidence_tokens())
            else
              Fixtures.chat_body(Fixtures.triage_content(), Fixtures.high_confidence_tokens())
            end

          respond(conn, body)
        end,
        2
      )

      assert {:ok, result} =
               Blink.route("Is this safe?", [Triage, Safety], config(bypass))

      assert result.winner in [:triage, :safety]
      assert length(result.checks) == 2
      assert [{:triage, %Blink.Result{} = _t}, {:safety, %Blink.Result{} = _s}] = result.checks
      assert result.status == :handled_locally
    end

    test "prefers a handled check over a low-confidence one, honouring :prefer", %{bypass: bypass} do
      smart_route(
        bypass,
        fn conn ->
          system = system_of(conn)

          body =
            if system =~ "safe" do
              # safety check: confident and valid
              Fixtures.chat_body(Fixtures.safety_content(false), Fixtures.high_confidence_tokens())
            else
              # triage check: low confidence
              Fixtures.chat_body(Fixtures.triage_content(), Fixtures.low_confidence_tokens())
            end

          respond(conn, body)
        end,
        2
      )

      assert {:ok, result} =
               Blink.route("Is this safe?", [Triage, Safety], config(bypass) ++ [prefer: [:safety]])

      assert result.winner == :safety
      assert result.status == :handled_locally
    end

    test "falls back to the best escalation candidate when nothing is handled", %{bypass: bypass} do
      smart_route(
        bypass,
        fn conn ->
          system = system_of(conn)

          body =
            if system =~ "safe" do
              # confident but invalid payload (missing required :safe) -> schema_invalid escalation
              Fixtures.chat_body(~s({"wrong_key": true}), Fixtures.high_confidence_tokens())
            else
              # low confidence -> low_confidence escalation
              Fixtures.chat_body(Fixtures.triage_content(), Fixtures.low_confidence_tokens())
            end

          respond(conn, body)
        end,
        2
      )

      assert {:ok, result} = Blink.route("Is this safe?", [Triage, Safety], config(bypass))

      assert result.status == :escalate_to_system_2
      assert result.winner == :safety
    end

    test "returns :all_checks_failed when every check errors", %{bypass: bypass} do
      for _ <- 1..2, do: Fixtures.stub(bypass, %{"error" => "boom"}, 500)

      assert {:error, {:all_checks_failed, checks}} =
               Blink.route("hi", [Triage, Safety], config(bypass))

      assert [{:triage, {:error, {:client_error, _}}}, {:safety, {:error, {:client_error, _}}}] =
               checks
    end

    test "supports explicit {name, module} tuples and string names", %{bypass: bypass} do
      for _ <- 1..3,
          do:
            Fixtures.stub(
              bypass,
              Fixtures.chat_body(Fixtures.triage_content(), Fixtures.high_confidence_tokens())
            )

      assert {:ok, result} =
               Blink.route("hi", [{"custom", Triage}, {"plain", Triage}, Safety], config(bypass))

      assert result.winner in [:custom, :plain, :safety]

      assert [
               {:custom, %Blink.Result{} = _c},
               {:plain, %Blink.Result{} = _p},
               {:safety, %Blink.Result{} = _s}
             ] = result.checks
    end

    test "supports atom names in {name, module} tuples", %{bypass: bypass} do
      for _ <- 1..2,
          do:
            Fixtures.stub(
              bypass,
              Fixtures.chat_body(Fixtures.triage_content(), Fixtures.high_confidence_tokens())
            )

      assert {:ok, result} = Blink.route("hi", [{:named, Triage}, Triage], config(bypass))

      assert result.winner == :named
      assert [{:named, %Blink.Result{} = _n}, {:triage, %Blink.Result{} = _t}] = result.checks
    end

    test "falls back to :check_<idx> for modules named exactly Schema", %{bypass: bypass} do
      for _ <- 1..2,
          do:
            Fixtures.stub(
              bypass,
              Fixtures.chat_body(~s({"ok": true}), Fixtures.high_confidence_tokens())
            )

      assert {:ok, result} = Blink.route("hi", [Schema, Triage], config(bypass))

      assert [{:check_0, %Blink.Result{} = _s}, {:triage, %Blink.Result{} = _t}] = result.checks
      assert result.winner == :check_0
    end

    test "route/2 uses the configured default endpoint" do
      bypass = Bypass.open()
      on_exit(fn ->
        Bypass.down(bypass)
        Application.delete_env(:blink, :default_endpoint)
      end)

      Application.put_env(:blink, :default_endpoint, "http://127.0.0.1:#{bypass.port}/v1")

      Fixtures.stub(
        bypass,
        Fixtures.chat_body(Fixtures.triage_content(), Fixtures.high_confidence_tokens())
      )

      assert {:ok, result} = Blink.route("hi", [Triage])
      assert result.winner == :triage
    end

    test "reports all checks failed when a check task times out" do
      assert {:error, {:all_checks_failed, checks}} =
               Blink.route("hi", [Triage], client: Blink.Test.SlowClient, timeout: 50)

      assert [{nil, {:error, {:timeout, :task_killed}}}] = checks
    end

    test "raises ArgumentError for an empty schema list" do
      assert_raise ArgumentError, ~r/non-empty list/, fn ->
        Blink.route("hi", [], config(%{port: 1}))
      end
    end
  end
end
