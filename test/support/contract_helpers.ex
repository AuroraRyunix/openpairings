defmodule PairingsEngineWeb.ContractHelpers do
  @moduledoc """
  The cross-repo contracts under `priv/contracts/<name>/`, for tests: load a
  schema, check a value against it, check every example and the index.

  The contracts are JSON Schema draft-07 (`ex_json_schema`). A `$ref` to
  another file of a contract resolves against the schema's `$id`, a
  raw.githubusercontent.com address; `resolve_remote/1` maps that address
  back onto this checkout's `priv/contracts` and refuses anything else, so a
  test never fetches a schema over the network - it checks the files the
  commit carries, which is the point.

  `CONTRACTS_WRITE_EXAMPLES=1 mix test ...` makes `record_example/3` write the
  real responses it is given as examples. For refreshing them after a
  deliberate change; read the diff before committing it.
  """
  import ExUnit.Assertions

  @root Path.expand("../../priv/contracts", __DIR__)
  @remote "https://raw.githubusercontent.com/teapot-chess/"

  @doc """
  The directory of contract `name`: one this repository provides
  (`"manubrium-v1"`), or a vendored one (`"vendor/openresults/publish-v1"`).
  """
  def dir(name), do: Path.join(@root, name)

  @doc """
  The `ex_json_schema` resolver: a contract's own address, read from disk -
  OpenPairings' own contracts from `priv/contracts`, another repository's from
  its vendored copy under `priv/contracts/vendor/<repo>`. Anything else
  raises - a schema that wants the network is a broken schema.
  """
  def resolve_remote(@remote <> rest = url) do
    path =
      case String.split(rest, "/main/priv/contracts/", parts: 2) do
        ["openpairings", file] -> Path.join(@root, file)
        [repo, file] -> Path.join([@root, "vendor", String.downcase(repo), file])
        _ -> raise("contract schemas resolve locally only; refusing to fetch #{url}")
      end

    if File.regular?(path),
      do: read_json!(path),
      else: raise("contract schema #{url} is referenced but not in priv/contracts")
  end

  def resolve_remote(url),
    do: raise("contract schemas resolve locally only; refusing to fetch #{url}")

  @doc "A resolved schema, cached for the test run."
  def schema(name, file) do
    key = {__MODULE__, name, file}

    case :persistent_term.get(key, nil) do
      nil ->
        Application.put_env(
          :ex_json_schema,
          :remote_schema_resolver,
          {__MODULE__, :resolve_remote}
        )

        resolved =
          name |> dir() |> Path.join(file) |> read_json!() |> ExJsonSchema.Schema.resolve()

        :persistent_term.put(key, resolved)
        resolved

      resolved ->
        resolved
    end
  end

  @doc """
  Fails unless `data` (any JSON-able term; it is put through Jason first, so
  atoms and structs are judged as they would travel) is valid against
  `file` of contract `name`. Returns `data` as JSON.
  """
  def assert_valid!(name, file, data) do
    json = data |> Jason.encode!() |> Jason.decode!()

    case ExJsonSchema.Validator.validate(schema(name, file), json) do
      :ok ->
        json

      {:error, errors} ->
        flunk("""
        #{name}/#{file} refuses this:

        #{Enum.map_join(errors, "\n", fn {message, path} -> "  #{path}: #{message}" end)}

        #{Jason.encode!(json, pretty: true)}
        """)
    end
  end

  @doc "Like `assert_valid!/3`, but says whether, and why not."
  def valid?(name, file, data) do
    ExJsonSchema.Validator.valid?(schema(name, file), data |> Jason.encode!() |> Jason.decode!())
  end

  @doc """
  Every example of contract `name`, as `{example file, schema file, data}`.
  `examples/<message>.json` and `examples/<message>.<variant>.json` belong
  to `<message>.schema.json` - the longest such message that has a schema,
  since a provider may put dots in its message names (`snapshot.request`).
  """
  def examples(name) do
    name
    |> dir()
    |> Path.join("examples/*.json")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(fn path ->
      {"examples/" <> Path.basename(path), schema_of(name, Path.basename(path, ".json")),
       read_json!(path)}
    end)
  end

  @doc "The schema file an example (by its name without `.json`) belongs to."
  def schema_of(name, example) do
    parts = String.split(example, ".")

    candidates =
      for n <- length(parts)..1//-1, do: Enum.join(Enum.take(parts, n), ".") <> ".schema.json"

    Enum.find(candidates, List.last(candidates), &File.regular?(Path.join(dir(name), &1)))
  end

  @doc "One example's data, by its file name under `examples/`."
  def example(name, file), do: name |> dir() |> Path.join("examples/" <> file) |> read_json!()

  @doc "Every file of contract `name` but `index.json`, relative, sorted."
  def files(name) do
    base = dir(name)

    base
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.relative_to(&1, base))
    |> Enum.reject(&(&1 == "index.json"))
    |> Enum.sort()
  end

  @doc "Fails unless `index.json` names the contract and lists exactly its files."
  def assert_index!(name) do
    index = name |> dir() |> Path.join("index.json") |> read_json!()
    [contract, "v" <> version] = name |> Path.basename() |> String.split(~r/-(?=v\d+$)/)

    assert index["contract"] == contract
    assert index["version"] == String.to_integer(version)
    assert index["files"] == files(name), "index.json does not list #{name}'s files exactly"
    index
  end

  @doc """
  Checks `data` against the schema of `example`'s message and, with
  `CONTRACTS_WRITE_EXAMPLES=1`, writes it as that example.
  """
  def record_example(name, example, data) do
    json = assert_valid!(name, schema_of(name, example), data)

    if System.get_env("CONTRACTS_WRITE_EXAMPLES") == "1" do
      path = name |> dir() |> Path.join("examples/#{example}.json")
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, Jason.encode!(json, pretty: true) <> "\n")
    end

    json
  end

  defp read_json!(path), do: path |> File.read!() |> Jason.decode!()
end
