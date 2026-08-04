defmodule PairingsEngineWeb.NormsOfficialsTest do
  # The Officials & FIDE report data card moved from SettingsLive to the Norms
  # tab. These tests cover that relocated card (arbiter FIDE-autocomplete,
  # officials fields, saving).
  #
  # async: false: sequential SQLite writes plus self-broadcast/render draining.
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Repo, Tournaments}
  alias PairingsEngine.Fide.FidePlayer
  alias PairingsEngineWeb.Live.ArbiterCombo

  setup :register_and_log_in_user

  defp create_tournament(scope, attrs \\ %{}) do
    {:ok, tournament} =
      Tournaments.create_tournament(
        scope,
        Map.merge(%{"name" => "Norms LV Test", "type" => "swiss", "rounds_count" => "5"}, attrs)
      )

    tournament
  end

  test "the Officials card offers only 2 ranked deputy slots — FIDE never ranks a 3rd/4th — and no standalone FIDE-id / pairing-mode inputs",
       %{conn: conn, scope: scope} do
    tournament = create_tournament(scope)
    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/norms")

    refute html =~ "Chief arbiter FIDE ID"
    refute html =~ ~s(name="tournament[officials][pairing_mode]")
    refute html =~ ~s(name="tournament[officials][pairing_program]")
    refute html =~ ~s(name="tournament[officials][swiss_variant]")

    # Only 2 — FIDE's own printed Certificaat ranks exactly 2 deputies by
    # name; anyone beyond that is a plain, unranked "Arbiter" via
    # "+ Add arbiter" (see docs/norms.md).
    assert html =~ "1st deputy arbiter"
    assert html =~ "2nd deputy arbiter"
    refute html =~ "3rd deputy arbiter"
    refute html =~ "4th deputy arbiter"

    # The deputy FIDE id is only carried as a hidden field.
    refute html =~
             ~s(type="text" id="arbiter-combo-deputy1-id-hidden" name="tournament[officials][deputy1_fide_id]")

    assert html =~
             ~s(type="hidden" id="arbiter-combo-deputy1-id-hidden" name="tournament[officials][deputy1_fide_id]")
  end

  test "arbiters 1 and 2 (beyond the 2 ranked deputies) save and reach the officials map",
       %{conn: conn, scope: scope} do
    tournament = create_tournament(scope)
    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/norms")

    render_submit(lv, "save_officials", %{
      "tournament" => %{
        "officials" => %{
          "extra_arbiters_count" => "2",
          "arbiter1_name" => "First Arbiter",
          "arbiter1_fide_id" => "300003",
          "arbiter2_name" => "Second Arbiter",
          "arbiter2_fide_id" => "400004"
        }
      }
    })

    render(lv)

    saved = Tournaments.get_authorized_tournament!(scope, tournament.id)
    assert saved.officials["arbiter1_name"] == "First Arbiter"
    assert saved.officials["arbiter1_fide_id"] == "300003"
    assert saved.officials["arbiter2_name"] == "Second Arbiter"
    assert saved.officials["arbiter2_fide_id"] == "400004"
  end

  test "the IT3 counts explainer lists the actual players behind each category, collapsed by default",
       %{conn: conn, scope: scope} do
    tournament = create_tournament(scope, %{"federation" => "BEL"})

    {:ok, _} =
      Tournaments.create_player(tournament.id, %{
        "name" => "Carlsen, Magnus",
        "title" => "GM",
        "fide_rating" => "2830",
        "federation" => "NOR"
      })

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/norms")

    assert html =~ "How the IT3 rated / titled / federation counts were calculated"
    # <details> with no `open` attribute is collapsed by default.
    refute html =~ "<details class=\"it3-explain\" open"
    assert html =~ "Carlsen, Magnus"
    assert html =~ "GM"
  end

  test "'+ Add arbiter' offers a 5th slot beyond the 4 built-in deputies, which saves and downloads",
       %{conn: conn, scope: scope} do
    tournament = create_tournament(scope)

    Repo.insert!(%FidePlayer{
      fide_id: 205_494,
      name: "Cornet, Luc",
      federation: "BEL"
    })

    {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/norms")
    refute html =~ "Arbiter 1"

    html = lv |> element(~s(button[phx-click="add_arbiter"])) |> render_click()
    assert html =~ "Arbiter 1"

    lv
    |> element("input[name='tournament[officials][arbiter1_name]']")
    |> render_change(%{
      "tournament" => %{"officials" => %{"arbiter1_name" => "Cornet"}},
      "_target" => ["tournament", "officials", "arbiter1_name"]
    })

    lv
    |> element(~s(button[phx-click="arbiter_pick"][phx-value-fide-id="205494"]))
    |> render_click()

    render_submit(lv, "save_officials", %{
      "tournament" => %{
        "officials" => %{
          "extra_arbiters_count" => "1",
          "arbiter1_name" => "Cornet, Luc",
          "arbiter1_fide_id" => "205494"
        }
      }
    })

    render(lv)

    saved = Tournaments.get_authorized_tournament!(scope, tournament.id)
    assert saved.officials["arbiter1_name"] == "Cornet, Luc"
    assert saved.officials["arbiter1_fide_id"] == "205494"

    conn = get(conn, ~p"/t/#{tournament.id}/norms/it3")
    assert conn.status == 200
    {:ok, members} = :zip.extract(conn.resp_body, [:memory])
    xml = Enum.map_join(members, fn {_name, bin} -> bin end)
    assert xml =~ "205494"
    assert xml =~ "CORNET, Luc"
  end

  test "typing a chief arbiter name — through the real form, either box — shows FIDE matches, and picking one fills name + FIDE id then saves",
       %{conn: conn, scope: scope} do
    tournament = create_tournament(scope)

    fide_player =
      Repo.insert!(%FidePlayer{
        fide_id: 1_503_014,
        name: "Carlsen, Magnus",
        federation: "NOR",
        title: "GM"
      })

    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/norms")

    # Typing in the NAME box searches — a real browser routes the change
    # event to the input's OWN phx-change, not the surrounding form's, so
    # the test must target that input directly rather than going through
    # `form/3` (which sends the form's `phx-change`, "officials_change").
    html =
      lv
      |> element("input[name='tournament[chief_arbiter]']")
      |> render_change(%{
        "tournament" => %{"chief_arbiter" => "Carlsen"},
        "_target" => ["tournament", "chief_arbiter"]
      })

    assert html =~ "Carlsen, Magnus"

    html =
      render_click(lv, "arbiter_pick", %{
        "role" => "chief_arbiter",
        "fide-id" => to_string(fide_player.fide_id)
      })

    assert html =~ ~s(value="Carlsen, Magnus")
    # The real, submitted field — a hidden input, only ever set by a pick.
    assert html =~ ~s(name="tournament[officials][chief_arbiter_fide_id]" value="1503014")

    render_submit(lv, "save_officials", %{
      "tournament" => %{
        "chief_arbiter" => "Carlsen, Magnus",
        "officials" => %{"chief_arbiter_fide_id" => "1503014"}
      }
    })

    render(lv)

    saved = Tournaments.get_authorized_tournament!(scope, tournament.id)
    assert saved.chief_arbiter == "Carlsen, Magnus"
    assert saved.officials["chief_arbiter_fide_id"] == "1503014"
  end

  test "typing a FIDE ID directly into the id box searches too, and only a pick commits it", %{
    conn: conn,
    scope: scope
  } do
    tournament = create_tournament(scope)

    Repo.insert!(%FidePlayer{
      fide_id: 1_503_014,
      name: "Carlsen, Magnus",
      federation: "NOR",
      title: "GM"
    })

    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/norms")

    # Typing digits into the ID search box (a field OUTSIDE the
    # tournament[...] namespace — see ArbiterCombo.id_search_name/1) finds the
    # same player a name search would have. Target the input directly, same
    # reasoning as the name-box test above.
    html =
      lv
      |> element("input[name='fide_id_search[chief_arbiter_fide_id]']")
      |> render_change(%{
        "fide_id_search" => %{"chief_arbiter_fide_id" => "1503014"},
        "_target" => ["fide_id_search", "chief_arbiter_fide_id"]
      })

    assert html =~ "Carlsen, Magnus"

    # Merely typing the id must NOT itself have committed anything — the real
    # hidden field is still blank until a result is actually picked.
    refute html =~ ~s(name="tournament[officials][chief_arbiter_fide_id]" value="1503014")

    html =
      render_click(lv, "arbiter_pick", %{"role" => "chief_arbiter", "fide-id" => "1503014"})

    assert html =~ ~s(name="tournament[officials][chief_arbiter_fide_id]" value="1503014")
  end

  test "the FIDE identifiers moved to the FIDE settings page, not the Norms Officials card", %{
    conn: conn,
    scope: scope
  } do
    tournament = create_tournament(scope)
    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/norms")

    refute html =~ ~s(name="tournament[fide_tournament_id]")
    refute html =~ ~s(name="tournament[event_code]")

    {:ok, _lv, fide_html} = live(conn, ~p"/t/#{tournament.id}/settings/fide")
    assert fide_html =~ ~s(name="tournament[fide_tournament_id]")
    assert fide_html =~ ~s(name="tournament[event_code]")
  end

  ## ---------- FA1/IA1 arbiter norm candidate picker ----------

  describe "FA1/IA1 candidate dropdown" do
    test "offers the event's own officials and prefills all four fields from the FIDE record", %{
      conn: conn,
      scope: scope
    } do
      Repo.insert_all(FidePlayer, [
        %{fide_id: 214_787, name: "De Vet, Sylvin", federation: "BEL"}
      ])

      tournament = create_tournament(scope, %{"chief_arbiter" => "Luc Cornet"})

      {:ok, tournament} =
        Tournaments.update_tournament(tournament, %{
          "officials" => %{
            "deputy1_name" => "Sylvin De Vet",
            "deputy1_fide_id" => "214787"
          }
        })

      {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/norms")

      # Both officials are offered as candidates.
      assert html =~ "Pick an arbiter"
      assert html =~ "Sylvin De Vet"

      html =
        lv
        |> element("select[name=fa1_candidate]")
        |> render_change(%{"fa1_candidate" => "deputy1"})

      # FIDE's "Last, First" drives the split, so the surname stays intact --
      # a positional guess on SWAR's "Sylvin De Vet" would have said "Vet".
      assert html =~ ~s(value="De Vet")
      assert html =~ ~s(value="Sylvin")
      assert html =~ ~s(value="214787")
      assert html =~ ~s(value="BEL")
    end

    test "an official with no FIDE id still prefills the name, leaving the id blank", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope, %{"chief_arbiter" => "Jan Peeters"})
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/norms")

      html =
        lv
        |> element("select[name=fa1_candidate]")
        |> render_change(%{"fa1_candidate" => "chief_arbiter"})

      assert html =~ ~s(value="Peeters")
      assert html =~ ~s(value="Jan")
    end

    test "choosing the blank option clears the fields again", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope, %{"chief_arbiter" => "Jan Peeters"})
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/norms")

      lv
      |> element("select[name=fa1_candidate]")
      |> render_change(%{"fa1_candidate" => "chief_arbiter"})

      html =
        lv |> element("select[name=fa1_candidate]") |> render_change(%{"fa1_candidate" => ""})

      refute html =~ ~s(value="Peeters")
    end

    test "no picker at all when the tournament has no officials named", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)
      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/norms")

      refute html =~ "Pick an arbiter"
    end
  end

  ## ---------- report readiness gate ----------

  describe "FIDE report blockers" do
    test "a chief arbiter with no FIDE ID blocks the IT3/FA1 downloads with a red bar", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope, %{"chief_arbiter" => "Luc Cornet"})
      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/norms")

      assert html =~ "Not ready to submit to FIDE"
      assert html =~ "Chief arbiter FIDE ID"
      assert html =~ "report-blocked"
      # The IT3 link is replaced by a disabled button, so it can't be clicked
      # through even though the route still exists.
      refute html =~ ~s(href="/t/#{tournament.id}/norms/it3")
      assert html =~ "disabled"
    end

    test "a named deputy without a FIDE ID also blocks", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope, %{"chief_arbiter" => "Luc Cornet"})

      {:ok, tournament} =
        Tournaments.update_tournament(tournament, %{
          "officials" => %{
            "chief_arbiter_fide_id" => "205494",
            "deputy1_name" => "Marc Van Dyck"
          }
        })

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/norms")

      assert html =~ "Not ready to submit to FIDE"
      assert html =~ "1st deputy arbiter FIDE ID"
    end

    test "an empty deputy slot is fine — not every event has two", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope, %{"chief_arbiter" => "Luc Cornet"})

      {:ok, tournament} =
        Tournaments.update_tournament(tournament, %{
          "officials" => %{
            "chief_arbiter_fide_id" => "205494",
            "chief_arbiter_email" => "arbiter@example.com",
            "organizer_email" => "organizer@example.com"
          }
        })

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/norms")

      refute html =~ "Not ready to submit to FIDE"
      assert html =~ ~s(href="/t/#{tournament.id}/norms/it3")
    end

    test "everything filled in unblocks the downloads", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope, %{"chief_arbiter" => "Luc Cornet"})

      {:ok, tournament} =
        Tournaments.update_tournament(tournament, %{
          "officials" => %{
            "chief_arbiter_fide_id" => "205494",
            "chief_arbiter_email" => "arbiter@example.com",
            "organizer_email" => "organizer@example.com",
            "deputy1_name" => "Sylvin De Vet",
            "deputy1_fide_id" => "214787"
          }
        })

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/norms")

      refute html =~ "Not ready to submit to FIDE"
      assert html =~ ~s(href="/t/#{tournament.id}/norms/it3")
    end

    test "a missing chief arbiter or organizer e-mail blocks the download, matching FIDE's own privacy-notice requirement",
         %{conn: conn, scope: scope} do
      tournament = create_tournament(scope, %{"chief_arbiter" => "Luc Cornet"})

      {:ok, tournament} =
        Tournaments.update_tournament(tournament, %{
          "officials" => %{"chief_arbiter_fide_id" => "205494"}
        })

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/norms")

      assert html =~ "Not ready to submit to FIDE"
      assert html =~ "Chief arbiter e-mail"
      assert html =~ "Organizer e-mail"
      refute html =~ ~s(href="/t/#{tournament.id}/norms/it3")
    end
  end

  ## ---------- arbiter picker usability ----------

  test "autocomplete rows carry birth year and FIDE id so namesakes are distinguishable", %{
    conn: conn,
    scope: scope
  } do
    Repo.insert_all(FidePlayer, [
      %{fide_id: 207_640, name: "Van Dyck, Marc", federation: "BEL", birth_year: 1960},
      %{fide_id: 228_494, name: "Van Dyck, Marc", federation: "BEL", birth_year: 1953}
    ])

    tournament = create_tournament(scope)

    {:ok, tournament} =
      Tournaments.update_tournament(tournament, %{
        "officials" => %{"deputy1_name" => "Marc Van Dyck"}
      })

    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/norms")

    # Retyping the name already stored (exactly the case the SWAR import
    # leaves behind) re-triggers the same search, no separate button needed.
    # Target the input directly, same reasoning as above.
    html =
      lv
      |> element("input[name='tournament[officials][deputy1_name]']")
      |> render_change(%{
        "tournament" => %{"officials" => %{"deputy1_name" => "Marc Van Dyck"}},
        "_target" => ["tournament", "officials", "deputy1_name"]
      })

    assert html =~ "b. 1960"
    assert html =~ "b. 1953"
    assert html =~ "#207640"
    assert html =~ "#228494"
  end

  test "edits to the FA1 fields survive a re-render and are what gets submitted", %{
    conn: conn,
    scope: scope
  } do
    tournament = create_tournament(scope, %{"chief_arbiter" => "Jan Peeters"})
    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/norms")

    html =
      lv
      |> form("#fa1-candidate-form", %{
        "candidate" => %{
          "last_name" => "Corrected",
          "first_name" => "Name",
          "fide_id" => "999999",
          "federation" => "NED"
        }
      })
      |> render_change()

    assert html =~ ~s(value="Corrected")
    assert html =~ ~s(value="999999")

    # A picker choice after typing replaces the fields (expected), but an
    # unrelated re-render must not silently revert them.
    send(lv.pid, {:tournament_changed, tournament.id, nil})
    html = render(lv)

    assert html =~ ~s(value="Corrected")
    assert html =~ ~s(value="999999")
  end

  ## ---------- regression: the autocomplete crashed the LiveView ----------

  # `phx-value-role` is dropped for form-serialised change events — LiveView
  # sends the form data plus `_target` and nothing else. The old handler
  # matched `%{"role" => role}`, so every keystroke in an arbiter name field
  # raised FunctionClauseError and killed the LiveView; the user saw
  # "something went wrong, attempting to reconnect". That parsing now lives in
  # `PairingsEngineWeb.Live.ArbiterCombo`, shared with the public tools page —
  # see `PairingsEngineWeb.ToolsNormsLiveTest` for the same guarantee there.
  #
  # Driven at the role-derivation level with the exact payloads the browser
  # sends. An earlier test passed hand-written params that *included* "role"
  # and so proved nothing about the real shape — the lesson being that a
  # synthetic payload can only test the clause you already wrote.
  describe "ArbiterCombo.target_role_and_field/1 (the shape that crashed)" do
    test "derives {role, :name} from _target for every name-field spelling" do
      assert ArbiterCombo.target_role_and_field(%{
               "_target" => ["tournament", "officials", "deputy1_name"]
             }) == {"deputy1", :name}

      assert ArbiterCombo.target_role_and_field(%{
               "_target" => ["tournament", "officials", "deputy2_name"]
             }) == {"deputy2", :name}

      assert ArbiterCombo.target_role_and_field(%{"_target" => ["tournament", "chief_arbiter"]}) ==
               {"chief_arbiter", :name}

      # The public tools page spells the chief arbiter's name field
      # differently (a flat "chief_arbiter_name" key, following the same
      # convention every other role already uses) — both must resolve to the
      # same role.
      assert ArbiterCombo.target_role_and_field(%{
               "_target" => ["overlay", "chief_arbiter_name"]
             }) == {"chief_arbiter", :name}

      assert ArbiterCombo.target_role_and_field(%{
               "_target" => ["tournament", "officials", "person_responsible_pairings"]
             }) == {"person_responsible_pairings", :name}
    end

    test "derives {role, :id} from the FIDE-ID search box, regardless of namespace" do
      assert ArbiterCombo.target_role_and_field(%{
               "_target" => ["fide_id_search", "chief_arbiter_fide_id"]
             }) == {"chief_arbiter", :id}

      assert ArbiterCombo.target_role_and_field(%{
               "_target" => ["fide_id_search", "deputy1_fide_id"]
             }) == {"deputy1", :id}

      assert ArbiterCombo.target_role_and_field(%{
               "_target" => ["fide_id_search", "person_responsible_pairings_fide_id"]
             }) == {"person_responsible_pairings", :id}
    end

    test "a non-arbiter field yields nil rather than raising" do
      assert ArbiterCombo.target_role_and_field(%{
               "_target" => ["tournament", "officials", "organizer_email"]
             }) == nil

      assert ArbiterCombo.target_role_and_field(%{"_target" => ["something", "else"]}) == nil
      assert ArbiterCombo.target_role_and_field(%{}) == nil
    end
  end

  test "typing in an arbiter field searches instead of taking the LiveView down", %{
    conn: conn,
    scope: scope
  } do
    Repo.insert_all(FidePlayer, [
      %{fide_id: 207_640, name: "Van Dyck, Marc", federation: "BEL", birth_year: 1960},
      %{fide_id: 228_494, name: "Van Dyck, Marc", federation: "BEL", birth_year: 1953}
    ])

    tournament = create_tournament(scope)
    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/norms")

    lv
    |> form("#officials-form", %{
      "tournament" => %{"officials" => %{"deputy1_name" => "Van Dyck"}}
    })
    |> render_change()

    # Still alive: a FunctionClauseError here would have terminated the
    # LiveView process and made this raise.
    assert render(lv) =~ "Officials"
  end

  ## ---------- every official must carry a FIDE ID ----------

  describe "saving officials without a FIDE ID" do
    test "a named deputy with no id is refused, and nothing is written", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/norms")

      html =
        lv
        |> form("#officials-form", %{
          "tournament" => %{"officials" => %{"deputy1_name" => "Marc Van Dyck"}}
        })
        |> render_submit()

      assert html =~ "Every official needs a FIDE ID"
      assert html =~ "1st deputy arbiter"

      # Refused, not silently stored half-filled.
      reloaded = Tournaments.get_tournament!(tournament.id)
      assert Map.get(reloaded.officials || %{}, "deputy1_name") in [nil, ""]
    end

    test "a chief arbiter with no id is refused", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/norms")

      html =
        lv
        |> form("#officials-form", %{"tournament" => %{"chief_arbiter" => "Luc Cornet"}})
        |> render_submit()

      assert html =~ "Every official needs a FIDE ID"
      assert html =~ "Chief arbiter"
    end

    test "name plus id saves normally", %{conn: conn, scope: scope} do
      # The FIDE-ID inputs are hidden and only written by picking a search
      # result — there is deliberately no way to type one by hand — so the id
      # is seeded here the way a pick would have left it.
      tournament = create_tournament(scope)

      {:ok, tournament} =
        Tournaments.update_tournament(tournament, %{
          "officials" => %{"chief_arbiter_fide_id" => "205494"}
        })

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/norms")

      html =
        lv
        |> form("#officials-form", %{"tournament" => %{"chief_arbiter" => "Cornet, Luc"}})
        |> render_submit()

      refute html =~ "Every official needs a FIDE ID"
      assert html =~ "Saved."

      reloaded = Tournaments.get_tournament!(tournament.id)
      assert reloaded.chief_arbiter == "Cornet, Luc"
      assert reloaded.officials["chief_arbiter_fide_id"] == "205494"
    end

    test "leaving an official entirely blank is still allowed", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/norms")

      html =
        lv
        |> form("#officials-form", %{
          "tournament" => %{"officials" => %{"organizer_email" => "a@b.c"}}
        })
        |> render_submit()

      refute html =~ "Every official needs a FIDE ID"
      assert html =~ "Saved."
    end
  end
end
