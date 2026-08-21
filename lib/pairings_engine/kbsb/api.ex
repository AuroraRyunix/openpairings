defmodule PairingsEngine.Kbsb.Api do
  @moduledoc """
  Reads the Belgian roster from the KBSB data platform's REST API
  (`kbsb-dataplatform`, the Odoo-synced live database), as an alternative
  source to the uploaded file `PairingsEngine.Kbsb.Parser` handles.

  This exists because the file path has one fatal operational property: a
  human has to remember to do it. A club-refresh button that silently finds
  nothing because nobody uploaded a list this season is indistinguishable,
  from the arbiter's side, from a broken button.

  ## What it does NOT change

  It replaces where the rows come from, and nothing else. The mirror in
  `kbsb_players` stays, and every consumer keeps reading it locally:
  OpenPairings pairs rounds in playing halls where the internet cannot be
  assumed, so a club lookup that needs an HTTP round trip at use time is not
  usable there. This runs once, on a button, with a network; club refresh
  runs later, possibly without one.

  ## Configuration

      config :pairings_engine, :kbsb,
        api_url: System.get_env("KBSB_API_URL"),
        api_key: System.get_env("KBSB_API_KEY")

  `api_url` is the base, without a trailing path - e.g.
  `https://kbsb-api.zerotwo.cloud`. The key travels in the `x-api-key`
  header, which is what the platform checks on every `/api` route.
  `configured?/0` is false when either is missing, and the UI hides the
  button rather than offering an action that can only fail.

  ## Pagination

  The platform paginates by cursor rather than streaming NDJSON - ordinary
  JSON, and a dropped connection costs one page rather than the whole walk.
  `fetch_all/1` follows `next_cursor` until it comes back `nil`, which the
  platform guarantees happens on the first short page, so there is never a
  wasted empty request at the end.

  A full walk is ~36 pages of 1000 at the current roster size. The API also
  supports `?since=` for incremental refreshes; this deliberately does not
  use it. The import it feeds is a full replace (see
  `PairingsEngine.Kbsb.Sync`), so a whole walk every time cannot drift out
  of step with the source, and at 36 requests there is nothing to optimise.
  """

  require Logger
  alias PairingsEngine.Kbsb.KbsbPlayer

  @page_size 1000

  # A cursor that fails to advance would spin forever on the same page. The
  # walk already refuses that (see `advance/2`), so this is a second, dumber
  # backstop against any other non-terminating shape - a platform bug, a
  # proxy replaying responses. ~36 pages expected; 500 is far past any
  # plausible roster and still bounded.
  @max_pages 500

  @receive_timeout :timer.seconds(30)

  @doc "True when both the base URL and the API key are configured."
  def configured?, do: base_url() != nil and api_key() != nil

  def base_url, do: blank_to_nil(config()[:api_url])
  def api_key, do: blank_to_nil(config()[:api_key])

  defp config, do: Application.get_env(:pairings_engine, :kbsb, [])

  # Extra options merged into every request. Exists so tests can pass a
  # `plug:` and exercise the cursor walk without standing up a server - a
  # cursor that fails to advance is the one bug in here that would hang
  # rather than fail, so it has to be reachable from a test.
  defp req_options, do: config()[:req_options] || []

  defp blank_to_nil(v) when v in [nil, ""], do: nil
  defp blank_to_nil(v), do: v

  @doc """
  Walks the whole roster export and returns `{:ok, rows}` - rows shaped for
  `PairingsEngine.Kbsb.KbsbPlayer`, ready for `Sync.import_rows/3`.

  `on_progress` is called with the running row count after each page, for
  the sync's progress line.

  Returns `{:error, message}` - a human-readable string, since it is shown
  to whoever pressed the button - on a transport failure, a non-200, an
  unparseable body, or a cursor that does not advance.
  """
  def fetch_all(on_progress \\ fn _count -> :ok end) do
    if configured?() do
      walk(nil, [], 0, on_progress)
    else
      {:error,
       "The KBSB data platform API is not configured. Set KBSB_API_URL and KBSB_API_KEY " <>
         "on the server, or import an uploaded list file instead."}
    end
  end

  defp walk(_cursor, _acc, page, _on_progress) when page >= @max_pages do
    {:error, "KBSB API export did not finish after #{@max_pages} pages - aborting."}
  end

  defp walk(cursor, acc, page, on_progress) do
    case get_page(cursor) do
      {:ok, %{rows: rows, next_cursor: next}} ->
        acc = acc ++ rows
        on_progress.(length(acc))

        case advance(cursor, next) do
          :done -> {:ok, acc}
          {:ok, next} -> walk(next, acc, page + 1, on_progress)
          {:error, _} = error -> error
        end

      {:error, _} = error ->
        error
    end
  end

  # `nil` is the platform's "that was the last page". Anything else must be
  # strictly greater than the cursor we just used, because the export is
  # ordered by id ascending and the cursor IS the id - a cursor that stalls
  # or goes backwards would re-fetch rows forever.
  defp advance(_cursor, nil), do: :done
  defp advance(nil, next) when is_integer(next), do: {:ok, next}
  defp advance(cursor, next) when is_integer(next) and next > cursor, do: {:ok, next}

  defp advance(cursor, next) do
    {:error,
     "KBSB API returned a cursor that did not advance (#{inspect(cursor)} -> #{inspect(next)})."}
  end

  defp get_page(cursor) do
    params = [limit: @page_size] ++ if(cursor, do: [cursor: cursor], else: [])

    url = base_url() |> String.trim_trailing("/") |> Kernel.<>("/api/v1/players_national/export")

    opts =
      Keyword.merge(
        [
          params: params,
          headers: [{"x-api-key", api_key()}],
          receive_timeout: @receive_timeout
        ],
        req_options()
      )

    case Req.get(url, opts) do
      {:ok, %Req.Response{status: 200, body: %{"players" => players} = body}} ->
        {:ok, %{rows: Enum.map(players, &to_row/1), next_cursor: body["next_cursor"]}}

      {:ok, %Req.Response{status: 200, body: body}} ->
        Logger.error("KBSB API export: unexpected body #{inspect(body, limit: 5)}")

        {:error,
         "KBSB API returned a 200 with no player list - is KBSB_API_URL pointing at the right host?"}

      {:ok, %Req.Response{status: 401}} ->
        {:error, "KBSB API rejected the key (401). Check KBSB_API_KEY and its scope."}

      {:ok, %Req.Response{status: 404}} ->
        {:error,
         "KBSB API has no roster export at that URL (404). KBSB_API_URL should be the base " <>
           "host only, e.g. https://kbsb-api.zerotwo.cloud"}

      {:ok, %Req.Response{status: status}} ->
        {:error, "KBSB API returned HTTP #{status}."}

      {:error, reason} ->
        {:error, "Could not reach the KBSB API: #{describe(reason)}"}
    end
  end

  defp describe(%Req.TransportError{reason: :timeout}), do: "connection timed out"
  defp describe(%Req.TransportError{reason: :nxdomain}), do: "host not found"
  defp describe(%Req.TransportError{reason: reason}), do: inspect(reason)
  defp describe(reason), do: inspect(reason)

  @doc false
  # Public only so the sync's tests can build rows the same way the real
  # walk does, without standing up an HTTP server.
  def to_row(p) do
    %{
      national_id: to_string(p["national_id"]),
      last_name: p["last_name"] || "",
      first_name: p["first_name"] || "",
      fide_id: p["fide_id"],
      club_number: club_number(p["club"]),
      club_name: p["club_name"] || "",
      federation: p["fed"] || "",
      birth_year: p["birthday"],
      died: p["died"],
      affiliated: p["affiliated"],
      # The national ELO system was retired and archived in July 2026, and
      # the export carries no rating at all. `national_rating` survives as
      # an import/manual-entry field only - see PairingsEngine.RatingRefresh.
      national_rating: nil
    }
  end

  # `club = 0` is the platform's "no club" sentinel and is never NULL there.
  # Stored as nil so `ClubRefresh`'s "never propose a blank club" rule reads
  # it as absent, rather than proposing the literal club number 0.
  defp club_number(0), do: nil
  defp club_number(n), do: n

  @doc false
  def page_size, do: @page_size

  @doc false
  def schema, do: KbsbPlayer
end
