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

  Who may: `Reply.tournament/3` - `:hall` (owner, editor, arbiter) for the
  round and the queue, `:desk` (owner, editor:
  `Tournaments.get_authorized_tournament/2`, the desk pages' own gate) for
  everything else.
  """
  use PairingsEngineWeb, :controller

  alias PairingsEngine.{Incidents, Manubrium, PostponedGames, Tournaments}
  alias PairingsEngine.Mobile.Sync
  alias PairingsEngineWeb.{DeskActions, MobileAppController}
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
