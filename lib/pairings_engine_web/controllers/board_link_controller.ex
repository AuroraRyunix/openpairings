defmodule PairingsEngineWeb.BoardLinkController do
  @moduledoc """
  The board link's HTTP side: `/api/boards/v1`, spoken by a box in the
  playing hall (`PairingsEngine.BoardLink`). The contract is
  `docs/board-link-api.md`; keep the two in step, because the other half is
  built from the document and not from this file.

  No session, no CSRF token, no cookie: a bearer secret on every request,
  checked by `authenticate/2` below before anything else runs. The box
  always calls; nothing here ever calls the box.

  Every error is `{"error": "<code>", "detail": "..."}`. The code is the
  contract; the detail is for whoever reads the box's log.
  """
  use PairingsEngineWeb, :controller

  alias PairingsEngine.{BoardLink, RateLimit}
  alias PairingsEngine.BoardLink.Document

  plug :authenticate

  # How often a box is asked to look. Five seconds: a round paired here is
  # on the box's screen within that, plus one fetch, and an unchanged
  # tournament costs a 304.
  @poll_seconds 5
  @max_batch 64

  @doc "The polling interval this server asks for, in seconds."
  def poll_seconds, do: @poll_seconds

  ## ---------- GET /link ----------

  def link(conn, _params) do
    body =
      conn.assigns.board_link
      |> BoardLink.listing()
      |> Map.merge(%{
        "api" => 1,
        "server" => %{
          "name" => "OpenPairings",
          "version" => to_string(Application.spec(:pairings_engine, :vsn))
        },
        "poll_seconds" => @poll_seconds
      })

    conditional(conn, etag_of(body), body)
  end

  ## ---------- POST /box ----------

  def box(conn, params) do
    link = conn.assigns.board_link

    link =
      BoardLink.touch(link, %{name: text(params["name"]), version: text(params["version"])})

    if is_map(params["boards"]), do: BoardLink.put_box_boards(link, params["boards"])

    json(conn, %{"status" => "ok"})
  end

  defp text(value) when is_binary(value), do: value
  defp text(_other), do: nil

  ## ---------- GET /tournaments/:id ----------

  def tournament(conn, %{"id" => id}) do
    with {:ok, tournament} <- covered(conn, id) do
      # The version first, and the document only for a box that does not
      # already hold it: the common request is "anything new?" and the
      # common answer is no.
      version = Document.version(tournament)

      if not_modified?(conn, version) do
        conn |> put_etag(version) |> send_resp(304, "")
      else
        conn |> put_etag(version) |> json(Document.document(tournament))
      end
    end
  end

  ## ---------- POST /tournaments/:id/games ----------

  def games(conn, %{"id" => id} = params) do
    with {:ok, tournament} <- covered(conn, id) do
      link = conn.assigns.board_link

      case params do
        %{"games" => games} when is_list(games) and length(games) <= @max_batch ->
          # Always 200 for a batch, one answer per game in order: one board
          # reporting a game that is gone must not hide that the other
          # eleven were stored.
          json(conn, %{
            "status" => "ok",
            "results" => Enum.map(games, &answer(BoardLink.report(link, tournament, &1), &1))
          })

        %{"games" => _other} ->
          error(conn, 422, "invalid_request", "games: a list of at most #{@max_batch} games")

        game ->
          case BoardLink.report(link, tournament, Map.delete(game, "id")) do
            {:ok, _answer} = ok -> json(conn, answer(ok, game))
            {:error, code, detail} -> error(conn, status_of(code), to_string(code), detail)
          end
      end
    end
  end

  defp answer({:ok, %{applied: applied, seq: seq, reason: reason}}, game) do
    %{"status" => "ok", "game" => game_id(game), "applied" => applied, "seq" => seq}
    |> then(&if(reason, do: Map.put(&1, "reason", to_string(reason)), else: &1))
  end

  defp answer({:error, code, detail}, game) do
    %{
      "status" => "error",
      "game" => game_id(game),
      "error" => to_string(code),
      "detail" => detail
    }
  end

  defp game_id(%{"game" => id}) when is_binary(id), do: id
  defp game_id(_other), do: nil

  defp status_of(:invalid_request), do: 422
  defp status_of(:not_a_game), do: 422
  defp status_of(:pairing_gone), do: 409
  defp status_of(:pairing_changed), do: 409

  ## ---------- shared ----------

  # One answer for "no such tournament" and "not yours": a code must not be
  # usable to find out which tournament ids exist.
  defp covered(conn, id) do
    case BoardLink.fetch_covered(conn.assigns.board_link, id) do
      {:ok, tournament} ->
        {:ok, tournament}

      :error ->
        error(
          conn,
          404,
          "tournament_not_found",
          "this code does not reach a tournament with that id"
        )
    end
  end

  defp conditional(conn, etag, body) do
    if not_modified?(conn, etag),
      do: conn |> put_etag(etag) |> send_resp(304, ""),
      else: conn |> put_etag(etag) |> json(body)
  end

  defp etag_of(body) do
    :crypto.hash(:sha256, :erlang.term_to_binary(body))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 20)
  end

  defp put_etag(conn, etag) do
    conn
    |> put_resp_header("etag", ~s("#{etag}"))
    |> put_resp_header("cache-control", "no-cache")
  end

  defp not_modified?(conn, etag) do
    conn
    |> get_req_header("if-none-match")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&(&1 |> String.trim() |> String.trim_leading("W/") |> String.trim("\"")))
    |> Enum.member?(etag)
  end

  defp error(conn, status, code, detail) do
    conn
    |> put_status(status)
    |> json(%{"error" => code, "detail" => detail})
    |> halt()
  end

  # The secret, then the budget. A refused secret is counted against the
  # address it came from; an accepted one against its own link, so a box
  # that has gone wrong is throttled without the hall's other machines
  # noticing.
  #
  # A right secret is never turned away for somebody else's wrong ones: the
  # box shares its address with a hall full of phones, and "guess badly
  # thirty times from the venue wifi" must not be a way to switch the boards
  # off. The address budget only decides what a WRONG secret is told.
  defp authenticate(conn, _opts) do
    address = PairingsEngineWeb.ClientIp.get(conn)

    with {:ok, secret} <- bearer(conn),
         {:ok, link} <- BoardLink.authenticate(secret, lan: on_network_listener?(conn)),
         :ok <- allowed(:board_link, Integer.to_string(link.id)) do
      RateLimit.record(:board_link, Integer.to_string(link.id))

      link =
        BoardLink.touch(link, %{
          name: header(conn, "x-board-box"),
          version: header(conn, "x-board-box-version")
        })

      assign(conn, :board_link, link)
    else
      :rate_limited ->
        conn
        |> put_resp_header("retry-after", "60")
        |> error(429, "rate_limited", "too many requests; wait and try again")

      _refused ->
        if RateLimit.allow?(:board_link_auth, address) do
          RateLimit.record(:board_link_auth, address)

          error(
            conn,
            401,
            "unauthorized",
            "no connect code, or one that is not (or no longer) valid"
          )
        else
          conn
          |> put_resp_header("retry-after", "600")
          |> error(429, "rate_limited", "too many refused codes from this address")
        end
    end
  end

  # Set by `PairingsEngineWeb.BoardLan.Plug` and by nothing else: the
  # request came in on a desktop copy's network listener, where only a code
  # made for the network is good.
  defp on_network_listener?(conn), do: conn.private[:board_lan] == true

  defp allowed(bucket, key),
    do: if(RateLimit.allow?(bucket, key), do: :ok, else: :rate_limited)

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> secret] -> {:ok, String.trim(secret)}
      ["bearer " <> secret] -> {:ok, String.trim(secret)}
      _missing -> :error
    end
  end

  defp header(conn, name) do
    case get_req_header(conn, name) do
      [value | _] -> value
      [] -> nil
    end
  end
end
