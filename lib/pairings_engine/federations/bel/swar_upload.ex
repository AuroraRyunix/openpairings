defmodule PairingsEngine.Federations.BEL.SwarUpload do
  @moduledoc """
  Sends a tournament's generated SWAR results page
  (`PairingsEngine.Federations.BEL.SwarPublish.export/1`) to the Belgian
  federation's own results site (`frbe-kbsb.be`) - the same two-step
  protocol SWAR itself performs when a club "sends" a tournament.

  This is a different server from `PairingsEngine.Publishing`'s OpenResults:
  the federation's site is public, has no authentication, already carries
  2,117 real tournaments, and nothing here can take a page back down once
  the federation has indexed it. See the "guard rails" section below.

  ## The two steps

  Step 1, `upload/1` - `PUT .../apiTournamentUpload.php` with the generated
  HTML as the body and a `User-Agent` beginning `Swar/` (the server refuses
  anything else). Success is a 200; failure is usually a 400 with a JSON
  array of `%{"message" => ..., "value" => ...}` entries - specific enough
  ("bad Guid 8 hexa", "bad Guid closing char") to show an arbiter verbatim
  rather than translating into a generic "upload failed".

  Step 2, `index/1` - `GET .../SwarTournamentUpload.php?Guid=<guid>`, which
  tells the federation to actually index what step 1 staged. It answers
  with an HTML confirmation page, not JSON; a 200 is success and the body is
  never read for meaning (it is French prose meant for a human, not this
  program). Both steps require `tournament.swar_guid` (minted by
  `SwarPublish.ensure_guid!/1`, which `upload/1` calls first).

  ## The curly braces

  A guid, in the shape `SwarPublish.generate_guid/1` documents, is itself
  `[prefix]-[date]-[hex]-{[uuid]}` - it carries its OWN literal `{`/`}`
  around the UUID half. Building step 2's URL through Req's `params:` option
  runs the value through `URI.encode_query/1`, which percent-encodes those
  into `%7B`/`%7D` - confirmed by hand (see `swar_upload_test.exs`) against
  what a real request actually puts on the wire, using `Req.Test`'s stub to
  read `conn.query_string` back. The federation's own upload script expects
  the literal characters, the same as a real SWAR install sends, so
  `index/1` builds the query string by hand instead of via `params:` -
  string concatenation into `url:` leaves `URI.parse/1` and `URI.to_string/1`
  untouched, which is what carries the braces through unencoded.

  ## Recoverable, not "start over"

  A PUT that lands followed by a GET that times out is a normal outcome,
  not a bug: the file is staged on the federation's server under this
  tournament's guid, and simply is not indexed yet. `index/1` is public and
  reusable on its own for exactly that - a caller can retry JUST step 2,
  with no re-upload, because the guid it needs is already persisted.
  `publish/1` runs both and tells the caller which step failed
  (`:upload` vs `:index`) so a settings page can offer the right retry
  rather than a blanket "try again"; `staged_but_not_indexed?/1` reads that
  same state back from the two stored timestamps so the offer survives a
  page reload or a different session, not just this one process.

  ## Guard rails

  **Never automatic.** Every function here is called by a person pressing a
  button - nothing enqueues a call to this module, nothing retries one on a
  timer, and nothing here runs from `PairingsEngine.Publishing`'s drain or
  any other background process. A publish to OpenResults can be taken back
  (`Publishing.take_down/1`); a publish here cannot, from this program, at
  all.

  **Not gated in here.** The `bel_swar_publish` feature and the admin role
  are both UI/route concerns, checked by the caller before either function
  below is reached - see `PairingsEngine.Features`'s moduledoc for why a
  pack "owns entrances, never stored values", and
  `PairingsEngineWeb.SettingsExportLive` for where both checks actually
  live (once in the markup, once again in the event handler, since a
  control absent from the page is still an event anybody can send).

  **Writability is checked here anyway.** `upload/1` and `index/1` each
  refuse on an archived or handed-off tournament (`Tournaments.
  ensure_writable/1`) in their own right, not only through `publish/1` -
  the same "each of those in its own right" reasoning
  `PairingsEngine.Publishing.rotate_address/1`'s moduledoc gives for why
  `take_down/1` and `rotate_public_slug/1` both check it independently,
  and for the same failure mode: a caller reaching `index/1` directly (the
  "Finish indexing" retry) has to meet the gate too.

  **The audit trail is the caller's job.** Same architecture as everywhere
  else in this app (see `PairingsEngine.Audit`'s moduledoc) - the event
  handler that calls `publish/1`/`index/1` logs the outcome immediately
  after, not this module.
  """

  import Ecto.Query

  alias PairingsEngine.{Publishing, Repo, Tournaments}
  alias PairingsEngine.Federations.BEL.SwarPublish
  alias PairingsEngine.Tournaments.Tournament

  require Logger

  @doc "Where step 1 PUTs the generated HTML - the federation's upload intake."
  def upload_url, do: Keyword.fetch!(config(), :upload_url)

  @doc "Where step 2 GETs to ask the federation to index what step 1 staged."
  def index_url, do: Keyword.fetch!(config(), :index_url)

  defp config, do: Application.get_env(:pairings_engine, :bel_swar_upload, [])

  # A generous ceiling rather than `Publishing`'s 15s: the body here is a
  # whole results page (a few hundred KB on a long tournament) going to a
  # server on someone else's infrastructure, not a small JSON snapshot.
  @timeout 30_000

  @doc """
  Runs both steps for `tournament`: `upload/1` then, if that lands,
  `index/1`.

  Returns:

    * `{:ok, tournament}` - both steps succeeded. `swar_uploaded_at` and
      `swar_published_at` are both stamped to now.
    * `{:error, :upload, message}` - step 1 did not succeed (a refusal, a
      transport failure, or the federation rejecting the file). Nothing
      changed - whatever the federation was already serving for this
      tournament, if anything, is untouched.
    * `{:error, :index, message, tournament}` - step 1 succeeded
      (`swar_uploaded_at` moved, and the returned tournament reflects it)
      but step 2 did not confirm it. Recoverable: call `index/1` again
      later, which needs no re-upload.

  Never automatic, never gated in here - see the moduledoc.
  """
  @spec publish(Tournament.t()) ::
          {:ok, Tournament.t()}
          | {:error, :upload, String.t()}
          | {:error, :index, String.t(), Tournament.t()}
  def publish(%Tournament{} = tournament) do
    case upload(tournament) do
      {:ok, uploaded} ->
        case index(uploaded) do
          {:ok, indexed} -> {:ok, indexed}
          {:error, message} -> {:error, :index, message, uploaded}
        end

      {:error, message} ->
        {:error, :upload, message}
    end
  end

  @doc """
  Step 1 alone: ensures a guid (`SwarPublish.ensure_guid!/1`), builds the
  current HTML (`SwarPublish.export/1` - rebuilt fresh every call, the same
  "payload rebuilt at send time" reasoning `PairingsEngine.Publishing` gives
  for OpenResults, so what goes out is always today's standings and
  results, never a stale copy from an earlier attempt), and `PUT`s it.

  On success, stamps and persists `swar_uploaded_at` and returns the
  updated tournament. On failure, returns `{:error, message}` and changes
  nothing.
  """
  @spec upload(Tournament.t()) :: {:ok, Tournament.t()} | {:error, String.t()}
  def upload(%Tournament{} = tournament) do
    with :ok <- writable(tournament) do
      do_upload(tournament)
    end
  end

  defp do_upload(tournament) do
    tournament = SwarPublish.ensure_guid!(tournament)
    html = SwarPublish.export(tournament)

    request =
      Req.new(
        url: upload_url(),
        user_agent: user_agent(),
        headers: [{"content-type", "text/html; charset=utf-8"}],
        body: html,
        receive_timeout: @timeout,
        retry: false
      )
      |> maybe_put_test_plug()

    case Req.put(request) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        {:ok, mark_uploaded(tournament)}

      {:ok, %Req.Response{status: 400, body: body}} ->
        log_and_error(tournament, :upload, describe_kbsb_error(body))

      {:ok, %Req.Response{status: status, body: body}} ->
        log_and_error(
          tournament,
          :upload,
          "the federation answered #{status}: #{Publishing.describe_body(body)}"
        )

      {:error, reason} ->
        log_and_error(tournament, :upload, Publishing.describe_transport(reason))
    end
  end

  @doc """
  Step 2 alone: asks the federation to index whatever is currently staged
  under `tournament`'s guid. Reusable on its own, with no re-upload - see
  the moduledoc's "Recoverable" section.

  Refuses with a plain message when `tournament` has never been uploaded at
  all (no guid yet) - there is nothing on the federation's server to index.

  On success, stamps and persists `swar_published_at` and returns the
  updated tournament. On failure, returns `{:error, message}` and changes
  nothing.
  """
  @spec index(Tournament.t()) :: {:ok, Tournament.t()} | {:error, String.t()}
  def index(%Tournament{} = tournament) do
    with :ok <- writable(tournament),
         :ok <- has_guid(tournament) do
      do_index(tournament)
    end
  end

  defp do_index(tournament) do
    # NOT built through Req's `params:` option - see the moduledoc. That
    # option runs the value through `URI.encode_query/1`, which percent-
    # encodes the `{`/`}` this guid's own shape already contains into
    # `%7B`/`%7D`; string concatenation into `url:` leaves them literal,
    # which is what the federation's own script expects.
    # Percent-encode the braces, do not send them raw.
    #
    # SWAR's own documentation says the guid must "retain its { and }", and
    # curl needs `--globoff` to manage it - which reads as "the server wants
    # literal braces". It does not: `{` and `}` are not legal in an HTTP/1.1
    # request target at all, and curl only manages it by knowingly sending an
    # illegal one. Mint refuses, and the first real publish came back
    #
    #   {:invalid_request_target,
    #    ".../SwarTournamentUpload.php?Guid=303-260812-379cf909-{03276dc2-...}"}
    #
    # having never left the machine. The federation's own published URLs are
    # percent-encoded - `.../260902-000331af-%7B5b75f205-...%7D.html` - and
    # PHP decodes `%7B` back to `{` before the script ever sees it, so this is
    # the same request by the only spelling a conforming client can send.
    url =
      index_url() <>
        "?Guid=" <> URI.encode(tournament.swar_guid, &URI.char_unreserved?/1)

    request =
      Req.new(
        url: url,
        user_agent: user_agent(),
        receive_timeout: @timeout,
        retry: false
      )
      |> maybe_put_test_plug()

    case Req.get(request) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        {:ok, mark_indexed(tournament)}

      {:ok, %Req.Response{status: 400, body: body}} ->
        log_and_error(tournament, :index, describe_kbsb_error(body))

      {:ok, %Req.Response{status: status, body: body}} ->
        log_and_error(
          tournament,
          :index,
          "the federation answered #{status}: #{Publishing.describe_body(body)}"
        )

      {:error, reason} ->
        log_and_error(tournament, :index, Publishing.describe_transport(reason))
    end
  end

  defp log_and_error(tournament, step, message) do
    Logger.warning(
      "SWAR #{step} to the federation failed for tournament #{tournament.id}: #{message}"
    )

    {:error, message}
  end

  defp has_guid(%Tournament{swar_guid: guid}) when is_binary(guid) and guid != "", do: :ok

  defp has_guid(%Tournament{}),
    do: {:error, "nothing has been uploaded for this tournament yet - press Publish first"}

  @doc """
  Whether `tournament` was successfully uploaded (step 1) more recently
  than it was last confirmed indexed (step 2) - including "uploaded and
  never indexed at all".

  True is the signal that retrying `index/1` alone is what would fix
  things, not a fresh `upload/1` - what a settings page uses to decide
  whether to offer "Finish indexing" beside "Publish". Reads the two
  persisted timestamps rather than any in-memory state, so the offer
  survives a page reload or a different browser tab, not just the process
  that made the failing attempt.
  """
  @spec staged_but_not_indexed?(Tournament.t()) :: boolean()
  def staged_but_not_indexed?(%Tournament{swar_uploaded_at: nil}), do: false

  def staged_but_not_indexed?(%Tournament{swar_published_at: nil}), do: true

  def staged_but_not_indexed?(%Tournament{swar_uploaded_at: up, swar_published_at: pub}),
    do: DateTime.compare(up, pub) == :gt

  # `"Swar/v7.00"` by default - the exact prefix the federation's intake
  # requires (anything not starting `Swar/` is refused outright), built from
  # the same configurable version string `SwarPublish` stamps into the
  # document's own `<meta name='Version'>` tag, so the two never disagree
  # about what this installation claims to be.
  defp user_agent, do: "Swar/#{SwarPublish.version()}"

  defp mark_uploaded(%Tournament{id: id} = tournament) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    Repo.update_all(from(t in Tournament, where: t.id == ^id), set: [swar_uploaded_at: now])
    %{tournament | swar_uploaded_at: now}
  end

  defp mark_indexed(%Tournament{id: id} = tournament) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    Repo.update_all(from(t in Tournament, where: t.id == ^id), set: [swar_published_at: now])
    %{tournament | swar_published_at: now}
  end

  defp writable(%Tournament{} = tournament) do
    case Tournaments.ensure_writable(tournament) do
      :ok -> :ok
      {:error, :archived} -> {:error, "this tournament is archived"}
      {:error, :handed_off} -> {:error, refusal_handed_off()}
    end
  end

  defp refusal_handed_off,
    do: "this tournament has been handed off to another copy of the app - take it back first"

  # The KBSB intake's own failure shape: a 400 with a JSON array of
  # `%{"message" => ..., "value" => ...}` entries (e.g. `"meta-error"` /
  # `"bad Guid date"`). Surfaced as `"message: value"`, joined, because that
  # is specific enough for an arbiter to act on and "upload failed" is not.
  # Falls back to `Publishing.describe_body/1`'s generic slice for anything
  # that doesn't match - a body Req didn't recognise as JSON (still tried
  # here once, in case the federation sent the right bytes with the wrong
  # `Content-Type`), or a JSON shape this format doesn't document.
  defp describe_kbsb_error(body) when is_list(body), do: format_kbsb_errors(body)

  defp describe_kbsb_error(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_list(decoded) -> format_kbsb_errors(decoded)
      _ -> Publishing.describe_body(body)
    end
  end

  defp describe_kbsb_error(body), do: Publishing.describe_body(body)

  defp format_kbsb_errors([]), do: "the federation rejected this upload"

  defp format_kbsb_errors(entries) do
    entries
    |> Enum.map(&format_kbsb_message/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> Publishing.describe_body(entries)
      messages -> Enum.join(messages, "; ")
    end
  end

  defp format_kbsb_message(%{"message" => message, "value" => value})
       when is_binary(message) and is_binary(value),
       do: "#{message}: #{value}"

  defp format_kbsb_message(%{"message" => message}) when is_binary(message), do: message
  defp format_kbsb_message(_), do: nil

  # Same convention `PairingsEngine.Keycloak` and `PairingsEngine.Publishing`
  # already follow: in prod nothing is configured, so requests go out for
  # real; `config/test.exs` points this at a `Req.Test` stub name, and
  # THIS is the one HTTP client in the app that a stray request from a test
  # run must never bypass - see the moduledoc's opening paragraph.
  defp maybe_put_test_plug(request) do
    case Application.get_env(:pairings_engine, :bel_swar_upload_req_plug) do
      nil -> request
      name -> Req.merge(request, plug: {Req.Test, name})
    end
  end
end
