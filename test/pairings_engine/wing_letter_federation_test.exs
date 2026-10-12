defmodule PairingsEngine.WingLetterFederationTest do
  @moduledoc """
  The Belgian player list's `Fed` column is the member's wing inside Belgium
  (V, F, D), not a country. It used to be copied into a player's
  `federation`, which is a FIDE country code. These tests hold the lookups,
  the registration review, the repair migration and the import to that.
  """
  use PairingsEngineWeb.ConnCase, async: false

  alias PairingsEngine.{
    Publishing,
    RateLimit,
    Repo,
    Snapshot,
    TournamentImport,
    Tournaments,
    TrfExport
  }

  alias PairingsEngine.Accounts.{Scope, User}
  alias PairingsEngine.Fide.FidePlayer
  alias PairingsEngine.Federations.BEL.{Member, Members}
  alias PairingsEngine.Registrations.{Registration, Review}
  alias PairingsEngine.Tournaments.{Pairing, Player, Round, Tournament}

  setup do
    RateLimit.clear(:fide_lookup, "127.0.0.1")
    Publishing.put_token("s3cret")
    :ok
  end

  defp member(attrs) do
    Repo.insert!(
      struct(
        %Member{
          national_id: "1001",
          last_name: "Wouters",
          first_name: "An",
          federation: "V",
          club_name: "Club"
        },
        attrs
      )
    )
  end

  defp fide(id, federation),
    do: Repo.insert!(%FidePlayer{fide_id: id, name: "Fide, Someone#{id}", federation: federation})

  defp search(conn, q) do
    conn
    |> put_req_header("authorization", "Bearer s3cret")
    |> get(~p"/internal/fide/search", q: q)
    |> json_response(200)
  end

  defp player(t, name, attrs),
    do: Repo.insert!(struct(%Player{tournament_id: t.id, name: name}, attrs))

  defp tournament(attrs \\ %{}),
    do: Repo.insert!(struct(%Tournament{name: "T", type: "swiss", rounds_count: 3}, attrs))

  describe "the lookup payload" do
    test "a member whose FIDE ID the FIDE list knows gets that list's federation", %{conn: conn} do
      member(%{fide_id: 777_001})
      fide(777_001, "NED")

      assert %{"players" => players} = search(conn, "Wouters")
      assert Enum.all?(players, &(&1["federation"] == "NED"))
      assert players != []
    end

    test "a member without a FIDE ID gets none, never the wing", %{conn: conn} do
      member(%{})

      assert %{"players" => [row]} = search(conn, "Wouters")
      assert row["federation"] == nil
      assert row["national_id"] == "1001"
    end

    test "a FIDE ID the FIDE list does not know (or no FIDE list at all) gets none",
         %{conn: conn} do
      member(%{fide_id: 777_002})

      assert %{"players" => [row]} = search(conn, "Wouters")
      assert row["federation"] == nil
    end
  end

  describe "the property: a Belgian lookup never yields a non-three-letter federation" do
    test "fide_federation/1" do
      fide(777_010, "BEL")
      fide(777_011, "V")
      fide(777_012, "")

      for {fide_id, expected} <- [
            {777_010, "BEL"},
            {777_011, nil},
            {777_012, nil},
            {999, nil},
            {nil, nil}
          ] do
        assert Members.fide_federation(%Member{fide_id: fide_id, federation: "V"}) == expected
      end
    end
  end

  describe "the registration review" do
    defp registration(player) do
      %Registration{payload: %{"player" => Map.merge(%{"name" => "wouters an"}, player)}}
    end

    test "matched to the Belgian list it takes the FIDE federation, not the wing" do
      member(%{fide_id: 777_020})
      fide(777_020, "NED")

      %{attrs: attrs} =
        Review.proposal(registration(%{"national_id" => "1001"}), %Tournament{rounds_count: 3},
          national_list: true
        )

      assert attrs["federation"] == "NED"
    end

    test "and nothing when the FIDE list does not know the person" do
      member(%{})

      %{attrs: attrs} =
        Review.proposal(registration(%{"national_id" => "1001"}), %Tournament{rounds_count: 3},
          national_list: true
        )

      refute Map.has_key?(attrs, "federation")
    end

    test "a letter already stored in an entry the results site filled is dropped" do
      %{attrs: attrs} =
        Review.proposal(
          registration(%{"national_id" => "1001", "federation" => "V"}),
          %Tournament{rounds_count: 3}
        )

      refute Map.has_key?(attrs, "federation")
    end
  end

  describe "the repair migration" do
    setup do
      path =
        Path.expand(
          "../../priv/repo/migrations/20261012160000_repair_wing_letter_federations.exs",
          __DIR__
        )

      mod = PairingsEngine.Repo.Migrations.RepairWingLetterFederations
      unless Code.ensure_loaded?(mod), do: Code.require_file(path)
      {:ok, mod: mod}
    end

    test "repairs exactly what the wing wrote, and nothing else", %{mod: mod} do
      fide(777_030, "NED")
      t = tournament()

      known = player(t, "Known", %{federation: "V", national_id: "1", fide_id: 777_030})
      unknown = player(t, "Unknown", %{federation: " f ", national_id: "2", fide_id: 123})
      no_fide = player(t, "NoFide", %{federation: "D", national_id: "3"})
      bel = player(t, "Bel", %{federation: "BEL", national_id: "4"})

      foreign =
        player(tournament(), "Foreign", %{federation: "V", national_id: "", fide_id: 777_030})

      {players_sql, _registrations_sql} = mod.statements()
      assert %{num_rows: 3} = Repo.query!(players_sql)

      fed = fn p -> Repo.get!(Player, p.id).federation end
      assert fed.(known) == "NED"
      assert fed.(unknown) in ["", nil]
      assert fed.(no_fide) in ["", nil]
      assert fed.(bel) == "BEL"
      assert fed.(foreign) == "V"

      # Idempotent.
      assert %{num_rows: 0} = Repo.query!(players_sql)
    end

    test "repairs a pending registration's stored payload with no FIDE list", %{mod: mod} do
      t = tournament()

      reg =
        Repo.insert!(%Registration{
          tournament_id: t.id,
          external_key: "k1",
          received_at: DateTime.utc_now(),
          payload: %{
            "player" => %{
              "name" => "x",
              "federation" => "V",
              "national_id" => "9",
              "fide_id" => 5
            }
          }
        })

      {_players_sql, registrations_sql} = mod.statements()
      assert %{num_rows: 1} = Repo.query!(registrations_sql)
      assert Repo.get!(Registration, reg.id).payload["player"]["federation"] == ""
    end
  end

  describe "import" do
    test "a backup with a wing letter on a Belgian player comes back repaired" do
      fide(777_040, "NED")

      user =
        Repo.insert!(%User{
          email: "u#{System.unique_integer([:positive])}@example.com",
          confirmed_at: DateTime.truncate(DateTime.utc_now(), :second)
        })

      source = tournament(%{user_id: user.id})

      player(source, "Old Backup", %{
        federation: "V",
        national_id: "77",
        fide_id: 777_040,
        pairing_number: 1
      })

      player(source, "Other", %{federation: "V", national_id: "", pairing_number: 2})

      data = PairingsEngine.TournamentExport.export_tournament(source)
      {:ok, imported} = TournamentImport.import(data, Scope.for_user(user))

      feds = imported |> Ecto.assoc(:players) |> Repo.all() |> Map.new(&{&1.name, &1.federation})

      assert feds["Old Backup"] == "NED"
      assert feds["Other"] == "V"
    end
  end

  describe "downstream, for a repaired player" do
    test "the results snapshot and the TRF carry the country" do
      t = tournament(%{rounds_count: 1, round_dates: ["2026-01-01"]})

      a =
        player(t, "Alice", %{
          federation: "NED",
          national_id: "5",
          fide_rating: 2000,
          pairing_number: 1
        })

      b = player(t, "Bob", %{federation: "BEL", fide_rating: 1900, pairing_number: 2})
      r = Repo.insert!(%Round{tournament_id: t.id, number: 1, status: "finished"})

      Repo.insert!(%Pairing{
        round_id: r.id,
        board: 1,
        white_player_id: a.id,
        black_player_id: b.id,
        result: "1-0"
      })

      {:ok, text} = TrfExport.export(t)
      alice_line = text |> String.split("\n") |> Enum.find(&String.contains?(&1, "Alice"))
      assert alice_line =~ "NED"

      {:ok, _} = Tournaments.publish_round_now(Tournaments.get_round(t.id, 1))
      snapshot = Snapshot.build(Tournaments.get_tournament!(t.id))
      assert Enum.any?(snapshot["players"], &(&1["federation"] == "NED"))
    end
  end
end
