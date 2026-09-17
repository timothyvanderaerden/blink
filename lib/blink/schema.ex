defmodule Blink.Schema do
  @moduledoc """
  Helpers for defining and validating Ecto-based decision schemas.

  ## Defining a decision schema

      defmodule MyApp.Routers.TriageSchema do
        use Blink.Schema

        decision_schema do
          field :intent, :string,
                required: true,
                in: ["simple_query", "code_refactor", "complex_reasoning", "unclear"]

          field :requires_system_2, :boolean, required: true
          field :extracted_entities, {:array, :string}, default: []
          field :reasoning_summary, :string
        end
      end

  The macro generates an `embedded_schema/0` plus a `changeset/2` that casts
  the model's JSON payload, enforces required fields and inclusion rules,
  and delegates the actual validation to the runtime function
  `build_changeset/3`.

  Plain `use Ecto.Schema` modules with their own `changeset/2` are also
  supported - `cast/2` works with any module exposing `changeset/2`.
  """

  import Ecto.Changeset

  defmacro __using__(_opts) do
    quote do
      use Ecto.Schema
      import Ecto.Changeset
      import Blink.Schema, only: [decision_schema: 1]
      @primary_key false
    end
  end

  @doc """
  Defines an embedded decision schema plus a validated `changeset/2`.

  Supports the usual `field/3` declarations with the extra options:

    * `required: true` - the field must be present in the payload
    * `in: [values]` - the field value must be one of the given values
  """
  defmacro decision_schema(do: block) do
    spec = parse_fields(block)

    field_defs =
      for {name, type, opts} <- spec.raw do
        ecto_opts = opts |> Keyword.delete(:required) |> Keyword.delete(:in)

        quote do
          field(unquote(name), unquote(type), unquote(ecto_opts))
        end
      end

    quote do
      embedded_schema do
        unquote_splicing(field_defs)
      end

      @doc "The validation spec used by the generated `changeset/2`."
      def blink_spec, do: unquote(spec.validation)

      @doc "Validates a decoded JSON payload against this decision schema."
      def changeset(schema, params) do
        Blink.Schema.build_changeset(schema, params, blink_spec())
      end
    end
  end

  @doc """
  Builds a changeset for `schema` from decoded `params` using a validation
  spec: `[fields: [...], required: [...], inclusions: [{field, values}]]`.

  This is the runtime heart of schema validation; it is shared by generated
  decision schemas and can be called directly for hand-written ones.
  """
  def build_changeset(schema, params, spec) do
    fields = Keyword.fetch!(spec, :fields)
    required = Keyword.get(spec, :required, [])
    inclusions = Keyword.get(spec, :inclusions, [])

    base =
      schema
      |> cast(params, fields)
      |> validate_required(required)

    Enum.reduce(inclusions, base, fn {field, values}, changeset ->
      validate_inclusion(changeset, field, values)
    end)
  end

  @doc """
  Casts a decoded JSON payload into the given schema module.

  Returns `{:ok, struct}` when valid, or `{:error, changeset}` otherwise.
  Works with any module exposing `changeset/2`, including plain
  `use Ecto.Schema` modules.
  """
  def cast(schema_module, params) do
    changeset = schema_module.changeset(struct(schema_module), params)

    if changeset.valid? do
      {:ok, Ecto.Changeset.apply_changes(changeset)}
    else
      {:error, changeset}
    end
  end

  @doc "Like `cast/2` but raises `ArgumentError` on an invalid payload."
  def cast!(schema_module, params) do
    case cast(schema_module, params) do
      {:ok, data} ->
        data

      {:error, changeset} ->
        raise ArgumentError,
              "invalid #{inspect(schema_module)} changeset: #{inspect(changeset.errors)}"
    end
  end

  @doc "Returns the field names of an Ecto schema module."
  def fields(schema_module) do
    schema_module.__schema__(:fields)
  end

  defp parse_fields({:__block__, _, exprs}), do: parse_fields(exprs)

  defp parse_fields(expr) when not is_list(expr), do: parse_fields([expr])

  defp parse_fields(exprs) do
    raw =
      for {:field, _, args} <- exprs do
        [name, type | rest] = args
        opts = if rest == [], do: [], else: Keyword.new(List.first(rest))
        {name, type, opts}
      end

    names = for {name, _, _} <- raw, do: name
    required = for {name, _, opts} <- raw, Keyword.get(opts, :required, false), do: name
    inclusions = for {name, _, opts} <- raw, values = Keyword.get(opts, :in), do: {name, values}

    %{
      raw: raw,
      validation: [
        fields: names,
        required: required,
        inclusions: inclusions
      ]
    }
  end
end
