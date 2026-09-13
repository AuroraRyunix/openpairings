defmodule PairingsEngine.Federations.BEL.ResultsSource do
  @moduledoc """
  Reads the Belgian roster from OpenResults' relay
  (`GET /api/federations/bel/players`, see that repository's
  docs/federations-bel.md) instead of the KBSB data platform directly - the
  source a desktop install uses when it has no `KBSB_API_URL`/`KBSB_API_KEY`
  of its own but does have a working connection to a results site.

  ## Why this exists

  The KBSB data platform's key can never ship inside a desktop release (see
  `PairingsEngine.Federations.BEL.Api`'s moduledoc). This is the second-best
  answer: a desktop install already holds a credential for OpenResults - an
  installation key it obtained for itself, or an operator token if one is
  configured (`PairingsEngine.Publishing`) - and OpenResults holds its OWN
  copy of the KBSB key and relays a reduced roster over that same
  credential. `PairingsEngine.Federations.BEL.source/0` is what decides
  when this module is actually used, ahead of the manual file upload and
  behind the direct data-platform key.

  ## The fields it carries

  Only what OpenResults' relay sends in the first place - see that
  repository's `OpenResults.Federations.BEL.Fields.allowed/0`, its
  hand-written allowlist: `national_id`, `last_name`, `first_name`,
  `national_rating`, `fide_id`, `club_number`, `club_name`, `federation`.
  `@fields` below is that same list, written down here too so a row this
  module builds cannot silently grow an extra key the relay never sent.
  Neither `birth_year` nor `died`/`affiliated` are in it - the same as
  every uploaded-file row already stored through `Parser.parse/1`, which
  never carries the latter two either.

  ## One request, not a walk

  Unlike `Api.fetch_all/1`, which walks the KBSB export page by page, the
  results site already did that reduction and hands back the whole roster
  in one response (gzip, decoded transparently by `Req`). There is nothing
  here to paginate.

  ## ETag reuse

  The relay's response carries a strong ETag. It is remembered
  (`PairingsEngine.Meta`, see `etag_key/0`) and sent back as
  `If-None-Match` on the next pull; a 304 means the roster has not changed
  since the last successful import, and `fetch_all/0` reports that as
  `:unchanged` rather than re-downloading and re-importing a roster this
  installation already has.
  """

  alias PairingsEngine.Federations.BEL.Api, as: DataPlatformApi
  alias PairingsEngine.Meta
  alias PairingsEngine.Publishing

  @path "/api/federations/bel/players"
  @etag_key "kbsb_results_source_etag"

  # See the moduledoc's "The fields it carries" - kept in lockstep with
  # OpenResults' `OpenResults.Federations.BEL.Fields.allowed/0` by hand,
  # the same way that module is kept in lockstep with what
  # `PairingsEngine.Federations.BEL.Member`/`.Parser` consume.
  @fields ~w(national_id last_name first_name national_rating fide_id club_number club_name federation)a

  @doc "The `meta` key the last-seen ETag is stored under - public for tests only."
  def etag_key, do: @etag_key

  @doc """
  Whether this source may be tried: no direct data-platform key configured,
  and this installation holds a credential OpenResults will accept right
  now (`PairingsEngine.Publishing.can_send?/0` - the operator token, or a
  registered, non-dead installation key in public mode).
  """
  @spec available?() :: boolean()
  def available?, do: not DataPlatformApi.configured?() and Publishing.can_send?()

  @doc """
  Pulls the roster from the results site.

  Returns `{:ok, rows}` (rows shaped for `Sync.import_rows/3`), `:unchanged`
  on a 304 (nothing to import), or `{:error, message}` - a human-readable
  string, since it is shown to whoever pressed the button.
  """
  @spec fetch_all() :: {:ok, [map()]} | :unchanged | {:error, String.t()}
  def fetch_all do
    if available?() do
      do_fetch()
    else
      {:error,
       "This installation has no connection to a results site. Connect to OpenResults under " <>
         "Settings → OpenResults, or import an uploaded list file instead."}
    end
  end

  defp do_fetch do
    headers = if etag = Meta.get(@etag_key), do: [{"if-none-match", etag}], else: []
    request = Publishing.request(@path, headers: headers)

    case Req.get(request) do
      {:ok, %Req.Response{status: 304}} ->
        :unchanged

      {:ok, %Req.Response{status: 200, body: %{"players" => players}} = response} ->
        if etag = get_header(response, "etag"), do: Meta.put(@etag_key, etag)
        {:ok, Enum.map(players, &to_row/1)}

      {:ok, %Req.Response{status: 200}} ->
        {:error, "the results site answered 200 with no player list"}

      {:ok, %Req.Response{status: 404} = response} ->
        case error_code(response) do
          "not_configured" ->
            {:error,
             "the results site does not relay a Belgian roster. Ask its operator to set " <>
               "OPENRESULTS_KBSB_API_URL / OPENRESULTS_KBSB_API_KEY, or import an uploaded " <>
               "list file instead."}

          _other ->
            {:error, "no Belgian roster endpoint at the results site (404)"}
        end

      {:ok, %Req.Response{status: 401}} ->
        {:error,
         "the results site rejected this installation's credential (401). Reconnect under " <>
           "Settings → OpenResults."}

      {:ok, %Req.Response{status: 429} = response} ->
        retry = get_header(response, "retry-after")

        {:error,
         "the results site is rate-limiting this installation" <>
           if(retry, do: " - try again in #{retry}s", else: "") <> "."}

      {:ok, %Req.Response{status: status}} ->
        {:error, "the results site answered HTTP #{status}"}

      {:error, error} ->
        {:error, "could not reach the results site: #{Publishing.describe_transport(error)}"}
    end
  end

  defp get_header(response, name) do
    case Req.Response.get_header(response, name) do
      [value | _] -> value
      [] -> nil
    end
  end

  defp error_code(response) do
    case response.body do
      %{"error" => code} when is_binary(code) -> code
      _ -> nil
    end
  end

  # The results site already reduced this row to its own allowlist, with
  # string keys (it is JSON). Coerced to the atom-keyed shape
  # `Sync.import_rows/3` expects - `@fields`, nothing added: a results-site
  # row never carries `birth_year`, `died` or `affiliated`, which stay
  # absent from the map entirely, the same as every uploaded-file row.
  defp to_row(p) do
    for field <- @fields, into: %{} do
      {field, p[Atom.to_string(field)]}
    end
    |> Map.update!(:national_id, &to_string/1)
  end
end
