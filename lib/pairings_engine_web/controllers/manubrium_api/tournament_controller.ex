defmodule PairingsEngineWeb.ManubriumApi.TournamentController do
  @moduledoc """
  Running a tournament from the Manubrium app: the tournament list, a
  tournament, a round, the hall's queue (results and incidents), clearing a
  result, pairing and unpairing, a round's public level, the standings and
  the incidents.

  Every write is the desk's or the hall's own function, never a copy:

    * results and incidents - `Mobile.Sync.submit/2`, under the device's
      account-bound code (`Manubrium.enrollment_for/2`): the hall's queue,
      its compare-and-set, its refusals, its audit rows;
    * clearing - `Manubrium.clear_result/4`, the hall's deputy clear;
    * pairing, unpairing, the public level - `PairingsEngineWeb.DeskActions`,
      which the Pairings page calls too.

  A new tournament is `DeskActions.create_tournament/2`, the very function
  the "New tournament" form calls: the account's defaults, the derived
  type, the seeded round dates, the hosted edition's limit, the audit row.

  Who may: `Reply.tournament/3` - `:hall` (owner, editor, arbiter) for the
  round and the queue, `:desk` (owner, editor:
  `Tournaments.get_authorized_tournament/2`, the desk pages' own gate) for
  everything else. Anyone signed in may make a tournament of their own.
  """
  use PairingsEngineWeb, :controller

  alias PairingsEngine.{Accounts, Incidents, Manubrium, PostponedGames, Tournaments}
  alias PairingsEngine.Mobile.Sync
  alias PairingsEngine.Tournaments.Tournament
  alias PairingsEngineWeb.{DeskActions, MobileAppController, PlayerLookup}
  alias PairingsEngineWeb.ManubriumApi.{Json, Reply}

  ## ---------- reading ----------

  @doc "GET /tournaments - every tournament the account works in, with its role."
  def index(conn, _params) do
    rows =
      conn.assigns.current_scope
      |> Tournaments.hall_tournaments()
      |> Enum.map(fn {t, role} -> Json.tournament_line(t, role) end)

    json(conn, %{tournaments: rows})
  end

  @doc """
  GET /tournament-options - what the "New tournament" screen offers: the
  pairing systems the desk's form offers, where players can be looked up,
  and what a new tournament starts from for this account.
  """
  def options(conn, _params) do
    scope = conn.assigns.current_scope
    defaults = DeskActions.new_tournament_params(account_defaults(scope))
    hidden = Accounts.TournamentDefaults.hidden_params(account_defaults(scope))

    sources =
      [%{id: "fide", label: gettext("FIDE rating list")}] ++
        if PlayerLookup.bel_available?(scope),
          do: [%{id: "bel", label: gettext("Belgian member list")}],
          else: []

    json(conn, %{
      systems:
        Enum.map(
          Tournament.pairing_systems(),
          &%{id: &1, label: Tournament.pairing_system_label(&1)}
        ),
      player_sources: sources,
      defaults: %{
        system: defaults["pairing_system"],
        rounds_count: to_int(defaults["rounds_count"]),
        time_control: blank_nil(defaults["rate_of_play"]),
        city: blank_nil(defaults["city"]),
        venue: nil,
        federation: blank_nil(hidden["federation"]),
        rated: false
      }
    })
  end

  @doc """
  POST /tournaments - `{tournament: {name, start_date, end_date, city,
  venue, system, rounds_count, time_control, federation, rated}}`: a new
  individual tournament owned by this account, made exactly as the desk's
  "New tournament" form makes one (`DeskActions.create_tournament/2`).
  """
  def create(conn, %{"tournament" => attrs}) when is_map(attrs) do
    scope = conn.assigns.current_scope

    with {:ok, params} <- create_params(conn, attrs),
         params = Map.merge(DeskActions.new_tournament_params(account_defaults(scope)), params),
         {:ok, t} <- created(conn, DeskActions.create_tournament(scope, params)) do
      conn |> put_status(201) |> json(%{tournament: Json.tournament_line(t, :owner)})
    else
      {:halt, conn} -> conn
    end
  end

  def create(conn, _params),
    do: Reply.error(conn, 400, "bad_request", gettext("A tournament is needed."))

  defp created(_conn, {:ok, t}), do: {:ok, t}
  defp created(conn, {:error, reason}), do: {:halt, Reply.refuse(conn, reason)}

  defp account_defaults(scope), do: Accounts.get_user!(scope.user.id).tournament_defaults

  # The app's names for the form's fields: `system` is the pairing system,
  # `time_control` the rate of play (the field every report reads), `rated`
  # the FIDE-rated tick. The end date dates the last round; every other
  # round is dated to the start, as the form does, and the Dates page
  # refines them.
  defp create_params(conn, attrs) do
    start_date = attrs |> Map.get("start_date") |> text()
    end_date = attrs |> Map.get("end_date") |> text()
    rounds = to_int(attrs["rounds_count"])

    with :ok <- check_date(conn, start_date),
         :ok <- check_date(conn, end_date),
         :ok <- check_order(conn, start_date, end_date) do
      params =
        %{
          "name" => text(attrs["name"]),
          "city" => text(attrs["city"]),
          "venue" => text(attrs["venue"]),
          "federation" => attrs["federation"] |> text() |> String.upcase(),
          "rate_of_play" => text(attrs["time_control"]),
          "pairing_system" => text(attrs["system"]),
          "rounds_count" =>
            if(rounds, do: Integer.to_string(rounds), else: text(attrs["rounds_count"])),
          "start_date" => start_date,
          "fide_homologated" => attrs["rated"] in [true, "true"]
        }
        |> Map.reject(fn {key, value} ->
          value == "" and key != "name"
        end)
        |> put_round_dates(start_date, end_date, rounds)

      {:ok, params}
    end
  end

  defp put_round_dates(params, start_date, end_date, rounds)
       when start_date != "" and end_date not in ["", start_date] and is_integer(rounds) and
              rounds > 1,
       do: Map.put(params, "round_dates", List.duplicate(start_date, rounds - 1) ++ [end_date])

  defp put_round_dates(params, _start_date, _end_date, _rounds), do: params

  defp check_date(_conn, ""), do: :ok

  defp check_date(conn, date) do
    case Date.from_iso8601(date) do
      {:ok, _date} ->
        :ok

      {:error, _reason} ->
        {:halt, Reply.error(conn, 422, "bad_date", gettext("Dates are written as YYYY-MM-DD."))}
    end
  end

  defp check_order(conn, start_date, end_date)
       when start_date != "" and end_date != "" and end_date < start_date,
       do:
         {:halt,
          Reply.error(
            conn,
            422,
            "bad_date",
            gettext("The tournament cannot end before it starts.")
          )}

  defp check_order(_conn, _start_date, _end_date), do: :ok

  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(value) when is_integer(value), do: Integer.to_string(value)
  defp text(_value), do: ""

  defp to_int(value) when is_integer(value), do: value

  defp to_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp to_int(_value), do: nil

  defp blank_nil(value) when value in [nil, ""], do: nil
  defp blank_nil(value), do: value

  @doc "GET /tournaments/:id"
  def show(conn, %{"id" => id}) do
    with {:ok, t, role} <- Reply.tournament(conn, id, :hall) do
      json(conn, %{tournament: Json.tournament(t, role)})
    else
      {:halt, conn} -> conn
    end
  end

  @doc "GET /tournaments/:id/rounds/:number"
  def round(conn, %{"id" => id, "number" => number}) do
    with {:ok, t, _role} <- Reply.tournament(conn, id, :hall),
         {:ok, n} <- round_number(conn, number),
         {:ok, round} <- fetch_round(conn, t, n) do
      json(conn, %{round: Json.round(t, round)})
    else
      {:halt, conn} -> conn
    end
  end

  @doc "GET /tournaments/:id/standings"
  def standings(conn, %{"id" => id}) do
    with {:ok, t, _role} <- Reply.tournament(conn, id, :desk) do
      json(conn, %{standings: Json.standings(t)})
    else
      {:halt, conn} -> conn
    end
  end

  @doc "GET /tournaments/:id/incidents - the desk's incident list, photos left out."
  def incidents(conn, %{"id" => id} = params) do
    with {:ok, t, _role} <- Reply.tournament(conn, id, :desk) do
      opts =
        case Reply.to_id(params["round"]) do
          {:ok, n} -> [round_number: n]
          :error -> []
        end

      json(conn, %{incidents: t.id |> Incidents.list(opts) |> Enum.map(&Json.incident/1)})
    else
      {:halt, conn} -> conn
    end
  end

  ## ---------- the hall: results and incidents ----------

  @doc """
  POST /tournaments/:id/sync - `{entries: [...]}`: the app's offline queue,
  judged by `Mobile.Sync` exactly as the hall pages' queue is. The entries
  never name a code; the device's own is filled in here.
  """
  def sync(conn, %{"id" => id, "entries" => entries}) when is_list(entries) do
    with {:ok, t, _role} <- Reply.tournament(conn, id, :hall) do
      case Manubrium.enrollment_for(conn.assigns.device, t.id) do
        {:ok, enrollment} ->
          entries = Enum.map(entries, &put_enrollment(&1, enrollment.id))

          case Sync.submit(enrollment.id, entries) do
            {:ok, answers} ->
              json(conn, %{results: Enum.map(answers, &MobileAppController.wire/1)})

            {:error, :too_many} ->
              Reply.error(
                conn,
                413,
                "too_many",
                gettext("At most %{max} entries per request.", max: Sync.max_batch())
              )
          end

        {:error, reason} ->
          Reply.refuse(conn, reason)
      end
    else
      {:halt, conn} -> conn
    end
  end

  def sync(conn, _params),
    do: Reply.error(conn, 400, "bad_request", gettext("A list of entries is needed."))

  defp put_enrollment(%{} = entry, enrollment_id), do: Map.put(entry, "enrollment", enrollment_id)
  defp put_enrollment(entry, _enrollment_id), do: entry

  @doc """
  POST /tournaments/:id/rounds/:number/boards/:pairing_id/clear -
  `{expected}`: clears a result, online only, compare-and-set.
  """
  def clear(conn, %{"id" => id, "number" => number, "pairing_id" => pairing_id} = params) do
    with {:ok, t, _role} <- Reply.tournament(conn, id, :hall),
         {:ok, n} <- round_number(conn, number),
         {:ok, pid} <- id_param(conn, pairing_id),
         {:ok, enrollment} <- enrollment(conn, t) do
      case Manubrium.clear_result(enrollment, pid, n, params["expected"]) do
        {:ok, _pairing} ->
          json(conn, %{status: "cleared"})

        {:conflict, current} ->
          conn
          |> put_status(409)
          |> json(%{
            error: "conflict",
            current: current,
            message:
              gettext("Not cleared: the board now says %{current}, entered elsewhere.",
                current: if(current == "", do: gettext("no result"), else: current)
              )
          })

        {:error, :board_gone} ->
          Reply.error(conn, 404, "board_gone", gettext("That board no longer exists."))

        {:error, reason} ->
          Reply.refuse(conn, reason)
      end
    else
      {:halt, conn} -> conn
    end
  end

  ## ---------- the desk: pairing, unpairing, publishing ----------

  @doc """
  POST /tournaments/:id/rounds - `{acknowledged: [warning ids]}`: pairs the
  next round, as the desk's "Pair round N" does when it has nothing to ask.
  """
  def pair(conn, %{"id" => id} = params) do
    with {:ok, t, _role} <- Reply.tournament(conn, id, :desk) do
      case DeskActions.pair_next_round(t, conn.assigns.current_scope, acknowledged(params)) do
        {:ok, round} ->
          round = Tournaments.get_round(t.id, round.number)

          conn
          |> put_status(201)
          |> json(%{round: Json.round(Tournaments.get_tournament!(t.id), round)})

        {:error, reason} ->
          Reply.refuse(conn, reason)
      end
    else
      {:halt, conn} -> conn
    end
  end

  @doc "DELETE /tournaments/:id/rounds/:number - unpairs the latest round."
  def unpair(conn, %{"id" => id, "number" => number}) do
    with {:ok, t, _role} <- Reply.tournament(conn, id, :desk),
         {:ok, n} <- round_number(conn, number) do
      case DeskActions.delete_round(t, conn.assigns.current_scope, n) do
        :ok -> send_resp(conn, 204, "")
        {:error, reason} -> Reply.refuse(conn, reason)
      end
    else
      {:halt, conn} -> conn
    end
  end

  @doc """
  PUT /tournaments/:id/rounds/:number/publish - `{level: 0..3}`: nothing,
  pairings, pairings and results, or those and the standings after it.
  """
  def publish(conn, %{"id" => id, "number" => number} = params) do
    with {:ok, t, _role} <- Reply.tournament(conn, id, :desk),
         {:ok, n} <- round_number(conn, number),
         {:ok, level} <- level(conn, params["level"]) do
      case DeskActions.set_publish_level(t, conn.assigns.current_scope, n, level) do
        {:ok, t} ->
          json(conn, %{
            round: n,
            publish_level:
              Tournaments.round_publish_state(t, Tournaments.get_round(t.id, n)).level
          })

        {:error, reason} when reason in [:round_not_complete, :earlier_round_not_complete] ->
          Reply.error(
            conn,
            409,
            Atom.to_string(reason),
            gettext(
              "Standings are published only after a round, and every round before it, is complete."
            )
          )

        {:error, reason} ->
          Reply.refuse(conn, reason)
      end
    else
      {:halt, conn} -> conn
    end
  end

  ## ---------- helpers ----------

  # Only the ids the write path knows, so a crafted value cannot mint an
  # atom - the desk's own rule for its button's value.
  defp acknowledged(%{"acknowledged" => ids}) when is_list(ids) do
    known = Map.new(PostponedGames.acknowledgement_ids(), &{Atom.to_string(&1), &1})
    for id <- ids, is_binary(id), ack = Map.get(known, id), do: ack
  end

  defp acknowledged(_params), do: []

  defp enrollment(conn, t) do
    case Manubrium.enrollment_for(conn.assigns.device, t.id) do
      {:ok, enrollment} -> {:ok, enrollment}
      {:error, reason} -> {:halt, Reply.refuse(conn, reason)}
    end
  end

  defp fetch_round(conn, t, n) do
    case Tournaments.get_round(t.id, n) do
      nil -> {:halt, Reply.refuse(conn, :not_paired)}
      round -> {:ok, round}
    end
  end

  defp round_number(conn, value), do: id_param(conn, value)

  defp id_param(conn, value) do
    case Reply.to_id(value) do
      {:ok, n} -> {:ok, n}
      :error -> {:halt, Reply.error(conn, 400, "bad_request", gettext("Not a number."))}
    end
  end

  defp level(_conn, level) when level in 0..3, do: {:ok, level}

  defp level(conn, _level),
    do: {:halt, Reply.error(conn, 400, "bad_request", gettext("The level is 0, 1, 2 or 3."))}
end
