defmodule PairingsEngine.RegistrationWorkflowTest do
  @moduledoc """
  The registration workflow end to end on this side of the channel, as
  rebuilt on 2026-09-30: the form's settings travelling out in the snapshot,
  entries travelling back through the token-and-key-gated pull, the review
  (prefilled from the FIDE and KBSB lists, duplicates flagged) and the
  decision.

  `PairingsEngine.RegistrationsTest` covers the pull and the decisions in
  depth; this file covers what was added on top and the flow as a whole.
  """
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.{Publishing, Registrations, Repo, Snapshot, Tournaments}
  alias PairingsEngine.Fide.FidePlayer
  alias PairingsEngine.Federations.BEL.Member
  alias PairingsEngine.Registrations.Review
  alias PairingsEngine.Tournaments.{Player, Tournament}

  @email "lotte.janssens@example.invalid"

  setup do
    Publishing.put_endpoint("https://openresults.example/")
    Publishing.put_token("s3cret")
    :ok
  end

  defp tournament(attrs \\ %{}) do
    Repo.insert!(
      struct(
        %Tournament{
          name: "Brugse Open",
          type: "swiss",
          rounds_count: 5,
          publish_to_openresults: true,
          registration_open: true,
          standings_through: 0,
          public_slug: "brugge-#{System.unique_integer([:positive])}",
          openresults_key: "tournament-key-1"
        },
        attrs
      )
    )
  end

  defp entry(id, player) do
    %{
      "id" => id,
      "received_at" => "2026-09-30T09:12:00Z",
      "payload" => %{
        "schema" => "openresults/registration",
        "version" => 1,
        "tournament_slug" => "brugse-open",
        "player" => player
      }
    }
  end

  defp lotte(overrides \\ %{}) do
    Map.merge(
      %{"name" => "janssens lotte", "email" => @email, "rating" => 1900, "fide_id" => 210_999},
      overrides
    )
  end

  defp serve(entries) do
    Req.Test.stub(PairingsEngine.PublishingTest, fn conn ->
      Req.Test.json(conn, %{"registrations" => entries})
    end)
  end

  defp fide_lotte do
    Repo.insert!(%FidePlayer{
      fide_id: 210_999,
      name: "Janssens, Lotte",
      federation: "BEL",
      sex: "F",
      title: "WFM",
      birth_year: 2001,
      standard_rating: 1987,
      rapid_rating: 2010
    })
  end

  defp kbsb_lotte do
    Repo.insert!(%Member{
      national_id: "-4711",
      last_name: "Janssens",
      first_name: "Lotte",
      fide_id: 210_999,
      federation: "BEL",
      club_name: "KBSK Brugge",
      club_number: 301,
      national_rating: 1950,
      birth_year: 2001
    })
  end

  describe "the whole flow" do
    test "sign-up -> pull -> review -> accept: the player exists, prefilled, absent, no email" do
      fide_lotte()
      kbsb_lotte()
      t = tournament()
      serve([entry(1, lotte())])

      assert {:ok, %{new: 1}} = Registrations.pull(t)
      assert [registration] = Registrations.pending(t.id)

      # What the review screen shows is exactly what accepting creates.
      %{attrs: shown, notes: notes} = Review.proposal(registration, t, national_list: true)

      assert {:ok, player} = Registrations.accept(registration, national_list: true)

      # From the FIDE list: the list's spelling (the same person, typed in a
      # different order), its title and its rating for this tempo - the
      # typed 1900 was a claim, and the arbiter was told so.
      assert player.name == "Janssens, Lotte"
      assert player.title == "WFM"
      assert player.fide_rating == 1987
      assert player.sex == "w"
      assert {:rating_from_list, 1987, 1900} in notes

      # From the KBSB list, found through the FIDE ID the entry carried: the
      # G licence's minus sign intact.
      assert player.national_id == "-4711"
      assert player.national_rating == 1950
      assert player.club == "KBSK Brugge"
      assert player.club_number == 301

      assert shown["name"] == player.name and shown["fide_rating"] == player.fide_rating

      # A web form is an intention, not an arrival.
      assert player.absent

      # The email stops in the registration row.
      refute inspect(Map.from_struct(player)) =~ @email
      refute Tournament |> Repo.get!(t.id) |> Snapshot.build() |> Jason.encode!() =~ @email
    end

    test "without the Belgian lookup the national list is not consulted" do
      fide_lotte()
      kbsb_lotte()
      t = tournament()
      serve([entry(1, lotte())])
      {:ok, _} = Registrations.pull(t)
      [registration] = Registrations.pending(t.id)

      assert {:ok, player} = Registrations.accept(registration)
      assert player.national_id == ""
      assert player.fide_rating == 1987
    end

    test "a national ID alone finds the member, and through them the FIDE list" do
      fide_lotte()
      kbsb_lotte()
      t = tournament()

      serve([
        entry(1, %{"name" => "Lotte Janssens", "email" => @email, "national_id" => "-4711"})
      ])

      {:ok, _} = Registrations.pull(t)
      [registration] = Registrations.pending(t.id)

      assert {:ok, player} = Registrations.accept(registration, national_list: true)
      assert player.fide_id == 210_999
      assert player.fide_rating == 1987
      assert player.national_id == "-4711"
    end

    test "a FIDE ID the list gives another name is kept as typed, and said" do
      fide_lotte()
      t = tournament()
      serve([entry(1, lotte(%{"name" => "Peeters, Jan"}))])
      {:ok, _} = Registrations.pull(t)
      [registration] = Registrations.pending(t.id)

      %{attrs: attrs, notes: notes} = Review.proposal(registration, t)
      assert attrs["name"] == "Peeters, Jan"
      assert {:fide_name_differs, "Janssens, Lotte"} in notes
    end

    test "reject: nothing is created, and the next pull does not bring it back" do
      t = tournament()
      serve([entry(1, lotte())])
      {:ok, _} = Registrations.pull(t)
      [registration] = Registrations.pending(t.id)

      assert {:ok, _} = Registrations.discard(registration)
      assert Tournaments.count_players(t.id) == 0

      assert {:ok, %{new: 0}} = Registrations.pull(t)
      assert Registrations.pending(t.id) == []
    end
  end

  describe "duplicates" do
    test "same FIDE ID as a player already entered: flagged, and accepting is refused" do
      t = tournament()

      {:ok, _} =
        Tournaments.create_player(t.id, %{"name" => "Janssens, Lotte", "fide_id" => 210_999})

      serve([entry(1, lotte())])
      {:ok, _} = Registrations.pull(t)
      [registration] = Registrations.pending(t.id)

      assert [%{kind: :player, reason: :fide_id}] =
               Review.duplicates(registration, Tournaments.list_players(t.id), [registration])

      assert {:error, message} = Registrations.accept(registration)
      assert message =~ "already in this tournament"
      assert Tournaments.count_players(t.id) == 1
    end

    test "same name in another order, accents and case aside, is a probable duplicate" do
      t = tournament()
      {:ok, _} = Tournaments.create_player(t.id, %{"name" => "Désiré, Émile"})
      serve([entry(1, %{"name" => "emile desire", "email" => @email})])
      {:ok, _} = Registrations.pull(t)
      [registration] = Registrations.pending(t.id)

      assert [%{kind: :player, reason: :name, name: "Désiré, Émile"}] =
               Review.duplicates(registration, Tournaments.list_players(t.id), [registration])
    end

    test "the same person sending the form twice shows up on both entries" do
      t = tournament()

      serve([
        entry(1, %{"name" => "Janssens, Lotte", "email" => @email}),
        entry(2, %{"name" => "L. Janssens", "email" => String.upcase(@email)})
      ])

      {:ok, _} = Registrations.pull(t)
      [first, second] = Registrations.pending(t.id)
      pending = [first, second]

      assert [%{kind: :entry, id: id, reason: :email}] = Review.duplicates(first, [], pending)
      assert id == second.id
      assert [%{kind: :entry, reason: :email}] = Review.duplicates(second, [], pending)
    end

    test "strangers are not duplicates for lacking the same data" do
      t = tournament()

      serve([
        entry(1, %{"name" => "Janssens, Lotte", "email" => "a@example.invalid"}),
        entry(2, %{"name" => "Peeters, Jan", "email" => "b@example.invalid"})
      ])

      {:ok, _} = Registrations.pull(t)
      [first | _] = pending = Registrations.pending(t.id)

      assert Review.duplicates(first, [], pending) == []
    end
  end

  describe "the form's settings, out in the snapshot" do
    test "window, cap and list travel; taken counts players and entries waiting" do
      t = tournament()
      {:ok, _} = Tournaments.create_player(t.id, %{"name" => "Aerts, An"})
      serve([entry(1, lotte()), entry(2, %{"name" => "Peeters, Jan", "email" => @email})])
      {:ok, _} = Registrations.pull(t)

      assert {:ok, t} =
               Tournaments.set_registration_settings(t, %{
                 "registration_opens_at" => "2026-10-01T06:00:00.000Z",
                 "registration_closes_at" => "2026-10-20T20:00:00Z",
                 "registration_max_players" => "60",
                 "registration_list_public" => "true"
               })

      assert Snapshot.build(t)["tournament"]["registration"] == %{
               "opens_at" => "2026-10-01T06:00:00Z",
               "closes_at" => "2026-10-20T20:00:00Z",
               "max_players" => 60,
               "taken" => 3,
               "list_public" => true
             }

      # A decision frees a place, and the count follows.
      [pending | _] = Registrations.pending(t.id)
      {:ok, _} = Registrations.discard(pending)
      assert Snapshot.build(t)["tournament"]["registration"]["taken"] == 2
    end

    test "saving them enqueues a publish, like opening the form does" do
      t = tournament()

      assert {:ok, _} =
               Tournaments.set_registration_settings(t, %{"registration_max_players" => "40"})

      assert Repo.exists?(
               from q in PairingsEngine.Publishing.QueueEntry, where: q.tournament_id == ^t.id
             )
    end

    test "a window that closes before it opens is refused" do
      t = tournament()

      assert {:error, changeset} =
               Tournaments.set_registration_settings(t, %{
                 "registration_opens_at" => "2026-10-20T00:00:00Z",
                 "registration_closes_at" => "2026-10-01T00:00:00Z"
               })

      assert "must be after the opening time" in errors_on(changeset).registration_closes_at
    end

    test "a field of zero players is refused" do
      assert {:error, changeset} =
               Tournaments.set_registration_settings(tournament(), %{
                 "registration_max_players" => "0"
               })

      assert errors_on(changeset).registration_max_players != []
    end

    test "an archived tournament's settings cannot change" do
      t = tournament(%{archived_at: DateTime.utc_now() |> DateTime.truncate(:second)})

      assert {:error, :archived} =
               Tournaments.set_registration_settings(t, %{"registration_max_players" => "10"})
    end

    test "they do not open the form" do
      t = tournament(%{registration_open: false})
      {:ok, t} = Tournaments.set_registration_settings(t, %{"registration_max_players" => "10"})

      refute t.registration_open
      assert Snapshot.build(t)["tournament"]["registration_open"] == false
    end
  end

  describe "the channel" do
    test "the pull carries the ingest token and this tournament's key, nothing else" do
      t = tournament()
      test_pid = self()

      Req.Test.stub(PairingsEngine.PublishingTest, fn conn ->
        send(
          test_pid,
          {:headers, Plug.Conn.get_req_header(conn, "authorization"),
           Plug.Conn.get_req_header(conn, Publishing.key_header())}
        )

        Req.Test.json(conn, %{"registrations" => []})
      end)

      assert {:ok, _} = Registrations.pull(t)
      assert_receive {:headers, ["Bearer s3cret"], ["tournament-key-1"]}
    end

    test "a server that refuses the token yields no entries and says why" do
      t = tournament()

      Req.Test.stub(PairingsEngine.PublishingTest, fn conn ->
        Plug.Conn.send_resp(conn, 401, ~s({"error":"unauthorized"}))
      end)

      assert {:error, message} = Registrations.pull(t)
      assert message =~ "rejected the token"
      assert Registrations.pending(t.id) == []
    end
  end

  describe "screens follow the queue" do
    test "a pull that brings something in, and a decision, are broadcast" do
      t = tournament()
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(t.id))
      serve([entry(1, lotte())])

      {:ok, %{new: 1}} = Registrations.pull(t)
      assert_receive {:tournament_changed, _, :registrations}

      # Nothing new: nothing to tell anybody.
      {:ok, %{new: 0}} = Registrations.pull(t)
      refute_receive {:tournament_changed, _, :registrations}

      [registration] = Registrations.pending(t.id)
      {:ok, _} = Registrations.discard(registration)
      assert_receive {:tournament_changed, _, :registrations}
    end
  end

  test "Player has no column an email could land in" do
    refute :email in Player.__schema__(:fields)
  end
end
