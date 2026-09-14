defmodule PairingsEngine.Federations.BEL.Http do
  @moduledoc """
  Downloads the Belgian national (KBSB/FRBE) rating list from KBSB's public
  monthly zip, and (optionally) a separate club-names file - the two
  sources `PairingsEngine.Federations.BEL.Sync` imports from, replacing the
  data-platform API and the OpenResults relay (both removed 2026-09-13; see
  docs/kbsb-sync.md).

  ## URL resolution

  `PairingsEngine.Federations.BEL.Settings.players_url/0` is a template
  (default `.../players_{YYYYMM}.zip`) or a fixed URL with no placeholder.
  A template is expanded against the current month first; KBSB answers a
  month not yet published with an HTTP **301** (not 404), so both 301 and
  404 - and, defensively, 403 - step back one month at a time, up to 3
  months, before giving up. A fixed URL (no `{YYYYMM}`) is fetched exactly
  as configured, with no month walking at all.

  ## Conditional GET

  The `ETag` (falling back to `Last-Modified`) from the last successful
  fetch of each RESOLVED url is remembered (`PairingsEngine.Meta`, one
  entry per URL) and sent back as `If-None-Match` / `If-Modified-Since`. A
  304 means nothing changed since last time - `fetch_players/1` and
  `fetch_clubs_file/0` both answer `:unchanged` rather than re-downloading
  and re-importing an identical file.

  ## Caps

  `@max_compressed_bytes` bounds the zip as streamed (~1.8 MB in
  practice); `@max_uncompressed_bytes` bounds what `players.sqlite` may
  declare it inflates to, checked via `:zip.list_dir/1` BEFORE anything is
  inflated - same defence `PairingsEngine.Fide.Sync` uses against a zip
  bomb. `@connect_timeout_ms`/`@receive_timeout_ms` bound the request
  itself.
  """

  alias PairingsEngine.Meta
  alias PairingsEngine.Federations.BEL.{Settings, SqliteFile}

  @max_compressed_bytes 20_000_000
  @connect_timeout_ms :timer.seconds(15)
  @receive_timeout_ms :timer.seconds(60)
  @max_months_back 3

  @doc """
  Fetches and unpacks the players list. Returns:

    * `{:ok, %{rows: [map], clubs: map() | nil, month_label: String.t(),
       resolved_url: String.t()}}` - `rows` are raw column-keyed maps
      (string keys, exactly the sqlite columns), `clubs` is
      `%{club_number => name}` if `players.sqlite` had a `clubs` table,
      else `nil`.
    * `:unchanged` - the resolved URL answered 304 (or its ETag/
      Last-Modified matched what was stored).
    * `{:error, reason}` - every month tried failed, the download exceeded
      a cap, the zip has no `players.sqlite`, or the table/columns inside
      it don't match what's expected.
  """
  def fetch_players(on_progress \\ fn _ -> :ok end) do
    template = Settings.players_url()

    if String.contains?(template, "{YYYYMM}") do
      today = Date.utc_today()
      try_months(template, today, 0, on_progress)
    else
      fetch_one(template, on_progress)
    end
  end

  defp try_months(_template, _today, offset, _on_progress) when offset > @max_months_back do
    {:error, "No published Belgian rating list found in the last #{@max_months_back + 1} months."}
  end

  defp try_months(template, today, offset, on_progress) do
    month = Date.add(today, -30 * offset) |> beginning_of_month()
    url = expand_url(template, month)

    case fetch_one(url, on_progress) do
      {:error, {:http_status, status}} when status in [301, 302, 303, 307, 308, 404, 403] ->
        try_months(template, today, offset + 1, on_progress)

      other ->
        with {:ok, result} <- other do
          {:ok, Map.put(result, :month_label, month_label(month))}
        end
    end
  end

  # Coarse but sufficient: only the year/month matters, and stepping back by
  # 30 days from any day-of-month always lands in the previous calendar
  # month or the one before it, never skips one, since every month is at
  # least 28 days.
  defp beginning_of_month(date), do: %{date | day: 1}

  defp expand_url(template, %Date{year: y, month: m}) do
    String.replace(template, "{YYYYMM}", "#{y}#{String.pad_leading("#{m}", 2, "0")}")
  end

  @month_names ~w(January February March April May June July August
                  September October November December)

  defp month_label(%Date{year: y, month: m}), do: "#{Enum.at(@month_names, m - 1)} #{y}"

  defp fetch_one(url, on_progress) do
    with {:ok, response} <- conditional_get(url, on_progress) do
      case response do
        :not_modified ->
          :unchanged

        {:ok, body} ->
          with :ok <- check_compressed_size(body) do
            SqliteFile.read(body)
          end
      end
    end
  end

  defp check_compressed_size(body) when byte_size(body) > @max_compressed_bytes,
    do: {:error, "Downloaded file exceeded #{div(@max_compressed_bytes, 1_000_000)} MB."}

  defp check_compressed_size(_body), do: :ok

  # Follows a redirect only when it points at another data file (a moved
  # .zip, .sqlite, .csv or .json) and only once; any other redirect - KBSB's
  # "month not published" 301 to its blog - is reported as that status, so
  # the month fallback can step back.
  defp follow_file_redirect(url, resp, status, on_progress) do
    location =
      case Req.Response.get_header(resp, "location") do
        [loc | _] -> loc
        _ -> nil
      end

    target = location && URI.merge(url, location) |> URI.to_string()

    if target != nil and target != url and data_file_url?(target) and
         not Process.get(:bel_http_followed_redirect, false) do
      Process.put(:bel_http_followed_redirect, true)

      try do
        conditional_get(target, on_progress)
      after
        Process.delete(:bel_http_followed_redirect)
      end
    else
      {:error, {:http_status, status}}
    end
  end

  defp data_file_url?(url) do
    path = URI.parse(url).path || ""
    String.downcase(Path.extname(path)) in [".zip", ".sqlite", ".csv", ".json"]
  end

  defp etag_key(url), do: "bel_http_etag:" <> url

  defp conditional_get(url, on_progress) do
    headers = conditional_headers(url)

    req_opts =
      [
        headers: headers,
        connect_options: [timeout: @connect_timeout_ms],
        receive_timeout: @receive_timeout_ms,
        retry: false,
        # Always raw bytes, regardless of what Content-Type the server
        # sends - both the players zip and the clubs file (which may well
        # be served as `application/json`) are parsed by hand below, and
        # Req's automatic JSON/CSV decoding would hand `body` back as an
        # already-decoded term instead of the binary every check here
        # (size cap included) assumes.
        decode_body: false,
        # Never follow a redirect blindly. KBSB answers a month it has not
        # published yet with a 301 to its blog, and following it turned "not
        # published yet" into a 200 HTML page that failed as :not_sqlite
        # instead of falling back to the previous month. A redirect to
        # another .zip/.sqlite file is followed once, by hand, below.
        redirect: false
      ]
      |> maybe_put_test_plug()

    on_progress.("Contacting #{host_of(url)}…")

    case Req.get(url, req_opts) do
      {:ok, %{status: 304}} ->
        {:ok, :not_modified}

      {:ok, %{status: status} = resp} when status in [301, 302, 303, 307, 308] ->
        follow_file_redirect(url, resp, status, on_progress)

      {:ok, %{status: 200, body: body} = resp} ->
        store_conditional(url, resp)
        {:ok, {:ok, body}}

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, "Download failed: #{inspect(reason)}"}
    end
  end

  # Same `Req.Test` stub convention as `PairingsEngine.Publishing` and
  # `PairingsEngine.Keycloak` - in prod nothing is configured and the
  # request goes out over the network; `config/test.exs` (or a test
  # itself) points this at a stub name instead.
  defp maybe_put_test_plug(req_opts) do
    case Application.get_env(:pairings_engine, :bel_http_req_plug) do
      nil -> req_opts
      name -> Keyword.put(req_opts, :plug, {Req.Test, name})
    end
  end

  defp conditional_headers(url) do
    case Meta.get(etag_key(url)) do
      nil ->
        []

      stored ->
        case String.split(stored, "\t", parts: 2) do
          ["etag", etag] -> [{"if-none-match", etag}]
          ["last-modified", lm] -> [{"if-modified-since", lm}]
          _ -> []
        end
    end
  end

  defp store_conditional(url, resp) do
    cond do
      etag = header(resp, "etag") -> Meta.put(etag_key(url), "etag\t" <> etag)
      lm = header(resp, "last-modified") -> Meta.put(etag_key(url), "last-modified\t" <> lm)
      true -> :ok
    end
  end

  defp header(resp, name) do
    case Req.Response.get_header(resp, name) do
      [v | _] -> v
      _ -> nil
    end
  end

  defp host_of(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> host
      _ -> url
    end
  end

  @doc """
  Fetches the optional "Belgian club names URL", if one is configured.
  Returns `{:ok, %{club_number => name}}`, `:unchanged` (304 / ETag
  match), `:not_configured` (no URL set), or `{:error, reason}`.
  """
  def fetch_clubs_file(on_progress \\ fn _ -> :ok end) do
    case Settings.clubs_url() do
      nil ->
        :not_configured

      "" ->
        :not_configured

      url ->
        case conditional_get(url, on_progress) do
          {:ok, :not_modified} ->
            :unchanged

          {:ok, {:ok, body}} ->
            if byte_size(body) > @max_compressed_bytes do
              {:error, "Club names file exceeded #{div(@max_compressed_bytes, 1_000_000)} MB."}
            else
              parse_clubs_file(body, url)
            end

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp parse_clubs_file(body, url) do
    cond do
      String.ends_with?(url, ".json") or looks_like_json?(body) ->
        parse_clubs_json(body)

      true ->
        parse_clubs_csv(body)
    end
  end

  defp looks_like_json?(body) do
    case String.trim_leading(body) do
      "{" <> _ -> true
      "[" <> _ -> true
      _ -> false
    end
  end

  defp parse_clubs_json(body) do
    case Jason.decode(body) do
      {:ok, list} when is_list(list) ->
        map =
          list
          |> Enum.reduce(%{}, fn
            %{"number" => n, "name" => name}, acc when is_binary(name) ->
              with {:ok, num} <- to_int(n) do
                Map.put(acc, num, name)
              else
                _ -> acc
              end

            _other, acc ->
              acc
          end)

        {:ok, map}

      {:ok, map} when is_map(map) ->
        result =
          map
          |> Enum.reduce(%{}, fn {k, v}, acc ->
            with {:ok, num} <- to_int(k), true <- is_binary(v) do
              Map.put(acc, num, v)
            else
              _ -> acc
            end
          end)

        {:ok, result}

      {:ok, _other} ->
        {:error, "Club names JSON must be a list or an object."}

      {:error, _reason} ->
        {:error, "Club names file is not valid JSON."}
    end
  end

  defp to_int(n) when is_integer(n), do: {:ok, n}

  defp to_int(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, ""} -> {:ok, i}
      _ -> :error
    end
  end

  defp to_int(_), do: :error

  defp parse_clubs_csv(body) do
    lines =
      body
      |> String.split(["\r\n", "\n"])
      |> Enum.reject(&(String.trim(&1) == ""))

    case lines do
      [] ->
        {:error, "Club names file is empty."}

      [header | rows] ->
        cells =
          header |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.map(&String.downcase/1)

        number_idx = Enum.find_index(cells, &(&1 == "number"))
        name_idx = Enum.find_index(cells, &(&1 == "name"))

        cond do
          is_nil(number_idx) or is_nil(name_idx) ->
            {:error, "Club names CSV must have a header with \"number\" and \"name\" columns."}

          true ->
            map =
              rows
              |> Enum.reduce(%{}, fn line, acc ->
                fields = String.split(line, ",")

                with num_raw when not is_nil(num_raw) <- Enum.at(fields, number_idx),
                     name_raw when not is_nil(name_raw) <- Enum.at(fields, name_idx),
                     {:ok, num} <- to_int(String.trim(num_raw)),
                     name <- String.trim(name_raw),
                     true <- name != "" do
                  Map.put(acc, num, name)
                else
                  _ -> acc
                end
              end)

            {:ok, map}
        end
    end
  end
end
