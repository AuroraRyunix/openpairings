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

  Adding from a list is the Players page's search and pick
  (`PairingsEngineWeb.PlayerLookup`): the same hits, and a pick fills the
  player with the same values the add form would have been filled with.

  Requested byes (`byes/2`) are the player dialog's absences and bye types,
  written through the same `update_player/5`.

  The owner and editors only (`Reply.tournament/3`'s `:desk`), as on the
  Players page.
  """
  use PairingsEngineWeb, :controller

  alias PairingsEngine.{ByeTypes, Fide, Standings, Tournaments}
  alias PairingsEngine.Federations.BEL.Members
  alias PairingsEngine.Tournaments.Player
  alias PairingsEngineWeb.{DeskActions, PlayerLookup}
  alias PairingsEngineWeb.ManubriumApi.{Json, Reply}

  @min_query 3
  @max_results 25

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
      typed = ByeTypes.stored_by_player(t.id)

      players =
        t.id
        |> Tournaments.list_players()
        |> Enum.map(&Json.player_full(&1, Map.get(typed, &1.id, %{})))

      json(conn, %{players: players})
    else
      {:halt, conn} -> conn
    end
  end

  @doc """
  GET /tournaments/:id/player-search?q=&source=fide|bel - the add form's
  search (`PlayerLookup.search/3`), at least three characters, at most 25
  hits, each with what picking it would fill in.
  """
  def search(conn, %{"id" => id} = params) do
    scope = conn.assigns.current_scope

    with {:ok, t, _role} <- Reply.tournament(conn, id, :desk),
         {:ok, query} <- query(conn, params["q"]),
         {:ok, source} <- source(conn, scope, params["source"] || "fide") do
      known = known_players(t)

      rows =
        case source do
          "fide" ->
            bel? = PlayerLookup.bel_lookup?(scope)

            t
            |> PlayerLookup.search(query, false)
            |> Map.fetch!(:fide)
            |> Enum.take(@max_results)
            |> Enum.map(&search_row("fide", PlayerLookup.fide_values(t, &1, bel?), known))

          "bel" ->
            t
            |> PlayerLookup.search(query, true)
            |> Map.fetch!(:bel)
            |> Enum.take(@max_results)
            |> Enum.map(&search_row("bel", PlayerLookup.bel_values(t, &1), known))
        end

      json(conn, %{results: rows})
    else
      {:halt, conn} -> conn
    end
  end

  defp query(conn, q) when is_binary(q) do
    q = String.trim(q)

    if String.length(q) >= @min_query,
      do: {:ok, q},
      else: query(conn, nil)
  end

  defp query(conn, _q),
    do:
      {:halt,
       Reply.error(
         conn,
         422,
         "query_too_short",
         gettext("Type at least %{n} characters to search.", n: @min_query)
       )}

  defp source(_conn, _scope, "fide"), do: {:ok, "fide"}

  defp source(conn, scope, "bel") do
    if PlayerLookup.bel_available?(scope),
      do: {:ok, "bel"},
      else: {:halt, source_refused(conn)}
  end

  defp source(conn, _scope, _other), do: {:halt, source_refused(conn)}

  defp source_refused(conn),
    do:
      Reply.error(
        conn,
        422,
        "unknown_source",
        gettext("Search the FIDE list, or the Belgian list where it is switched on.")
      )

  defp search_row(source, values, known) do
    %{
      source: source,
      fide_id: values["fide_id"],
      national_id: blank_nil(values["national_id"]),
      name: values["name"],
      federation: blank_nil(values["federation"]),
      title: blank_nil(values["title"]),
      sex: blank_nil(values["sex"]),
      birth_year: values["birth_year"],
      fide_rating: values["fide_rating"],
      national_rating: values["national_rating"],
      club: blank_nil(values["club"]),
      already_in: already_in?(values, known)
    }
  end

  # The FIDE ids and national ids already in the tournament.
  defp known_players(t) do
    players = Tournaments.list_players(t.id)

    {players |> MapSet.new(& &1.fide_id) |> MapSet.delete(nil),
     players |> MapSet.new(& &1.national_id) |> MapSet.delete(nil) |> MapSet.delete("")}
  end

  defp already_in?(values, {fide_ids, national_ids}) do
    (is_integer(values["fide_id"]) and MapSet.member?(fide_ids, values["fide_id"])) or
      (values["national_id"] not in [nil, ""] and
         MapSet.member?(national_ids, to_string(values["national_id"])))
  end

  defp blank_nil(value) when value in [nil, ""], do: nil
  defp blank_nil(value), do: value

  @doc """
  POST /tournaments/:id/players - a late entry (or any entry). With
  `player.from` (`{source: "fide", fide_id}` or `{source: "bel",
  national_id}`) the player is filled from that list as the Players page's
  pick fills its form; `start_round` may come beside it.
  """
  def create(conn, %{"id" => id, "player" => %{"from" => from} = player}) do
    scope = conn.assigns.current_scope

    with {:ok, t, _role} <- Reply.tournament(conn, id, :desk),
         {:ok, values} <- from_list(conn, t, scope, from),
         :ok <- not_already_in(conn, t, values) do
      attrs = Map.merge(values, take(player, ~w(start_round)))
      add(conn, t, attrs)
    else
      {:halt, conn} -> conn
    end
  end

  def create(conn, %{"id" => id} = params) do
    with {:ok, t, _role} <- Reply.tournament(conn, id, :desk) do
      attrs = params |> Map.get("player", %{}) |> take(@on_create)
      add(conn, t, attrs)
    else
      {:halt, conn} -> conn
    end
  end

  defp from_list(conn, t, scope, %{"source" => "fide", "fide_id" => fide_id}) do
    case Fide.get_player(fide_id) do
      nil -> {:halt, Reply.refuse(conn, :not_in_list)}
      fp -> {:ok, PlayerLookup.fide_values(t, fp, PlayerLookup.bel_lookup?(scope))}
    end
  end

  defp from_list(conn, t, scope, %{"source" => "bel", "national_id" => national_id})
       when is_binary(national_id) or is_integer(national_id) do
    with {:ok, "bel"} <- source(conn, scope, "bel") do
      case Members.find_by_national_id(to_string(national_id)) do
        nil -> {:halt, Reply.refuse(conn, :not_in_list)}
        kp -> {:ok, PlayerLookup.bel_values(t, kp)}
      end
    end
  end

  defp from_list(conn, _t, _scope, _from),
    do:
      {:halt,
       Reply.error(
         conn,
         400,
         "bad_request",
         gettext("Name the list and the player: a FIDE id or a national id.")
       )}

  defp not_already_in(conn, t, values) do
    if already_in?(values, known_players(t)),
      do: {:halt, Reply.refuse(conn, :duplicate_player)},
      else: :ok
  end

  defp add(conn, t, attrs) do
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
  end

  @doc """
  PATCH /tournaments/:id/players/:player_id - `{player: {...}, acknowledged: [...]}`.

  `player` may carry the basic fields, `withdrawn` (true withdraws, false
  re-enters), `absent` (the whole event), `absent_rounds` (a list of round
  numbers: the rounds the player asked to be left out of) and `bye_types`
  (`{"round": "requested-half" | "requested-zero" | "full-point"}`, where
  the tournament asks the bye type per absence).

  `present` is the Players page's "Pr." column: `false` marks the player
  absent for the whole event (`absent`), `true` brings them back - the
  check-in at the door.
  """
  def update(conn, %{"id" => id, "player_id" => player_id} = params) do
    with {:ok, t, _role} <- Reply.tournament(conn, id, :desk),
         %Player{} = before <- find_player(t, player_id) do
      attrs = params |> Map.get("player", %{}) |> update_attrs()
      save(conn, t, before, attrs, params)
    else
      {:halt, conn} -> conn
      nil -> player_not_found(conn)
    end
  end

  @doc """
  PUT /tournaments/:id/players/:player_id/byes - `{byes: [{round, kind}],
  acknowledged: [...]}`: the rounds not yet paired that the player asked to
  be left out of, and what each is (`Json.bye_kinds/1`), replacing what was
  asked for those rounds. Paired rounds are left as they are, and naming
  one is refused. Written as the player dialog writes absences and bye
  types: `absent_rounds` and `bye_types` through `update_player/5`.
  """
  def byes(conn, %{"id" => id, "player_id" => player_id} = params) do
    with {:ok, t, _role} <- Reply.tournament(conn, id, :desk),
         %Player{} = before <- find_player(t, player_id),
         {:ok, requested} <- requested_byes(conn, t, params["byes"]) do
      paired = Standings.rounds_paired(t.id)

      kept =
        before.absent_rounds
        |> Player.parse_absent_rounds()
        |> Enum.filter(&(&1 <= paired))

      rounds = Enum.sort(kept ++ Map.keys(requested))

      bye_types =
        for {round, kind} <- requested, kind != "absent", into: %{} do
          {Integer.to_string(round), kind}
        end

      attrs = %{"absent_rounds" => Enum.map_join(rounds, ",", &Integer.to_string/1)}
      attrs = if bye_types == %{}, do: attrs, else: Map.put(attrs, "bye_types", bye_types)

      save(conn, t, before, attrs, params)
    else
      {:halt, conn} -> conn
      nil -> player_not_found(conn)
    end
  end

  # `%{round => kind}`, every round a number of this tournament not yet
  # paired, each named once, every kind one `Json.bye_kinds/1` offers.
  defp requested_byes(conn, t, list) when is_list(list) do
    kinds = t |> Json.bye_kinds() |> Enum.map(& &1.id)
    paired = Standings.rounds_paired(t.id)

    parsed =
      Enum.map(list, fn
        %{"round" => round, "kind" => kind} -> {Reply.to_id(round), kind}
        _other -> :error
      end)

    cond do
      Enum.any?(parsed, &(not match?({{:ok, n}, _kind} when is_integer(n), &1))) ->
        {:halt, bad_byes(conn)}

      Enum.any?(parsed, fn {{:ok, n}, _kind} -> n > (t.rounds_count || 0) end) ->
        {:halt, bad_byes(conn)}

      length(Enum.uniq_by(parsed, fn {{:ok, n}, _kind} -> n end)) != length(parsed) ->
        {:halt, bad_byes(conn)}

      Enum.any?(parsed, fn {_round, kind} -> kind not in kinds end) ->
        {:halt, Reply.refuse(conn, :unknown_bye_kind)}

      Enum.any?(parsed, fn {{:ok, n}, _kind} -> n <= paired end) ->
        {:halt, Reply.refuse(conn, :round_paired)}

      true ->
        {:ok, Map.new(parsed, fn {{:ok, n}, kind} -> {n, kind} end)}
    end
  end

  defp requested_byes(conn, _t, _list), do: {:halt, bad_byes(conn)}

  defp bad_byes(conn),
    do:
      Reply.error(
        conn,
        400,
        "bad_request",
        gettext("A list of byes is needed: each a round of this tournament, once, and a kind.")
      )

  defp save(conn, t, before, attrs, params) do
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
  end

  defp player_not_found(conn),
    do: Reply.error(conn, 404, "player_not_found", gettext("No such player in this tournament."))

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
    |> put_if(attrs, "present", fn v -> {"absent", v not in [true, "true"]} end)
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
