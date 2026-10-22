defmodule PairingsEngine.Incidents do
  @moduledoc """
  Incidents logged at a board from a phone (Manubrium, docs/manubrium.md):
  an illegal move, a clock problem, a phone going off, a complaint, time
  added, a game put back to an earlier position, a call for the arbiter, or
  something else - with a short note, the time, and at most one photo.

  Each one is also a line in the tournament's audit trail
  (`"incident.logged"`), under the account of the arbiter whose phone it
  came from, or "System" with the phone's code for a no-account one.

  Who may log what is decided here (`permit_kind/2`), on top of the round
  and board-range rules every phone write already goes through
  (`PairingsEngine.Mobile.permit_round/3`, `Mobile.board_in_range?/2`):

    * a `"deputy"` may log every kind;
    * a `"helper"` may log `"arbiter_call"` only. A helper at a board where
      something has gone wrong needs the arbiter standing there, not a form;
      writing down what happened is the arbiter's job.

  Logging is rationed per enrolment (`RateLimit`'s `:mobile_incident`, and a
  hard `@cap` per enrolment) for the same reason codes are: a credential
  with no account behind it should not be able to fill a table.

  New incidents are announced on `topic/1`, a topic of their own rather than
  the tournament's: every arbiter page follows the tournament topic, and a
  LiveView with no clause for a message it receives crashes (the lesson
  `PairingsEngineWeb.EnrollmentRevokedHook` exists to remember).
  """
  import Ecto.Query

  alias PairingsEngine.{Audit, RateLimit, Repo, Tournaments}
  alias PairingsEngine.Incidents.{Incident, Photo}
  alias PairingsEngine.Mobile.Enrollment
  alias PairingsEngine.Tournaments.Pairing

  @kinds ~w(illegal_move clock device complaint time_added game_rewound arbiter_call other)
  @helper_kinds ~w(arbiter_call)

  # A note is a line on a report, not a statement. Long enough for "flag
  # fell at move 38, both claimed", short enough that it cannot become one.
  @note_max 280

  # Per enrolment, for its whole life. A deputy at a busy event logs a
  # handful an hour; three hundred is not an event, it is a loop.
  @cap 300

  # How far the phone's clock may disagree with the server's before its
  # time is not believed. A queue held through a long outage can be hours
  # old; a phone whose clock is a day out is wrong, not delayed.
  @clock_past_s 24 * 3600
  @clock_future_s 5 * 60

  # A photo, after the phone shrank it to 1600 pixels on its longest side:
  # a few hundred kilobytes, usually. Two megabytes is room for a phone that
  # did not shrink it, and no room for anything else.
  @photo_max 2_000_000

  @doc "Every incident kind, in the order the phone offers them."
  def kinds, do: @kinds

  @doc "The kinds `level` may log."
  def kinds_for("deputy"), do: @kinds
  def kinds_for(_helper), do: @helper_kinds

  @doc "The longest note accepted."
  def note_max, do: @note_max

  @doc "The largest photo accepted, in bytes."
  def photo_max, do: @photo_max

  @doc """
  Whether `data` is a photo this module keeps: a JPEG by its first bytes
  (not by what the sender called it), no larger than `photo_max/0`.
  `:ok`, or `{:error, :photo_too_large | :not_a_photo}`.
  """
  def check_photo(:too_large), do: {:error, :photo_too_large}

  def check_photo(data) when is_binary(data) and byte_size(data) > @photo_max,
    do: {:error, :photo_too_large}

  def check_photo(<<0xFF, 0xD8, 0xFF, _rest::binary>>), do: :ok
  def check_photo(_data), do: {:error, :not_a_photo}

  @doc "The PubSub topic new incidents of `tournament_id` are announced on."
  def topic(tournament_id), do: "incidents:#{tournament_id}"

  @doc "Whether `enrollment`'s level may log an incident of `kind`."
  @spec permit_kind(Enrollment.t(), String.t()) ::
          :ok | {:error, :unknown_kind | :kind_not_allowed}
  def permit_kind(%Enrollment{}, kind) when kind not in @kinds, do: {:error, :unknown_kind}

  def permit_kind(%Enrollment{level: level}, kind) do
    if kind in kinds_for(level), do: :ok, else: {:error, :kind_not_allowed}
  end

  @doc """
  Logs an incident on `pairing` (round `round_number`) for `enrollment`.

  `attrs`: `:kind`, `:note`, `:occurred_at` (a `DateTime` or nil),
  `:client_id` (the phone's id for the entry) and `:photo` (JPEG bytes, or
  nil). The caller has already checked round and board range; this checks
  the kind, the note, the photo, the cap and the rate limit.

  Idempotent on `{enrollment, client_id}`: a second call with the same pair
  writes nothing and returns the incident the first one wrote.

  Returns `{:ok, incident}` or `{:error, reason}`, `reason` one of
  `:unknown_kind`, `:kind_not_allowed`, `:note_too_long`, `:photo_too_large`,
  `:not_a_photo`, `:incident_cap`, `:rate_limited`.
  """
  def log_from_phone(%Enrollment{} = enrollment, %Pairing{} = pairing, round_number, attrs) do
    kind = attrs[:kind]
    note = attrs |> Map.get(:note, "") |> to_string() |> String.trim()
    client_id = attrs[:client_id]
    key = Integer.to_string(enrollment.id)

    photo = attrs[:photo]

    with :ok <- permit_kind(enrollment, kind),
         :ok <- check_note(note),
         :ok <- if(is_nil(photo), do: :ok, else: check_photo(photo)) do
      case existing(enrollment.id, client_id) do
        %Incident{} = incident ->
          {:ok, incident}

        nil ->
          cond do
            count_for_enrollment(enrollment.id) >= @cap ->
              {:error, :incident_cap}

            not RateLimit.allow?(:mobile_incident, key) ->
              {:error, :rate_limited}

            true ->
              RateLimit.record(:mobile_incident, key)

              insert(enrollment, pairing, round_number, %{
                kind: kind,
                note: note,
                occurred_at: plausible_time(attrs[:occurred_at]),
                client_id: client_id,
                photo: photo
              })
          end
      end
    end
  end

  defp insert(enrollment, pairing, round_number, attrs) do
    incident = %Incident{
      tournament_id: enrollment.tournament_id,
      round_number: round_number,
      board: pairing.board,
      pairing_id: pairing.id,
      white_player_id: pairing.white_player_id,
      black_player_id: pairing.black_player_id,
      white_name: name(pairing.white_player),
      black_name: name(pairing.black_player),
      kind: attrs.kind,
      note: attrs.note,
      occurred_at: attrs.occurred_at,
      source: "phone",
      enrollment_id: enrollment.id,
      enrollment_label: enrollment.label || "",
      client_id: attrs.client_id,
      user_id: enrollment.user_id,
      has_photo: not is_nil(attrs.photo)
    }

    # Two sends of one entry at the same moment (a page and a second tab
    # flushing the same queue) both get here; the unique index lets one in
    # and the other reads back what it wrote.
    Repo.transaction(fn ->
      case Repo.insert(incident,
             on_conflict: :nothing,
             conflict_target: [:enrollment_id, :client_id]
           ) do
        {:ok, %Incident{id: nil}} ->
          {:existing, existing(enrollment.id, attrs.client_id)}

        {:ok, inserted} ->
          if attrs.photo, do: insert_photo!(inserted, attrs.photo)
          {:new, inserted}
      end
    end)
    |> case do
      {:ok, {:existing, found}} ->
        {:ok, found}

      {:ok, {:new, inserted}} ->
        audit(enrollment, inserted)

        Phoenix.PubSub.broadcast(
          PairingsEngine.PubSub,
          topic(enrollment.tournament_id),
          {:incident_logged, enrollment.tournament_id, round_number}
        )

        {:ok, inserted}
    end
  end

  defp insert_photo!(incident, data) do
    Repo.insert!(%Photo{
      tournament_id: incident.tournament_id,
      incident_id: incident.id,
      content_type: "image/jpeg",
      byte_size: byte_size(data),
      data: data
    })
  end

  # The audit row, in the shape the result rows have: the board, who sat
  # there, and which phone - an account's own phone under that account.
  defp audit(enrollment, incident) do
    Audit.log(incident.tournament_id, enrollment.user_id, "incident.logged", %{
      incident_id: incident.id,
      kind: incident.kind,
      round: incident.round_number,
      board: incident.board,
      white: incident.white_name,
      black: incident.black_name,
      note: incident.note,
      photo: incident.has_photo,
      via: "mobile",
      enrollment_id: enrollment.id,
      enrollment_code: enrollment.code,
      enrollment_label: enrollment.label,
      enrollment_level: enrollment.level
    })
  end

  @doc """
  Attaches `data` (JPEG bytes) to incident `incident_id` of `tournament_id`
  after the fact - a photo taken once the incident was already logged. The
  same checks a photo in a queued entry meets (`check_photo/1`), one photo
  per incident (`:photo_exists`), and an audit row under `scope`.
  `{:ok, incident}` or `{:error, :not_found | :photo_exists |
  :photo_too_large | :not_a_photo}`.
  """
  def attach_photo(tournament_id, incident_id, data, scope) do
    with %Incident{} = incident <-
           Repo.get_by(Incident, id: incident_id, tournament_id: tournament_id) ||
             {:error, :not_found},
         :ok <- if(incident.has_photo, do: {:error, :photo_exists}, else: :ok),
         :ok <- check_photo(data) do
      {:ok, updated} =
        Repo.transaction(fn ->
          insert_photo!(incident, data)
          Repo.update!(Ecto.Changeset.change(incident, has_photo: true))
        end)

      Audit.log(tournament_id, scope, "incident.photo_added", %{
        incident_id: incident.id,
        kind: incident.kind,
        round: incident.round_number,
        board: incident.board,
        via: "mobile"
      })

      # The desk's incidents page shows the camera mark as soon as it lands.
      Phoenix.PubSub.broadcast(
        PairingsEngine.PubSub,
        topic(tournament_id),
        {:incident_logged, tournament_id, incident.round_number}
      )

      {:ok, updated}
    end
  end

  @doc """
  Marks incident `incident_id` of `tournament_id` handled (`true`) or open
  again (`false`), with an audit row under `scope`. A handled incident stays
  on the list, unhighlighted; nothing about it is lost.

  `{:ok, incident}` or `{:error, :not_found | :archived | :handed_off}`.
  """
  def set_handled(tournament_id, incident_id, handled?, scope) do
    with :ok <- Tournaments.ensure_writable(tournament_id),
         %Incident{} = incident <- get(tournament_id, incident_id) || {:error, :not_found} do
      at = if handled?, do: DateTime.utc_now() |> DateTime.truncate(:second)
      updated = Repo.update!(Ecto.Changeset.change(incident, handled_at: at))

      # Two literal calls rather than one with a computed action: the
      # audit page's tests read the codes straight off the source.
      if handled?,
        do: Audit.log(tournament_id, scope, "incident.handled", summary(incident)),
        else: Audit.log(tournament_id, scope, "incident.reopened", summary(incident))

      announce(tournament_id, incident.round_number)
      {:ok, updated}
    end
  end

  @doc """
  Removes incident `incident_id` of `tournament_id`, and its photo with it,
  leaving an audit row under `scope` that still says what it was - the
  incident goes, the record of it having existed does not.

  `{:ok, incident}` or `{:error, :not_found | :archived | :handed_off}`.
  """
  def delete(tournament_id, incident_id, scope) do
    with :ok <- Tournaments.ensure_writable(tournament_id),
         %Incident{} = incident <- get(tournament_id, incident_id) || {:error, :not_found} do
      Repo.delete!(incident)

      Audit.log(
        tournament_id,
        scope,
        "incident.deleted",
        Map.merge(summary(incident), %{
          note: incident.note,
          white: incident.white_name,
          black: incident.black_name,
          photo: incident.has_photo
        })
      )

      announce(tournament_id, incident.round_number)
      {:ok, incident}
    end
  end

  defp get(tournament_id, incident_id) do
    case Integer.parse(to_string(incident_id)) do
      {id, ""} -> Repo.get_by(Incident, id: id, tournament_id: tournament_id)
      _ -> nil
    end
  end

  defp summary(incident),
    do: %{
      incident_id: incident.id,
      kind: incident.kind,
      round: incident.round_number,
      board: incident.board
    }

  # The same message a new incident sends, so every page that counts them
  # (the list, the Pairings page's line) recounts without a clause of its own.
  defp announce(tournament_id, round_number) do
    Phoenix.PubSub.broadcast(
      PairingsEngine.PubSub,
      topic(tournament_id),
      {:incident_logged, tournament_id, round_number}
    )
  end

  @doc """
  The photo of incident `incident_id` in `tournament_id`, or nil. The
  caller decides who may see it; this only makes sure the two ids belong
  together.
  """
  def get_photo(tournament_id, incident_id) do
    Repo.one(
      from p in Photo,
        where: p.tournament_id == ^tournament_id and p.incident_id == ^incident_id
    )
  end

  defp name(%PairingsEngine.Tournaments.Player{name: name}), do: name || ""
  defp name(_), do: ""

  defp existing(_enrollment_id, nil), do: nil

  defp existing(enrollment_id, client_id),
    do: Repo.get_by(Incident, enrollment_id: enrollment_id, client_id: client_id)

  defp check_note(note) do
    if String.length(note) > @note_max, do: {:error, :note_too_long}, else: :ok
  end

  defp count_for_enrollment(enrollment_id) do
    Repo.aggregate(from(i in Incident, where: i.enrollment_id == ^enrollment_id), :count)
  end

  @doc false
  # The phone's clock, if it is within reason; the server's otherwise.
  def plausible_time(%DateTime{} = at) do
    now = DateTime.utc_now()
    diff = DateTime.diff(at, now, :second)

    if diff >= -@clock_past_s and diff <= @clock_future_s,
      do: DateTime.truncate(at, :second),
      else: DateTime.truncate(now, :second)
  end

  def plausible_time(_), do: DateTime.utc_now() |> DateTime.truncate(:second)

  @doc """
  The incidents of `tournament_id`, newest first, with the players who sat
  at the board preloaded. `round_number: n` limits it to one round.
  """
  def list(tournament_id, opts \\ []) do
    query =
      from i in Incident,
        where: i.tournament_id == ^tournament_id,
        order_by: [desc: i.occurred_at, desc: i.id],
        preload: [:white_player, :black_player, :user]

    query =
      case Keyword.get(opts, :round_number) do
        nil -> query
        n -> where(query, [i], i.round_number == ^n)
      end

    Repo.all(query)
  end

  @doc "How many incidents each round of `tournament_id` has: `%{round_number => count}`."
  def counts_by_round(tournament_id) do
    from(i in Incident,
      where: i.tournament_id == ^tournament_id,
      group_by: i.round_number,
      select: {i.round_number, count(i.id)}
    )
    |> Repo.all()
    |> Map.new()
  end
end
