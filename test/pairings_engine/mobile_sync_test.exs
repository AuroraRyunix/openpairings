defmodule PairingsEngine.MobileSyncTest do
  @moduledoc """
  Manubrium's queue, server side (`PairingsEngine.Mobile.Sync`,
  docs/manubrium.md): idempotent resends, the refusals a queued entry can
  meet, compare-and-set, incidents and who may log them, and a phone revoked
  while it was offline.
  """
  use PairingsEngine.DataCase, async: false

  import PairingsEngine.AccountsFixtures

  alias PairingsEngine.{Audit, Incidents, Mobile, RateLimit, Repo, Tournaments}
  alias PairingsEngine.Incidents.Incident
  alias PairingsEngine.Mobile.{Submission, Sync}
  alias PairingsEngine.Tournaments.{Pairing, Round}

  # Enrolment ids come back after a sandbox rollback, and the buckets are
  # keyed by them; a previous test's hits are not this test's.
  setup do
    RateLimit.clear_all()
    :ok
  end

  defp tournament(name \\ "Sync T") do
    {:ok, t} =
      Tournaments.create_tournament(user_scope_fixture(), %{"name" => name, "type" => "swiss"})

    t
  end

  defp player(t, name) do
    {:ok, p} = Tournaments.create_player(t.id, %{"name" => name, "fide_rating" => "1800"})
    p
  end

  # Round `number` with one board per `{white, black, result}`, numbered 1..
  defp round(t, number, boards) do
    round = Repo.insert!(%Round{tournament_id: t.id, number: number, status: "paired"})

    boards
    |> Enum.with_index(1)
    |> Enum.map(fn {{w, b, result}, board} ->
      Repo.insert!(%Pairing{
        round_id: round.id,
        board: board,
        white_player_id: w.id,
        black_player_id: b.id,
        result: result
      })
    end)
  end

  defp setup_board(level \\ "helper", opts \\ []) do
    t = tournament()
    {a, b, c, d} = {player(t, "Ann"), player(t, "Bob"), player(t, "Cas"), player(t, "Dee")}
    [p1, p2] = round(t, 1, [{a, b, ""}, {c, d, ""}])
    {:ok, e} = Mobile.create_enrollment(t.id, Keyword.merge([level: level], opts))
    %{t: t, e: e, p1: p1, p2: p2, players: {a, b, c, d}}
  end

  defp cid, do: Ecto.UUID.generate()

  defp result_entry(e, p, result, extra \\ %{}) do
    Map.merge(
      %{
        "cid" => cid(),
        "enrollment" => e.id,
        "kind" => "result",
        "round" => 1,
        "pairing" => p.id,
        "board" => p.board,
        "white" => p.white_player_id,
        "black" => p.black_player_id,
        "result" => result,
        "expected" => ""
      },
      extra
    )
  end

  defp incident_entry(e, p, type, extra \\ %{}) do
    Map.merge(
      %{
        "cid" => cid(),
        "enrollment" => e.id,
        "kind" => "incident",
        "round" => 1,
        "pairing" => p.id,
        "board" => p.board,
        "type" => type,
        "note" => "flag fell",
        "at" => DateTime.utc_now() |> DateTime.to_iso8601()
      },
      extra
    )
  end

  defp stored(p), do: Repo.get!(Pairing, p.id).result

  defp one(e, entry) do
    {:ok, [answer]} = Sync.submit(e.id, [entry])
    answer
  end

  describe "results" do
    test "a queued result is written, audited and answered saved" do
      %{e: e, p1: p1, t: t} = setup_board()

      assert %{status: :saved, reason: :saved, board: 1} = one(e, result_entry(e, p1, "1-0"))
      assert stored(p1) == "1-0"

      [log] = Audit.list_for_tournament(t.id)
      assert log.details["via"] == "mobile"
      assert log.details["queued"] == true
    end

    test "a resend of the same entry gets the same answer and writes nothing" do
      %{e: e, p1: p1, t: t} = setup_board("deputy")
      entry = result_entry(e, p1, "1-0")

      assert %{status: :saved} = one(e, entry)

      # The desk changes the board after the phone's first send landed but
      # before its reply did. The resend must not put 1-0 back.
      {:ok, _} = Tournaments.update_pairing_result(Repo.get!(Pairing, p1.id), "0-1")

      assert %{status: :saved, reason: :saved} = one(e, entry)
      assert stored(p1) == "0-1"
      assert Repo.aggregate(Submission, :count) == 1

      entered = Audit.list_for_tournament(t.id) |> Enum.filter(&(&1.details["queued"] == true))
      assert length(entered) == 1
    end

    test "a refusal is kept too, and a resend is refused the same way" do
      %{e: e, p1: p1} = setup_board()
      {:ok, _} = Tournaments.update_pairing_result(p1, "0-1")
      entry = result_entry(e, p1, "1-0")

      assert %{status: :refused, reason: :already_set} = one(e, entry)
      assert %{status: :refused, reason: :already_set} = one(e, entry)
      assert stored(p1) == "0-1"
    end

    test "the board already holding exactly this result is not a refusal" do
      %{e: e, p1: p1} = setup_board()
      {:ok, _} = Tournaments.update_pairing_result(p1, "1-0")

      assert %{status: :saved, reason: :unchanged} = one(e, result_entry(e, p1, "1-0"))
    end

    test "a deputy's queued correction does not overwrite a board changed meanwhile" do
      %{e: e, p1: p1} = setup_board("deputy")
      {:ok, _} = Tournaments.update_pairing_result(p1, "0-1")

      # The phone saw the board blank when it tapped.
      answer = one(e, result_entry(e, p1, "1-0", %{"expected" => ""}))
      assert %{status: :refused, reason: :conflict, current: "0-1"} = answer
      assert stored(p1) == "0-1"

      # Made against what is there now, the same correction goes through.
      assert %{status: :saved} = one(e, result_entry(e, p1, "1-0", %{"expected" => "0-1"}))
      assert stored(p1) == "1-0"
    end

    test "entries are judged in the order they were made" do
      %{e: e, p1: p1} = setup_board("deputy")

      first = result_entry(e, p1, "1-0")
      second = result_entry(e, p1, "1/2-1/2", %{"expected" => "1-0"})

      assert {:ok, [%{status: :saved}, %{status: :saved}]} = Sync.submit(e.id, [first, second])
      assert stored(p1) == "1/2-1/2"
    end

    test "a helper's entry for a round that is no longer current is refused" do
      %{e: e, p1: p1, t: t, players: {a, b, _, _}} = setup_board()
      round(t, 2, [{b, a, ""}])

      assert %{status: :refused, reason: :earlier_round} = one(e, result_entry(e, p1, "1-0"))
      assert stored(p1) == ""
    end

    test "outside the board range is refused" do
      %{e: e, p2: p2} = setup_board("helper", board_from: 1, board_to: 1)

      assert %{status: :refused, reason: :board_out_of_range} = one(e, result_entry(e, p2, "1-0"))
      assert stored(p2) == ""
    end

    test "a board whose players changed since the phone drew it is refused" do
      %{e: e, p1: p1, players: {_, _, c, _}} = setup_board()

      entry = result_entry(e, p1, "1-0", %{"white" => c.id})
      assert %{status: :refused, reason: :board_changed} = one(e, entry)
      assert stored(p1) == ""
    end

    test "a pairing of another tournament, or another round, is a board that is gone" do
      %{e: e, p1: p1} = setup_board()
      other = setup_board()

      assert %{status: :refused, reason: :board_gone} = one(e, result_entry(e, other.p1, "1-0"))

      assert %{status: :refused, reason: :board_gone} =
               one(e, result_entry(e, p1, "1-0", %{"round" => 2}))

      assert stored(other.p1) == ""
    end

    test "an archived tournament refuses with its reason" do
      %{e: e, p1: p1, t: t} = setup_board()

      t
      |> Ecto.Changeset.change(archived_at: DateTime.utc_now() |> DateTime.truncate(:second))
      |> Repo.update!()

      assert %{status: :refused, reason: :archived} = one(e, result_entry(e, p1, "1-0"))
    end

    test "a clear is never queued, and junk is refused without being stored" do
      %{e: e, p1: p1} = setup_board("deputy")

      assert %{status: :refused, reason: :invalid} = one(e, result_entry(e, p1, ""))
      assert %{status: :refused, reason: :invalid} = one(e, result_entry(e, p1, "2-0"))
      assert %{status: :refused, reason: :invalid} = one(e, %{"cid" => "x", "kind" => "result"})
      assert {:ok, [%{status: :refused, reason: :invalid, cid: nil}]} = Sync.submit(e.id, ["no"])
      assert Repo.aggregate(Submission, :count) == 0
    end

    test "more than a batch in one request is refused whole" do
      %{e: e, p1: p1} = setup_board()
      entries = for _ <- 1..(Sync.max_batch() + 1), do: result_entry(e, p1, "1-0")

      assert {:error, :too_many} = Sync.submit(e.id, entries)
      assert stored(p1) == ""
    end

    test "past the rate limit an entry is told to retry, and nothing is kept" do
      %{e: e, p1: p1} = setup_board()
      key = Integer.to_string(e.id)
      for _ <- 1..600, do: RateLimit.record(:mobile_sync, key)

      assert %{status: :retry, reason: :rate_limited} = one(e, result_entry(e, p1, "1-0"))
      assert stored(p1) == ""
      assert Repo.aggregate(Submission, :count) == 0
    end
  end

  describe "a phone revoked or re-enrolled while it was offline" do
    test "every queued entry comes back refused, per board, and nothing is written" do
      %{e: e, p1: p1, p2: p2} = setup_board()

      queued = [
        result_entry(e, p1, "1-0"),
        result_entry(e, p2, "0-1"),
        incident_entry(e, p1, "arbiter_call")
      ]

      {:ok, _} = Mobile.revoke(e)

      assert {:ok, answers} = Sync.submit(e.id, queued)

      assert Enum.map(answers, &{&1.status, &1.reason, &1.board}) ==
               [{:refused, :revoked, 1}, {:refused, :revoked, 2}, {:refused, :revoked, 1}]

      assert stored(p1) == "" and stored(p2) == ""
      assert Repo.aggregate(Incident, :count) == 0
      assert Repo.aggregate(Submission, :count) == 0
    end

    test "no enrolment in the session at all is the same refusal" do
      %{e: e, p1: p1} = setup_board()

      assert {:ok, [%{status: :refused, reason: :revoked}]} =
               Sync.submit(nil, [result_entry(e, p1, "1-0")])
    end

    test "an entry made under an earlier code is not sent under the new one" do
      %{e: old, p1: p1, t: t} = setup_board()
      {:ok, new} = Mobile.create_enrollment(t.id, level: "helper")

      assert {:ok, [%{status: :refused, reason: :other_code}]} =
               Sync.submit(new.id, [result_entry(old, p1, "1-0")])

      assert stored(p1) == ""
    end
  end

  describe "incidents" do
    test "a deputy logs any kind, with the board, players, note and phone time" do
      %{e: e, p1: p1, t: t} = setup_board("deputy", label: "Hall B")
      at = DateTime.utc_now() |> DateTime.add(-600, :second) |> DateTime.truncate(:second)

      entry = incident_entry(e, p1, "clock", %{"at" => DateTime.to_iso8601(at)})
      assert %{status: :saved, kind: "incident"} = one(e, entry)

      [i] = Incidents.list(t.id)
      assert {i.round_number, i.board, i.kind, i.note} == {1, 1, "clock", "flag fell"}
      assert {i.white_name, i.black_name, i.enrollment_label} == {"Ann", "Bob", "Hall B"}
      assert i.occurred_at == at
      assert i.source == "phone"
    end

    test "a helper may call the arbiter and nothing else" do
      %{e: e, p1: p1, t: t} = setup_board("helper")

      assert %{status: :saved} = one(e, incident_entry(e, p1, "arbiter_call"))

      assert %{status: :refused, reason: :kind_not_allowed} =
               one(e, incident_entry(e, p1, "clock"))

      assert %{status: :refused, reason: :unknown_kind} = one(e, incident_entry(e, p1, "fire"))
      assert [%{kind: "arbiter_call"}] = Incidents.list(t.id)
    end

    test "a helper cannot log on an earlier round, nor anyone outside their boards" do
      %{e: e, p1: p1, t: t, players: {a, b, _, _}} = setup_board()
      round(t, 2, [{b, a, ""}])

      assert %{status: :refused, reason: :earlier_round} =
               one(e, incident_entry(e, p1, "arbiter_call"))

      ranged = setup_board("deputy", board_from: 2)

      assert %{status: :refused, reason: :board_out_of_range} =
               one(ranged.e, incident_entry(ranged.e, ranged.p1, "clock"))

      assert Repo.aggregate(Incident, :count) == 0
    end

    test "a resend makes no second incident" do
      %{e: e, p1: p1, t: t} = setup_board("deputy")
      entry = incident_entry(e, p1, "dispute")

      assert %{status: :saved} = one(e, entry)
      assert %{status: :saved} = one(e, entry)
      assert length(Incidents.list(t.id)) == 1
    end

    test "the same incident logged twice at the database level is still one row" do
      %{e: e, p1: p1, t: t} = setup_board("deputy")
      pairing = Repo.get!(Pairing, p1.id) |> Repo.preload([:white_player, :black_player])
      attrs = %{kind: "other", note: "", occurred_at: nil, client_id: cid()}

      {:ok, first} = Incidents.log_from_phone(e, pairing, 1, attrs)
      {:ok, second} = Incidents.log_from_phone(e, pairing, 1, attrs)
      assert first.id == second.id
      assert length(Incidents.list(t.id)) == 1
    end

    test "a long note, the cap and the rate limit" do
      %{e: e, p1: p1, t: t} = setup_board("deputy")
      long = String.duplicate("x", Incidents.note_max() + 1)

      assert %{status: :refused, reason: :note_too_long} =
               one(e, incident_entry(e, p1, "other", %{"note" => long}))

      key = Integer.to_string(e.id)
      for _ <- 1..30, do: RateLimit.record(:mobile_incident, key)
      assert %{status: :retry, reason: :rate_limited} = one(e, incident_entry(e, p1, "other"))

      capped = setup_board("deputy")
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      rows =
        for n <- 1..300 do
          %{
            tournament_id: capped.t.id,
            round_number: 1,
            board: 1,
            kind: "other",
            note: "",
            white_name: "",
            black_name: "",
            occurred_at: now,
            source: "phone",
            enrollment_label: "",
            enrollment_id: capped.e.id,
            client_id: "seed-#{n}",
            inserted_at: now,
            updated_at: now
          }
        end

      Repo.insert_all(Incident, rows)

      assert %{status: :refused, reason: :incident_cap} =
               one(capped.e, incident_entry(capped.e, capped.p1, "other"))

      assert Incidents.list(t.id) == []
    end

    test "a phone clock a day out is not believed" do
      far = DateTime.utc_now() |> DateTime.add(-3 * 86_400, :second)
      near = DateTime.utc_now() |> DateTime.add(-3600, :second)

      assert DateTime.diff(DateTime.utc_now(), Incidents.plausible_time(far)) < 5
      assert Incidents.plausible_time(near) == DateTime.truncate(near, :second)
      assert DateTime.diff(DateTime.utc_now(), Incidents.plausible_time(nil)) < 5
    end

    test "a new incident is announced on the incidents topic" do
      %{e: e, p1: p1, t: t} = setup_board("deputy")
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Incidents.topic(t.id))

      one(e, incident_entry(e, p1, "device"))
      assert_receive {:incident_logged, tid, 1}
      assert tid == t.id
    end

    test "incidents outlive a re-pairing of their round" do
      %{e: e, p1: p1, t: t} = setup_board("deputy")
      one(e, incident_entry(e, p1, "illegal_move"))

      Repo.delete_all(from p in Pairing, where: p.id == ^p1.id)

      [i] = Incidents.list(t.id)
      assert i.pairing_id == nil
      assert {i.round_number, i.board, i.white_name} == {1, 1, "Ann"}
      assert Incidents.counts_by_round(t.id) == %{1 => 1}
    end
  end
end
