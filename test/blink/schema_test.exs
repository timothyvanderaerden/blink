defmodule Blink.SchemaTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Blink.Schema
  alias Blink.Test.Schemas.{Loose, PlainEcto, Safety, Triage}

  describe "decision_schema generated modules" do
    test "exposes the declared fields" do
      assert Schema.fields(Triage) ==
               [:intent, :requires_system_2, :extracted_entities, :reasoning_summary]

      assert Schema.fields(Safety) == [:safe, :flags]
    end

    test "casts a valid payload into a struct" do
      params = %{
        "intent" => "simple_query",
        "requires_system_2" => false,
        "extracted_entities" => ["Paris"],
        "reasoning_summary" => "clear question"
      }

      assert {:ok, %Triage{} = data} = Schema.cast(Triage, params)
      assert data.intent == "simple_query"
      assert data.requires_system_2 == false
      assert data.extracted_entities == ["Paris"]
      assert data.reasoning_summary == "clear question"
    end

    test "applies field defaults" do
      assert {:ok, %Triage{} = data} =
               Schema.cast(Triage, %{"intent" => "unclear", "requires_system_2" => true})

      assert data.extracted_entities == []
      assert data.reasoning_summary == nil
    end

    test "rejects missing required fields" do
      {:error, changeset} = Schema.cast(Triage, %{"intent" => "simple_query"})

      assert {"can't be blank", [validation: :required]} = changeset.errors[:requires_system_2]
    end

    test "rejects values outside the inclusion list" do
      params = %{
        "intent" => "bogus_intent",
        "requires_system_2" => false
      }

      {:error, changeset} = Schema.cast(Triage, params)

      assert {"is invalid", [validation: :inclusion, enum: _]} = changeset.errors[:intent]
    end

    test "ignores unknown keys" do
      params = %{
        "intent" => "code_refactor",
        "requires_system_2" => true,
        "surprise" => "ignored"
      }

      assert {:ok, %Triage{}} = Schema.cast(Triage, params)
    end

    test "supports schemas without required or inclusion rules" do
      assert {:ok, %Loose{score: 7, note: "ok"}} = Schema.cast(Loose, %{"score" => 7, "note" => "ok"})
      assert {:ok, %Loose{}} = Schema.cast(Loose, %{})
    end
  end

  describe "cast!/2" do
    test "returns the struct on success" do
      assert %Safety{safe: true} =
               Schema.cast!(Safety, %{"safe" => true, "flags" => ["prompt_injection"]})
    end

    test "raises ArgumentError on an invalid payload" do
      assert_raise ArgumentError, ~r/invalid .*changeset/, fn ->
        Schema.cast!(Safety, %{"flags" => []})
      end
    end
  end

  describe "hand-written Ecto schemas" do
    test "cast/2 works with a plain use Ecto.Schema module" do
      params = %{
        "intent" => "complex_reasoning",
        "requires_system_2" => true,
        "extracted_entities" => [],
        "reasoning_summary" => "needs planning"
      }

      assert {:ok, %PlainEcto{} = data} = Schema.cast(PlainEcto, params)
      assert data.intent == "complex_reasoning"
    end

    test "cast/2 reports changeset errors for plain modules" do
      {:error, changeset} = Schema.cast(PlainEcto, %{"intent" => "nope"})
      assert changeset.errors[:intent]
      assert changeset.errors[:requires_system_2]
    end
  end

  describe "build_changeset/3" do
    test "builds a changeset from an explicit spec" do
      spec = [
        fields: [:intent, :requires_system_2],
        required: [:intent, :requires_system_2],
        inclusions: [{:intent, ["simple_query", "unclear"]}]
      ]

      schema = struct(Triage)

      valid = Schema.build_changeset(schema, %{"intent" => "unclear", "requires_system_2" => true}, spec)
      assert valid.valid?

      invalid = Schema.build_changeset(schema, %{"intent" => "nope"}, spec)
      refute invalid.valid?
      assert {"is invalid", [validation: :inclusion, enum: _]} = invalid.errors[:intent]
      assert {"can't be blank", [validation: :required]} = invalid.errors[:requires_system_2]
    end

    test "works with an empty spec" do
      spec = [fields: [:intent]]
      changeset = Schema.build_changeset(struct(Triage), %{"intent" => "unclear"}, spec)
      assert changeset.valid?
    end
  end

  describe "runtime macro expansion" do
    test "decision_schema expands at runtime into a working schema" do
      # A defmodule nested in a function body resolves names relative to
      # this test module, so the schema is compiled at runtime through
      # Code.eval_string instead. That also runs the decision_schema/1 and
      # parse_fields/1 codegen under coverage (test files compile before
      # coverage starts).
      Code.eval_string("""
      defmodule Blink.Test.RuntimeSchema do
        use Blink.Schema

        decision_schema do
          field :intent, :string, required: true, in: ["a", "b"]
          field :score, :integer, required: true
          field :note, :string
        end
      end

      defmodule Blink.Test.RuntimeSingle do
        use Blink.Schema

        # a single-field block arrives as a bare expression, not a __block__
        decision_schema do
          field :ok, :boolean, required: true
        end
      end
      """)

      # Module.concat keeps the module lookup at runtime, so the compiler
      # does not warn about a module that only exists after this test runs.
      schema = Module.concat([Blink, :Test, :RuntimeSchema])

      assert Schema.fields(schema) == [:intent, :score, :note]
      assert schema.blink_spec() == [
               fields: [:intent, :score, :note],
               required: [:intent, :score],
               inclusions: [{:intent, ["a", "b"]}]
             ]

      assert {:ok, data} = Schema.cast(schema, %{"intent" => "a", "score" => 3})
      assert data.intent == "a"
      assert data.score == 3
      assert data.note == nil

      {:error, changeset} = Schema.cast(schema, %{"intent" => "zzz", "score" => 3})
      assert {"is invalid", [validation: :inclusion, enum: _]} = changeset.errors[:intent]

      single = Module.concat([Blink, :Test, :RuntimeSingle])
      assert Schema.fields(single) == [:ok]
      assert {:ok, data} = Schema.cast(single, %{"ok" => true})
      assert data.ok == true
    end
  end
end
