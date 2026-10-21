defmodule PairingsEngine.Mobile.Sync do
  @moduledoc """
  The server half of Manubrium's offline queue (docs/manubrium.md): judges
  the entries a phone made - results and incidents, possibly while the hall
  wifi was down - in the order it made them, and says, per entry, what
  became of it.

  The phone only ever asks. Every entry is held to the same rules a tap
  with the network up is held to (`PairingsEngine.Mobile.permit_round/3`,
  `Mobile.board_in_range?/2`, `Mobile.permit_result/4`,
  `PairingsEngine.Tournaments.update_pairing_result/3`,
  `PairingsEngine.Incidents.permit_kind/2`), checked when it ARRIVES, not
  when it was tapped. Plus the one rule only a delay makes necessary:

    * **compare-and-set** - a result is written only while the board still
      holds what the phone believed it held when the result was tapped
      (`"expected"`). A desk entry, another phone, a re-pairing in the
      meantime: the entry is refused and says so, with both values. A queue
      that wins by arriving last is how a result entered at the desk gets
      overwritten by a phone that was in a basement.

  Each entry gets one of three answers:

    * `:saved` - written, or the board already held exactly this result;
    * `:refused` - final; the reason travels back and is shown per board;
    * `:retry` - not an answer (rate limited); the phone keeps it waiting.

  Final answers are stored in `PairingsEngine.Mobile.Submission` under the
  phone's id for the entry, so a resend after a lost reply gets the same
  answer back and writes nothing.
  """
  import Ecto.Query

  alias PairingsEngine.{Incidents, Mobile, RateLimit, Repo, Results, Tournaments}
  alias PairingsEngine.Mobile.{Enrollment, Submission}
  alias PairingsEngine.Pairing, as: Engine
  alias PairingsEngine.Tournaments.{Pairing, Round}

  # Per request. The phone sends its queue in slices of this size, one
  # slice at a time, so the order survives and no single request does an
  # unbounded amount of work.
  @max_batch 25

  # Result codes a queued entry may carry: everything an arbiter may write,
  # except the blank. Clearing a result is never queued - see the doc.
  @codes Results.entry_codes() -- [""]

  @doc "The most entries one request may carry."
  def max_batch, do: @max_batch

  @typedoc "One entry's answer."
  @type answer :: %{
          cid: String.t() | nil,
          status: :saved | :refused | :retry,
          reason: atom(),
          board: integer() | nil,
          kind: String.t() | nil,
          current: String.t() | nil
        }

  @doc """
  Judges `entries` (string-keyed maps, as decoded from the phone's JSON) for
  the enrolment with id `enrollment_id` - the one in the phone's session,
  never one an entry names. Returns `{:ok, answers}` in the same order, or
  `{:error, :too_many}` for a batch over `max_batch/0`.

  An enrolment that is not active any more (revoked, expired) refuses every
  entry with `:revoked`, and nothing is stored: the phone shows each one,
  per board, so whoever holds it can read them out to the arbiter.
  """
  @spec submit(integer() | nil, list()) :: {:ok, [answer()]} | {:error, :too_many}
  def submit(_enrollment_id, entries) when is_list(entries) and length(entries) > @max_batch,
    do: {:error, :too_many}

  def submit(enrollment_id, entries) when is_list(entries) do
    case enrollment_id && Mobile.get_active(enrollment_id) do
      %Enrollment{} = enrollment ->
        {:ok, Enum.map(entries, &judge(enrollment, &1))}

      _ ->
        {:ok, Enum.map(entries, &answer(&1, :refused, :revoked))}
    end
  end

  defp judge(enrollment, entry) do
    with {:ok, parsed} <- parse(entry),
         :ok <- same_enrollment(enrollment, parsed) do
      case Repo.get_by(Submission, enrollment_id: enrollment.id, client_id: parsed.cid) do
        %Submission{} = stored ->
          %{
            answer(parsed, String.to_existing_atom(stored.status), reason_atom(stored.reason))
            | board: stored.board || parsed.board
          }

        nil ->
          judge_new(enrollment, parsed)
      end
    else
      {:refused, reason} -> answer(entry, :refused, reason)
    end
  end

  defp judge_new(enrollment, parsed) do
    key = Integer.to_string(enrollment.id)

    if RateLimit.allow?(:mobile_sync, key) do
      RateLimit.record(:mobile_sync, key)
      {status, reason, current} = decide(enrollment, parsed)

      # `:retry` is "ask again", not an answer, and is never kept.
      if status != :retry, do: store(enrollment, parsed, status, reason)

      %{answer(parsed, status, reason) | current: current}
    else
      answer(parsed, :retry, :rate_limited)
    end
  end

  # ---- results ----

  defp decide(enrollment, %{kind: "result"} = e) do
    latest = Engine.paired_rounds_count(enrollment.tournament_id)

    with {:ok, pairing} <- fetch_pairing(enrollment, e),
         :ok <- Mobile.permit_round(enrollment, e.round, latest),
         :ok <- in_range(enrollment, pairing),
         :ok <- same_seats(pairing, e),
         :write <- unchanged(pairing, e),
         :ok <- Mobile.permit_result(enrollment, pairing, e.round, latest),
         :ok <- expected(pairing, e),
         {:ok, _} <- Tournaments.update_pairing_result(pairing, e.result) do
      Mobile.log_result(enrollment, pairing, e.round, pairing.result, e.result, %{
        queued: true,
        client_id: e.cid
      })

      {:saved, :saved, nil}
    else
      :unchanged ->
        {:saved, :unchanged, nil}

      {:conflict, current} ->
        Mobile.announce_conflict(enrollment, e.pairing, e.board, e.result, current)
        {:refused, :conflict, current}

      {:error, reason} ->
        {:refused, write_reason(reason), nil}
    end
  end

  # ---- incidents ----

  defp decide(enrollment, %{kind: "incident"} = e) do
    latest = Engine.paired_rounds_count(enrollment.tournament_id)

    with {:ok, pairing} <- fetch_pairing(enrollment, e),
         :ok <- Mobile.permit_round(enrollment, e.round, latest),
         :ok <- in_range(enrollment, pairing),
         {:ok, _incident} <-
           Incidents.log_from_phone(enrollment, pairing, e.round, %{
             kind: e.type,
             note: e.note,
             occurred_at: e.at,
             client_id: e.cid,
             photo: e.photo
           }) do
      {:saved, :saved, nil}
    else
      {:error, :rate_limited} -> {:retry, :rate_limited, nil}
      {:error, reason} -> {:refused, reason, nil}
    end
  end

  # The board as stored, and only if it belongs to this enrolment's
  # tournament AND to the round the entry names. A round deleted and paired
  # again has new pairing ids, so an entry for the old one lands here as
  # gone, which is the truth: the board it was about no longer exists.
  defp fetch_pairing(enrollment, e) do
    query =
      from p in Pairing,
        join: r in Round,
        on: r.id == p.round_id,
        where:
          p.id == ^e.pairing and r.tournament_id == ^enrollment.tournament_id and
            r.number == ^e.round and not is_nil(p.black_player_id),
        preload: [:white_player, :black_player]

    case Repo.one(query) do
      nil -> {:error, :board_gone}
      pairing -> {:ok, pairing}
    end
  end

  defp in_range(enrollment, pairing) do
    if Mobile.board_in_range?(enrollment, pairing.board),
      do: :ok,
      else: {:error, :board_out_of_range}
  end

  # The seats are what a result is about. Checked before "unchanged" so a
  # board that was re-seated and happens to carry the same result still
  # says it was re-seated.
  defp same_seats(pairing, e) do
    if pairing.white_player_id == e.white and pairing.black_player_id == e.black,
      do: :ok,
      else: {:error, :board_changed}
  end

  # Already exactly this result - from the desk, another phone, or this
  # entry's own first send whose reply never arrived. Nothing to write and
  # nothing to refuse.
  defp unchanged(%Pairing{result: result}, %{result: result}), do: :unchanged
  defp unchanged(_pairing, _e), do: :write

  defp expected(%Pairing{result: stored}, %{expected: expected}) do
    if blank(stored) == blank(expected), do: :ok, else: {:conflict, stored}
  end

  defp blank(nil), do: ""
  defp blank(v), do: v

  defp write_reason({:needs_acknowledgement, ids}) do
    cond do
      :adjourned_non_draw_result in ids -> :postponed_decisive
      :result_correction in ids -> :correction_after_pairing
      true -> :sent_in_trf
    end
  end

  defp write_reason(reason)
       when reason in [
              :earlier_round,
              :board_out_of_range,
              :already_set,
              :board_changed,
              :board_gone,
              :archived,
              :handed_off,
              :round_closed_in_fide_mode,
              :match_score_set,
              :match_decided,
              :postponed_games_off
            ],
       do: reason

  defp write_reason(_other), do: :not_saved

  # ---- parsing ----

  @cid ~r/\A[A-Za-z0-9-]{8,64}\z/

  # An entry with no board at all - the app's round-level "Log an incident"
  # sent these before it asked which board - is refused by that name, so the
  # phone can say what is missing instead of "Board ?: not saved". Every
  # incident row has a board; there is nowhere to put one without.
  defp parse(%{"cid" => cid, "kind" => kind} = entry)
       when is_binary(cid) and kind in ["result", "incident"] do
    with true <- Regex.match?(@cid, cid),
         :ok <- has_board(entry),
         {:ok, base} <- parse_base(entry, cid, kind),
         {:ok, parsed} <- parse_kind(kind, entry, base) do
      {:ok, parsed}
    else
      {:refused, :no_board} -> {:refused, :no_board}
      _ -> {:refused, :invalid}
    end
  end

  defp parse(_entry), do: {:refused, :invalid}

  defp has_board(%{"pairing" => pairing}) when pairing not in [nil, ""], do: :ok
  defp has_board(_entry), do: {:refused, :no_board}

  defp parse_base(entry, cid, kind) do
    with {:ok, enrollment} <- int(entry["enrollment"]),
         {:ok, round} <- int(entry["round"]),
         {:ok, pairing} <- int(entry["pairing"]) do
      {:ok,
       %{
         cid: cid,
         kind: kind,
         enrollment: enrollment,
         round: round,
         pairing: pairing,
         board: optional_int(entry["board"])
       }}
    end
  end

  defp parse_kind("result", entry, base) do
    result = entry["result"]
    expected = entry["expected"] || ""

    if result in @codes and is_binary(expected) do
      {:ok,
       Map.merge(base, %{
         result: result,
         expected: expected,
         white: optional_int(entry["white"]),
         black: optional_int(entry["black"])
       })}
    else
      :error
    end
  end

  defp parse_kind("incident", entry, base) do
    type = entry["type"]
    note = entry["note"] || ""

    with true <- is_binary(type) and is_binary(note),
         {:ok, photo} <- photo(entry["photo"]) do
      {:ok, Map.merge(base, %{type: type, note: note, at: datetime(entry["at"]), photo: photo})}
    else
      _ -> :error
    end
  end

  # The phone sends a photo as base64 inside the entry, so it waits in the
  # same queue as everything else. Size and kind are `Incidents`' to judge
  # once it is bytes; this only refuses what is not base64 at all, or so
  # long that decoding it would be the waste.
  @photo_b64_max div(PairingsEngine.Incidents.photo_max() * 4, 3) + 4

  defp photo(nil), do: {:ok, nil}
  defp photo(""), do: {:ok, nil}

  defp photo(b64) when is_binary(b64) and byte_size(b64) <= @photo_b64_max,
    do: Base.decode64(b64)

  defp photo(b64) when is_binary(b64), do: {:ok, :too_large}
  defp photo(_other), do: :error

  defp int(v) when is_integer(v) and v > 0, do: {:ok, v}

  defp int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> :error
    end
  end

  defp int(_), do: :error

  defp optional_int(v) do
    case int(v) do
      {:ok, n} -> n
      :error -> nil
    end
  end

  defp datetime(v) when is_binary(v) do
    case DateTime.from_iso8601(v) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp datetime(_), do: nil

  # An entry made under one enrolment is never sent under another. A phone
  # that was re-enrolled gets the old code's leftovers back refused - shown,
  # so they can be re-entered knowingly - rather than quietly attributed to
  # a code that never tapped them.
  defp same_enrollment(%Enrollment{id: id}, %{enrollment: id}), do: :ok
  defp same_enrollment(_enrollment, _parsed), do: {:refused, :other_code}

  # ---- answers ----

  defp store(enrollment, parsed, status, reason) do
    Repo.insert(
      %Submission{
        enrollment_id: enrollment.id,
        client_id: parsed.cid,
        kind: parsed.kind,
        status: Atom.to_string(status),
        reason: Atom.to_string(reason),
        board: parsed.board
      },
      on_conflict: :nothing,
      conflict_target: [:enrollment_id, :client_id]
    )
  end

  # Stored reasons were written from atoms this module defines, so turning
  # them back is safe; anything else (a row from a future version, say)
  # reads as the generic refusal rather than raising.
  defp reason_atom(reason) do
    String.to_existing_atom(reason)
  rescue
    ArgumentError -> :not_saved
  end

  defp answer(entry, status, reason) do
    %{
      cid: field(entry, :cid),
      status: status,
      reason: reason,
      board: entry |> field(:board) |> optional_int(),
      kind: field(entry, :kind),
      current: nil
    }
  end

  # Answers are built from parsed entries and from raw ones that did not
  # parse; the cid is echoed back either way so the phone can match it up.
  defp field(%{} = entry, key) when is_map_key(entry, key), do: Map.get(entry, key)
  defp field(%{} = entry, key), do: Map.get(entry, Atom.to_string(key))
  defp field(_not_a_map, _key), do: nil
end
