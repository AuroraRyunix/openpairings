defmodule PairingsEngineWeb.PlayerFormWordsLiveTest do
  @moduledoc """
  The player dialog's status ticks (what each one says and which combinations
  it will not offer) and its one pairing-allocated bye control (how the answer
  lands in the five stored fields, and what becomes of a contradiction).
  """
  use PairingsEngineWeb.ConnCase

  import Ecto.Query
  import Phoenix.LiveViewTest
  import PairingsEngineWeb.FideGateHelpers

  alias PairingsEngine.{Repo, Tournaments}
  alias PairingsEngine.Tournaments.{ByeChoice, Player}

  setup [:register_and_log_in_user, :enable_federation_features]

  defp tournament(scope, attrs \\ %{}) do
    {:ok, t} =
      Tournaments.create_tournament(
        scope,
        Map.merge(
          %{
            "name" => "Form words",
            "type" => "swiss",
            "start_date" => "2026-07-01",
            "rounds_count" => "5",
            "round_dates" => List.duplicate("2026-07-01", 5),
            "tiebreaks" => ["BH", "SB"],
            "chief_arbiter" => "Jane Arbiter",
            "federation" => "BEL",
            "rate_of_play" => "90 min + 30 sec/move"
          },
          attrs
        )
      )

    t
  end

  defp player(t, name, attrs \\ %{}) do
    {:ok, p} = Tournaments.create_player(t.id, Map.merge(%{"name" => name}, attrs))
    p
  end

  defp open_edit(conn, t, p) do
    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/players")
    render_click(lv, "edit_player", %{"id" => to_string(p.id)})
    lv
  end

  defp change(lv, params) do
    lv |> form("#player-edit-form", %{"player" => params}) |> render_change()
  end

  defp submit(lv, params) do
    lv |> form("#player-edit-form", %{"player" => params}) |> render_submit()
  end

  describe "the status ticks" do
    test "four ticks, each with a line saying what it does", %{conn: conn, scope: scope} do
      t = tournament(scope)
      lv = open_edit(conn, t, player(t, "Anna"))

      for id <- ~w(player-absent player-no-half-bye player-withdrawn player-expelled) do
        assert has_element?(lv, "##{id}")
        assert has_element?(lv, "##{id}:not([disabled])")
      end

      for id <-
            ~w(player-absent-tick player-no-half-bye-tick player-withdrawn-tick player-expelled-tick) do
        assert has_element?(lv, "##{id} .status-tick-hint")
      end
    end

    test "Expelled greys out Absent and Withdrawn and sends their stored values back",
         %{conn: conn, scope: scope} do
      t = tournament(scope)
      p = player(t, "Anna", %{"absent" => "true", "forfeit" => "true"})
      lv = open_edit(conn, t, p)

      # Withdrawn already greys Absent out.
      assert has_element?(lv, "#player-absent[disabled]")
      refute has_element?(lv, "#player-withdrawn[disabled]")

      change(lv, %{"status" => "expelled"})
      assert has_element?(lv, "#player-absent[disabled]")
      assert has_element?(lv, "#player-withdrawn[disabled]")
      assert has_element?(lv, "#player-expelled:not([disabled])")

      submit(lv, %{"status" => "expelled"})

      p = Repo.reload!(p)
      assert p.status == "expelled"
      # Untouched: the greyed-out ticks are not rewritten by being greyed out.
      assert p.absent
      assert p.forfeit
    end

    test "Withdrawn greys out Absent only, and untick brings it back", %{conn: conn, scope: scope} do
      t = tournament(scope)
      p = player(t, "Anna", %{"absent" => "true"})
      lv = open_edit(conn, t, p)

      refute has_element?(lv, "#player-absent[disabled]")
      change(lv, %{"forfeit" => "true", "absent" => "true"})
      assert has_element?(lv, "#player-absent[disabled]")
      assert has_element?(lv, "#player-expelled:not([disabled])")

      submit(lv, %{"forfeit" => "true"})
      p = Repo.reload!(p)
      assert p.forfeit and p.absent
    end
  end

  describe "the bye control" do
    test "FIDE rules decide by default; no stray tick or second select", %{
      conn: conn,
      scope: scope
    } do
      t = tournament(scope)
      lv = open_edit(conn, t, player(t, "Anna"))

      assert has_element?(lv, "#player-bye-choice option[value=''][selected]")
      refute has_element?(lv, "#player-no-bye-toggle")
      refute has_element?(lv, "#player-bye-preference-select")
      refute has_element?(lv, "#player-bye-other")
    end

    test "certain rounds plus a preference for the others is stored as the other rounds",
         %{conn: conn, scope: scope} do
      t = tournament(scope)
      p = player(t, "Anna")
      lv = open_edit(conn, t, p)

      change(lv, %{"bye_choice" => "rounds"})
      assert has_element?(lv, "#player-bye-other")

      submit(lv, %{"bye_choice" => "rounds", "no_bye_rounds" => "3,5", "bye_other" => "want_soft"})

      p = Repo.reload!(p)
      assert p.no_bye and p.no_bye_rounds == "3,5"
      assert p.bye_preference == "want_soft"
      assert p.bye_preference_rounds == "1,2,4"

      # And it reads back as the same two answers.
      lv = open_edit(conn, t, p)
      assert has_element?(lv, "#player-bye-choice option[value=rounds][selected]")
      assert has_element?(lv, "#player-bye-other option[value=want_soft][selected]")
    end

    test "never clears a preference, whatever was there", %{conn: conn, scope: scope} do
      t = tournament(scope)
      p = player(t, "Anna", %{"bye_preference" => "avoid_soft"})
      lv = open_edit(conn, t, p)

      submit(lv, %{"bye_choice" => "never"})

      p = Repo.reload!(p)
      assert p.no_bye and p.no_bye_rounds == ""
      assert p.bye_preference == ""
    end

    test "a stored contradiction is shown as the exclusion, said out loud, and cleaned on save",
         %{conn: conn, scope: scope} do
      t = tournament(scope)
      p = player(t, "Anna")
      # A pair an older version let through: never, and also "rather not".
      Repo.update_all(from(x in Player, where: x.id == ^p.id),
        set: [no_bye: true, bye_preference: "avoid_soft"]
      )

      lv = open_edit(conn, t, p)
      assert has_element?(lv, "#player-bye-choice option[value=never][selected]")
      assert has_element?(lv, "#player-bye-clash-note")

      # Untouched until somebody saves the dialog.
      assert Repo.reload!(p).bye_preference == "avoid_soft"

      submit(lv, %{})
      p = Repo.reload!(p)
      assert p.no_bye
      assert p.bye_preference == ""
    end

    test "a stored preference that is not simply the other rounds is kept as stored",
         %{conn: conn, scope: scope} do
      t = tournament(scope)

      p =
        player(t, "Anna", %{
          "no_bye" => "true",
          "no_bye_scope" => "rounds",
          "no_bye_rounds" => "3",
          "bye_preference" => "want_soft",
          "bye_preference_scope" => "rounds",
          "bye_preference_rounds" => "1"
        })

      lv = open_edit(conn, t, p)
      assert has_element?(lv, "#player-bye-other option[value=keep][selected]")

      submit(lv, %{})
      p = Repo.reload!(p)
      assert p.bye_preference == "want_soft"
      assert p.bye_preference_rounds == "1"
    end

    test "a preference choice keeps its own rounds and drops the exclusion", %{
      conn: conn,
      scope: scope
    } do
      t = tournament(scope)
      p = player(t, "Anna", %{"no_bye" => "true", "no_bye_scope" => "all"})
      lv = open_edit(conn, t, p)

      change(lv, %{"bye_choice" => "want_hard"})
      assert has_element?(lv, "#player-bye-preference-scope-all[checked]")
      assert has_element?(lv, "#player-bye-preference-warning")
      refute has_element?(lv, "#player-no-bye-warning")

      change(lv, %{"bye_choice" => "want_hard", "bye_preference_scope" => "rounds"})

      submit(lv, %{
        "bye_choice" => "want_hard",
        "bye_preference_scope" => "rounds",
        "bye_preference_rounds" => "2"
      })

      p = Repo.reload!(p)
      refute p.no_bye
      assert {p.bye_preference, p.bye_preference_rounds} == {"want_hard", "2"}
    end

    test "with the switch off only a stored exclusion's choices are on the list",
         %{conn: conn, scope: scope, user: user} do
      {:ok, _} = PairingsEngine.Features.set_enabled(user, [])
      t = tournament(scope)
      p = player(t, "Anna", %{"no_bye" => "true", "no_bye_scope" => "all"})
      lv = open_edit(conn, t, p)

      assert has_element?(lv, "#player-bye-choice option[value=never][selected]")
      refute has_element?(lv, "#player-bye-choice option[value=want_hard]")

      other = open_edit(conn, t, player(t, "Bert"))
      refute has_element?(other, "#player-bye")
    end
  end

  describe "ByeChoice" do
    test "expand/3 leaves params without the control alone" do
      params = %{"name" => "A", "no_bye" => "true"}
      assert ByeChoice.expand(params, 5) == params
    end

    test "the other rounds are the complement within the round count" do
      assert ByeChoice.complement("3,5", 5) == "1,2,4"
      assert ByeChoice.complement("2-4", 5) == "1,5"
      assert ByeChoice.complement("1-5", 5) == ""
      assert ByeChoice.complement("x", 5) == ""
    end

    test "an exclusion of every round leaves no other rounds to prefer in" do
      out =
        ByeChoice.expand(
          %{"bye_choice" => "rounds", "no_bye_rounds" => "1-5", "bye_other" => "want_hard"},
          5
        )

      assert out["bye_preference"] == ""
    end

    test "keep_preference leaves a FIDE-rated tournament's stored preference alone" do
      out = ByeChoice.expand(%{"bye_choice" => "never"}, 5, keep_preference: true)
      assert out["no_bye"] == "true"
      refute Map.has_key?(out, "bye_preference")
    end
  end

  describe "the changeset" do
    test "never beside rather-not keeps the exclusion when a save touches either" do
      cs =
        Player.changeset(%Player{}, %{
          "name" => "A",
          "no_bye" => "true",
          "no_bye_scope" => "all",
          "bye_preference" => "avoid_soft"
        })

      assert Ecto.Changeset.get_field(cs, :no_bye)
      assert Ecto.Changeset.get_field(cs, :bye_preference) == ""
    end

    test "rather-not in the rounds an exclusion leaves is not touched" do
      cs =
        Player.changeset(%Player{}, %{
          "name" => "A",
          "no_bye" => "true",
          "no_bye_scope" => "rounds",
          "no_bye_rounds" => "3",
          "bye_preference" => "avoid_soft",
          "bye_preference_scope" => "rounds",
          "bye_preference_rounds" => "1,2,4,5"
        })

      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :bye_preference) == "avoid_soft"
    end

    test "wanting the bye in a round it is excluded from is still refused" do
      cs =
        Player.changeset(%Player{}, %{
          "name" => "A",
          "no_bye" => "true",
          "no_bye_scope" => "rounds",
          "no_bye_rounds" => "3",
          "bye_preference" => "want_hard",
          "bye_preference_scope" => "rounds",
          "bye_preference_rounds" => "3,4"
        })

      refute cs.valid?
      assert Keyword.has_key?(cs.errors, :bye_preference)
    end
  end
end
