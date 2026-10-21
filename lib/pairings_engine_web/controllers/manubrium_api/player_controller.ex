defmodule PairingsEngineWeb.ManubriumApi.PlayerController do
  @moduledoc """
  The players from the Manubrium app: the list, a late entry, and the
  changes an arbiter makes in the middle of an event - basic fields,
  withdrawing and re-entering, absences and byes requested per round.

  Every write is `PairingsEngineWeb.DeskActions.create_player/3` or
  `update_player/5`, which the Players page calls too: the same
  `Tournaments.create_player/2` / `update_player/3` gates (late entry
  numbering, rounds already sent to FIDE, a second half-point bye) and the
  same audit rows. Where the Players page asks the arbiter to confirm, this
  answers 409 `needs_acknowledgement` with the warning ids in `confirm`;
  the app asks, and sends the change again with `acknowledged`.

  The owner and editors only (`Reply.tournament/3`'s `:desk`).
  """
  use PairingsEngineWeb, :controller

  alias PairingsEngine.Tournaments
  alias PairingsEngine.Tournaments.Player
  alias PairingsEngineWeb.DeskActions
  alias PairingsEngineWeb.ManubriumApi.{Json, Reply}

  # The fields a phone may set. Everything else on a player is the Players
  # page's: categories, ratings history, norms, pairing numbers.
  @basic ~w(name title sex fide_id fide_rating national_rating federation club birth_year)
  @on_create @basic ++ ~w(start_round)

  @acks %{
    "sent_round_changed" => :sent_round_changed,
    "second_half_bye" => :second_half_bye
  }

  @doc "GET /tournaments/:id/players"
  def index(conn, %{"id" => id}) do
    with {:ok, t, _role} <- Reply.tournament(conn, id, :desk) do
      players =
        t.id
        |> Tournaments.list_players()
        |> Enum.map(&Json.player_full/1)

      json(conn, %{players: players})
    else
      {:halt, conn} -> conn
    end
  end

  @doc "POST /tournaments/:id/players - a late entry (or any entry)."
  def create(conn, %{"id" => id} = params) do
    with {:ok, t, _role} <- Reply.tournament(conn, id, :desk) do
      attrs = params |> Map.get("player", %{}) |> take(@on_create)

      case DeskActions.create_player(t, conn.assigns.current_scope, attrs) do
        {:ok, player} ->
          conn |> put_status(201) |> json(%{player: Json.player_full(player)})

        {:error, :duplicate_fide_id} ->
          Reply.error(
            conn,
            422,
            "duplicate_fide_id",
            gettext("A player with this FIDE ID is already registered.")
          )

        {:error, reason} ->
          Reply.refuse(conn, reason)
      end
    else
      {:halt, conn} -> conn
    end
  end

  @doc """
  PATCH /tournaments/:id/players/:player_id - `{player: {...}, acknowledged: [...]}`.

  `player` may carry the basic fields, `withdrawn` (true withdraws, false
  re-enters), `absent` (the whole event), `absent_rounds` (a list of round
  numbers: the rounds the player asked to be left out of) and `bye_types`
  (`{"round": "requested-half" | "requested-zero" | "full-point"}`, where
  the tournament asks the bye type per absence).
  """
  def update(conn, %{"id" => id, "player_id" => player_id} = params) do
    with {:ok, t, _role} <- Reply.tournament(conn, id, :desk),
         %Player{} = before <- find_player(t, player_id) do
      attrs = params |> Map.get("player", %{}) |> update_attrs()

      case DeskActions.update_player(
             t,
             conn.assigns.current_scope,
             before,
             attrs,
             acknowledged(params)
           ) do
        {:ok, player} ->
          json(conn, %{player: Json.player_full(player)})

        {:error, {:needs_acknowledgement, ids}} ->
          conn
          |> put_status(409)
          |> json(%{
            error: "needs_acknowledgement",
            confirm: ids,
            message: confirm_text(ids, before, attrs)
          })

        {:error, reason} ->
          Reply.refuse(conn, reason)
      end
    else
      {:halt, conn} ->
        conn

      nil ->
        Reply.error(conn, 404, "player_not_found", gettext("No such player in this tournament."))
    end
  end

  defp find_player(t, player_id) do
    case Reply.to_id(player_id) do
      {:ok, pid} -> Tournaments.get_player(t.id, pid)
      :error -> nil
    end
  end

  defp take(attrs, fields) when is_map(attrs), do: Map.take(attrs, fields)
  defp take(_attrs, _fields), do: %{}

  defp update_attrs(attrs) when is_map(attrs) do
    base = take(attrs, @basic ++ ~w(absent bye_types))

    base
    |> put_if(attrs, "withdrawn", fn v -> {"forfeit", v in [true, "true"]} end)
    |> put_if(attrs, "absent_rounds", fn
      list when is_list(list) -> {"absent_rounds", Enum.map_join(list, ",", &to_string/1)}
      text when is_binary(text) -> {"absent_rounds", text}
      _other -> {"absent_rounds", ""}
    end)
  end

  defp update_attrs(_attrs), do: %{}

  defp put_if(acc, attrs, key, fun) do
    case Map.fetch(attrs, key) do
      {:ok, value} ->
        {k, v} = fun.(value)
        Map.put(acc, k, v)

      :error ->
        acc
    end
  end

  defp acknowledged(%{"acknowledged" => ids}) when is_list(ids),
    do: for(id <- ids, is_binary(id), ack = Map.get(@acks, id), do: ack)

  defp acknowledged(_params), do: []

  defp confirm_text([:second_half_bye], before, attrs) do
    rounds = Tournaments.second_half_bye_rounds(before, attrs)

    gettext(
      "A player gets one half-point bye per tournament (C.05). Round %{rounds} would be another. Confirm to give it anyway.",
      rounds: Enum.join(rounds, ", ")
    )
  end

  defp confirm_text(_ids, before, attrs) do
    gettext(
      "Round %{rounds} was already sent to FIDE. Confirm to change the absence anyway.",
      rounds: before |> Tournaments.sent_absence_rounds(attrs) |> Enum.join(", ")
    )
  end
end
