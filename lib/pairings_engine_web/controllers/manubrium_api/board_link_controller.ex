defmodule PairingsEngineWeb.ManubriumApi.BoardLinkController do
  @moduledoc """
  The hall boxes from the Manubrium app (Alnasl, `PairingsEngine.BoardLink`):
  the codes that reach a tournament, a new one, and withdrawing one.

  The same three things the Boards settings page does, through the same
  functions: `BoardLink.list_links/1`, `create_link/3` (its gate - whoever
  may edit, never an archived or handed-off tournament - and its ceiling)
  and `revoke_link/3`. The connect code is built by `BoardLinkAddress`, so
  the phone shows the very string the page shows and a box scans.

  What a box reports about a game reaches the app beside each board of a
  round (`Json.round/2`'s `board_report`), and only there: a board never
  enters a result.

  The owner and editors only (`Reply.tournament/3`'s `:desk`), as on the
  Boards page.
  """
  use PairingsEngineWeb, :controller

  alias PairingsEngine.BoardLink
  alias PairingsEngineWeb.{BoardLan, BoardLinkAddress}
  alias PairingsEngineWeb.ManubriumApi.{Json, Reply}

  @doc "GET /tournaments/:id/board-links - the tournament's codes and its group's."
  def index(conn, %{"id" => id}) do
    with {:ok, t, _role} <- Reply.tournament(conn, id, :desk) do
      %{tournament: own, group: group} = BoardLink.list_links(t)
      json(conn, %{links: Enum.map(own ++ group, &Json.board_link/1)})
    else
      {:halt, conn} -> conn
    end
  end

  @doc """
  POST /tournaments/:id/board-links - `{where: "lan"}` optional: a new code
  for this tournament. The answer carries the full connect code, once.
  `where: "lan"` asks for a code for a box on a desktop copy's network, as
  the Boards page's "for a box on this network" does; anywhere else it is
  an ordinary code.
  """
  def create(conn, %{"id" => id} = params) do
    with {:ok, t, _role} <- Reply.tournament(conn, id, :desk),
         {:ok, lan} <- lan(conn, params["where"]) do
      opts = if lan, do: [lan: lan.base_url], else: []

      case BoardLink.create_link(conn.assigns.current_scope, t, opts) do
        {:ok, link, secret} ->
          conn
          |> put_status(201)
          |> json(%{
            link: Json.board_link(link),
            code: BoardLinkAddress.connect_code(secret, lan && lan.base_url)
          })

        {:error, reason} ->
          Reply.refuse(conn, reason)
      end
    else
      {:halt, conn} -> conn
    end
  end

  # Asked of the listener now, as the Boards page asks it: a code with an
  # address nothing answers on is the one thing not to hand out.
  defp lan(conn, "lan") do
    if BoardLan.available?() do
      lan = BoardLan.status()
      if BoardLan.usable?(lan), do: {:ok, lan}, else: {:halt, Reply.refuse(conn, :lan_unusable)}
    else
      {:ok, nil}
    end
  end

  defp lan(_conn, _where), do: {:ok, nil}

  @doc "DELETE /tournaments/:id/board-links/:link_id - withdraws a code."
  def delete(conn, %{"id" => id, "link_id" => link_id}) do
    with {:ok, t, _role} <- Reply.tournament(conn, id, :desk) do
      with {:ok, link_id} <- Reply.to_id(link_id),
           {:ok, _link} <- BoardLink.revoke_link(conn.assigns.current_scope, t, link_id) do
        send_resp(conn, 204, "")
      else
        {:error, :not_found} -> link_not_found(conn)
        :error -> link_not_found(conn)
        {:error, reason} -> Reply.refuse(conn, reason)
      end
    else
      {:halt, conn} -> conn
    end
  end

  defp link_not_found(conn),
    do: Reply.error(conn, 404, "link_not_found", gettext("No such code on this tournament."))
end
