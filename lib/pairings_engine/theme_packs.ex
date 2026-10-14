defmodule PairingsEngine.ThemePacks do
  @moduledoc """
  Colour themes that are not part of the program: folders an operator (or a
  desktop user) drops in, which turn up in the theme picker after the
  built-in ones. The format is in `docs/theme-packs.md`; in short, a pack is

      <id>/theme.json   {"id", "name", "name_nl"?, "author", "version", "dark", "swatch"}
      <id>/theme.css    rules scoped to [data-theme="<id>"]
      <id>/fonts/*.woff2 (optional)

  ## Where packs come from

    * `PAIRINGS_THEMES_DIR` (config `:themes_dir`), when set - the hosted
      server's folder, filled by the deploy;
    * otherwise, on a desktop install, `<data dir>/themes`, next to the
      database (config `:local_data_dir`);
    * otherwise nowhere: no folder, no packs, and the app is exactly the app.

  Nothing is installed by default.

  ## Refusals

  A pack that does not load is refused, not half-loaded: a bad `theme.json`,
  a stylesheet over 200 KB, or CSS that `PairingsEngine.ThemePacks.Scanner`
  will not pass. The reason is logged once and shown in the picker, where
  the person who installed it will look first.

  Results are cached per pack against the files' size and modification
  time, so a page render costs a directory listing and a few `stat`s, and
  replacing a pack takes effect on the next page without a restart.
  """

  require Logger

  alias PairingsEngine.ThemePacks.Scanner

  @css_limit 200 * 1024
  @font_limit 1024 * 1024
  @id_format ~r/\A[a-z0-9][a-z0-9-]{0,39}\z/
  @font_file ~r/\A[a-z0-9_-]+\.woff2\z/
  @hex ~r/\A#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})\z/

  @typedoc "An installed, accepted pack."
  @type pack :: %{
          id: String.t(),
          name: String.t(),
          name_nl: String.t() | nil,
          author: String.t(),
          version: String.t(),
          dark: boolean(),
          swatch: [String.t()],
          path: String.t(),
          etag: String.t()
        }

  @doc "The largest `theme.css` served, in bytes."
  def css_limit, do: @css_limit

  @doc "The largest font file served, in bytes."
  def font_limit, do: @font_limit

  @doc "Whether `file` is a font name the pack controller may serve."
  def font_file?(file), do: is_binary(file) and file =~ @font_file

  @doc """
  The folder packs are read from, or `nil` for none. See the moduledoc for
  the order.
  """
  @spec dir() :: String.t() | nil
  def dir do
    resolve_dir(
      Application.get_env(:pairings_engine, :themes_dir),
      Application.get_env(:pairings_engine, :local_mode, false),
      Application.get_env(:pairings_engine, :local_data_dir)
    )
  end

  @doc false
  # The decision itself, apart from where its inputs live, so it can be
  # tested without touching the application environment.
  def resolve_dir(themes_dir, local_mode?, local_data_dir) do
    cond do
      is_binary(themes_dir) and themes_dir != "" -> themes_dir
      local_mode? == true and is_binary(local_data_dir) -> Path.join(local_data_dir, "themes")
      true -> nil
    end
  end

  @doc "The accepted packs, sorted by name."
  @spec list() :: [pack()]
  def list, do: for({:ok, pack} <- scan(), do: pack)

  @doc "The refused packs, as `{folder name, reason}`."
  @spec refused() :: [{String.t(), String.t()}]
  def refused, do: for({:refused, id, reason} <- scan(), do: {id, reason})

  @doc "The ids of the accepted packs."
  def ids, do: Enum.map(list(), & &1.id)

  @doc "The accepted pack `id`, or `nil`."
  @spec get(String.t()) :: pack() | nil
  def get(id) when is_binary(id) do
    if id =~ @id_format, do: Enum.find(list(), &(&1.id == id)), else: nil
  end

  def get(_), do: nil

  @doc """
  The packs as the root layout hands them to its bootstrap script: data,
  never code.
  """
  def bootstrap_json do
    list()
    |> Enum.map(&%{id: &1.id, dark: &1.dark, css: css_url(&1)})
    |> Jason.encode!()
  end

  @doc "Where a pack's stylesheet is served, versioned by its etag."
  def css_url(%{id: id, etag: etag}), do: "/themes/#{id}/theme.css?v=#{etag}"

  @doc "The name to show for `pack` in `locale`."
  def label(%{name_nl: nl}, "nl") when is_binary(nl), do: nl
  def label(%{name: name}, _locale), do: name

  defp scan do
    case dir() do
      nil ->
        []

      dir ->
        case File.ls(dir) do
          {:ok, entries} ->
            entries
            |> Enum.sort()
            |> Enum.map(&Path.join(dir, &1))
            |> Enum.filter(&File.dir?/1)
            |> Enum.map(&load_cached/1)
            |> Enum.sort_by(fn
              {:ok, pack} -> {0, String.downcase(pack.name)}
              {:refused, id, _} -> {1, id}
            end)

          {:error, _} ->
            []
        end
    end
  end

  defp load_cached(path) do
    key = {__MODULE__, path}
    stamp = stamp(path)

    case :persistent_term.get(key, nil) do
      {^stamp, result} ->
        result

      _ ->
        result = load_folder(path)

        case result do
          {:refused, id, reason} -> Logger.warning("theme pack #{id} refused: #{reason}")
          _ -> :ok
        end

        :persistent_term.put(key, {stamp, result})
        result
    end
  end

  defp stamp(path) do
    for file <- ["theme.json", "theme.css"] do
      case File.stat(Path.join(path, file), time: :posix) do
        {:ok, %{size: size, mtime: mtime}} -> {size, mtime}
        _ -> nil
      end
    end
  end

  defp load_folder(path) do
    folder = Path.basename(path)

    case load(path) do
      {:ok, pack} ->
        if pack.id == folder,
          do: {:ok, pack},
          else:
            {:refused, folder, "theme.json says id #{inspect(pack.id)}, the folder is #{folder}"}

      {:error, reason} ->
        {:refused, folder, reason}
    end
  end

  @doc """
  Reads and checks the pack in `path`: its `theme.json`, and its
  `theme.css` against the size cap and the scanner. Does not care what the
  folder is called - `mix pairings.theme_check` runs it on a pack before it
  is installed anywhere.
  """
  @spec load(String.t()) :: {:ok, pack()} | {:error, String.t()}
  def load(path) do
    with {:ok, meta} <- read_meta(path),
         {:ok, css} <- read_css(path),
         :ok <- Scanner.scan(css, meta.id) do
      etag =
        :crypto.hash(:sha256, [Jason.encode!(meta), css])
        |> binary_part(0, 8)
        |> Base.encode16(case: :lower)

      {:ok, Map.merge(meta, %{path: path, etag: etag})}
    end
  end

  defp read_meta(path) do
    with {:ok, text} <- read(Path.join(path, "theme.json"), 16 * 1024, "theme.json"),
         {:ok, json} <- decode(text) do
      meta(json)
    end
  end

  defp read_css(path), do: read(Path.join(path, "theme.css"), @css_limit, "theme.css")

  defp read(file, limit, what) do
    case File.stat(file) do
      {:ok, %{type: :regular, size: size}} when size > limit ->
        {:error, "#{what} is over #{div(limit, 1024)} KB"}

      {:ok, %{type: :regular}} ->
        case File.read(file) do
          {:ok, text} -> {:ok, text}
          {:error, reason} -> {:error, "#{what} unreadable: #{reason}"}
        end

      _ ->
        {:error, "no #{what}"}
    end
  end

  defp decode(text) do
    case Jason.decode(text) do
      {:ok, %{} = json} -> {:ok, json}
      _ -> {:error, "theme.json is not a JSON object"}
    end
  end

  defp meta(json) do
    id = json["id"]
    swatch = json["swatch"]

    cond do
      not (is_binary(id) and id =~ @id_format) ->
        {:error, "id must be lowercase letters, digits and dashes"}

      id in PairingsEngine.Accounts.Preferences.builtin_themes() or id == "embed" ->
        {:error, "id #{id} is a built-in theme"}

      not text?(json["name"]) ->
        {:error, "name is missing or longer than 40 characters"}

      json["name_nl"] != nil and not text?(json["name_nl"]) ->
        {:error, "name_nl is longer than 40 characters"}

      not is_boolean(json["dark"]) ->
        {:error, "dark must be true or false"}

      not (is_list(swatch) and length(swatch) in 3..4 and
               Enum.all?(swatch, &(is_binary(&1) and &1 =~ @hex))) ->
        {:error, "swatch must be 3 or 4 hex colours"}

      true ->
        {:ok,
         %{
           id: id,
           name: json["name"],
           name_nl: json["name_nl"],
           author: string(json["author"]),
           version: string(json["version"]),
           dark: json["dark"],
           swatch: Enum.map(swatch, &String.downcase/1)
         }}
    end
  end

  defp text?(value),
    do: is_binary(value) and String.trim(value) != "" and String.length(value) <= 40

  defp string(value) when is_binary(value), do: String.slice(value, 0, 80)
  defp string(_), do: ""
end
