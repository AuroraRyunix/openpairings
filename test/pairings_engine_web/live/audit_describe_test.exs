defmodule PairingsEngineWeb.AuditDescribeTest do
  @moduledoc """
  The Audit page's sentences, in both languages.

  `AuditLive.describe/2` is the whole readable content of the page an
  arbiter opens when something went wrong, and it was built by string
  interpolation - so no gettext pass ever saw it, and a Dutch arbiter got a
  Dutch page with every row in English. `translations_test.exs` cannot catch
  that shape of gap: it checks the catalogue, and a sentence that never
  reached the catalogue is not in it to be checked.

  So this test starts from the other end. It reads `audit_live.ex` itself for
  every action code a `describe/2` clause names, requires an entry for each
  one here, and renders every entry in English and in Dutch. A clause added
  later without a translation fails here: first for having no entry, then -
  once it has one - for rendering the same in both languages, or for leaving
  an English word in the Dutch.
  """
  use ExUnit.Case, async: true

  alias PairingsEngineWeb.AuditLive
  alias PairingsEngine.AuditActionCodes

  @source "lib/pairings_engine_web/live/audit_live.ex"

  # Words the Dutch sentence legitimately shares with the English one: words
  # both languages spell the same (`is`, `in`, `was`, `per`, `extra`, `via`,
  # `gratis` - the Players page's own label for a free entry in both), chess
  # and software loanwords the catalogue keeps (`bye`, `rating`, `logo`,
  # `link`, `token`, `computer`), identifiers (`FIDE`, `SWAR`, `guid`), and
  # labels whose Dutch msgstr is currently the English word: the `Support`
  # role and the phone access levels (see
  # docs/translations-audit-2026-09-12.md, finding 14).
  @shared ~w(is in was per extra via gratis bye byes rating ratings logo link token
             computer guid swar trf json csv fide elo keizer support deputy helper)

  # Representative details for every described action, in the shape they
  # come back from the JSON column: string keys. The first entry of each list
  # is the ordinary case; the rest reach the clause's other sentences.
  @entries %{
    "player.created" => [
      %{"player_id" => 7, "player_name" => "Anna Peeters", "rating" => 1850},
      %{"player_id" => 7, "player_name" => "Anna Peeters"}
    ],
    "player.updated" => [
      %{
        "player_name" => "Anna Peeters",
        "changed_fields" => %{"absent" => [false, true], "fide_rating" => [1850, 1873]}
      },
      %{"player_name" => "Anna Peeters", "changed_fields" => %{}}
    ],
    "player.deleted" => [%{"player_name" => "Anna Peeters"}],
    "registration.accepted" => [%{"player_name" => "Bram Claes"}],
    "registration.discarded" => [%{"player_name" => "Bram Claes"}],
    "player.ratings_refreshed" => [%{"players_updated" => 12}, %{"players_updated" => 1}],
    "player.clubs_refreshed" => [%{"players_updated" => 5}, %{"players_updated" => 1}],
    "player.bulk_absent_set" => [
      %{"absent" => true, "player_count" => 24},
      %{"absent" => false, "player_count" => 1}
    ],
    "player.bulk_paid_set" => [
      %{"paid" => "paid", "player_count" => 24},
      %{"paid" => "nopaid", "player_count" => 1},
      %{"paid" => "gratis", "player_count" => 24},
      # Refused by `set_all_players_paid/2`; only a hand-edited backup has it.
      %{"paid" => "halfpaid", "player_count" => 24}
    ],
    "player.bulk_category_set" => [
      %{"category" => "U12", "added" => true, "player_count" => 24},
      %{"category" => "U12", "added" => false, "player_count" => 1}
    ],
    "pairing.round_paired" => [
      %{
        "round" => 3,
        "board_count" => 12,
        "bye_count" => 1,
        "floater_count" => 4,
        "allocated_bye" => %{"player" => "Bram Claes"}
      },
      %{"round" => 3, "board_count" => 12, "bye_count" => 1, "floater_count" => 0},
      %{"round" => 3, "board_count" => 12, "bye_count" => 0, "floater_count" => 2},
      %{"round" => 1, "board_count" => 1}
    ],
    "pairing.result_entered" => [
      %{
        "round" => 2,
        "board" => 4,
        "white" => "Anna Peeters",
        "black" => "Bram Claes",
        "to" => "1-0"
      },
      %{"round" => 2, "board" => 9, "white" => "Chris Maes", "black" => nil, "to" => "1-0"},
      %{
        "round" => 2,
        "board" => 4,
        "white" => "Anna Peeters",
        "black" => "Bram Claes",
        "to" => "0-1",
        "via" => "mobile",
        "enrollment_id" => 5,
        "enrollment_label" => "Tafel 3",
        "enrollment_level" => "deputy"
      },
      %{
        "round" => 2,
        "board" => 4,
        "white" => "Anna Peeters",
        "black" => "Bram Claes",
        "to" => "0-1",
        "via" => "mobile",
        "enrollment_id" => 5,
        "enrollment_label" => "Tafel 3"
      },
      %{
        "round" => 2,
        "board" => 4,
        "white" => "Anna Peeters",
        "black" => "Bram Claes",
        "to" => "0-1",
        "via" => "mobile",
        "enrollment_id" => 5,
        "enrollment_label" => nil,
        "enrollment_level" => "helper"
      },
      %{
        "round" => 2,
        "board" => 4,
        "white" => "Anna Peeters",
        "black" => "Bram Claes",
        "to" => "0-1",
        "via" => "mobile",
        "enrollment_id" => 5,
        "enrollment_label" => ""
      }
    ],
    "pairing.result_changed" => [
      %{
        "round" => 2,
        "board" => 4,
        "white" => "Anna Peeters",
        "black" => "Bram Claes",
        "from" => "1-0",
        "to" => "0-1"
      },
      %{"round" => 2, "board" => 9, "white" => "Chris Maes", "from" => "0-1", "to" => "1-0"},
      %{
        "round" => 2,
        "board" => 4,
        "white" => "Anna Peeters",
        "black" => "Bram Claes",
        "from" => "1-0",
        "to" => ""
      }
    ],
    "pairing.result_cleared" => [
      %{
        "round" => 2,
        "board" => 4,
        "white" => "Anna Peeters",
        "black" => "Bram Claes",
        "from" => "1/2-1/2",
        "to" => ""
      },
      %{"round" => 2, "board" => 9, "white" => "Chris Maes", "from" => "1-0", "to" => ""}
    ],
    "pairing.round_deleted" => [%{"round" => 3}],
    "pairing.results_imported" => [
      %{"round" => 2, "results_set" => 8},
      %{"round" => 2, "results_set" => 1}
    ],
    "pairing.result_clear_attempted" => [
      %{"round" => 2, "board" => 4, "white" => "Anna Peeters", "from" => "1-0"}
    ],
    # The confirmation subtitles `PairingsLive.confirm_for/2` writes, word for
    # word, as `summary`.
    "pairing.players_swapped" => [
      %{"round" => 3, "summary" => "Anna Peeters  ⇄  Bram Claes"},
      %{"round" => 3}
    ],
    "pairing.player_substituted" => [
      %{"round" => 3, "summary" => "Chris Maes takes Bram Claes's place"}
    ],
    "pairing.seat_vacated" => [%{"round" => 3, "summary" => "Bram Claes is not playing round 3"}],
    "pairing.bye_awarded" => [%{"round" => 3, "summary" => "Anna Peeters sits out round 3"}],
    "pairing.seat_filled" => [%{"round" => 3, "summary" => "Chris Maes joins board 7"}],
    "pairing.pool_paired" => [%{"round" => 3, "summary" => "Chris Maes  vs  Dirk Jacobs"}],
    "pairing.deleted" => [%{"round" => 3, "summary" => "Board 12 is removed from round 3"}],
    "pairing.hidden" => [%{"pairing_id" => 41, "round" => 3, "board" => 12}],
    "pairing.unhidden" => [%{"pairing_id" => 41, "round" => 3, "board" => 12}],
    "pairing.pairings_published" => [%{"through_round" => 4}, %{"through_round" => 1}],
    "pairing.pairings_unpublished" => [%{"from_round" => 4}, %{"from_round" => 1}, %{}],
    "pairing.account_recomputed" => [
      %{"recomputed" => 6, "skipped" => %{":current" => 2, ":hand_edited" => 1}},
      %{"recomputed" => 1, "skipped" => %{":current" => 1}},
      %{"recomputed" => 0, "skipped" => %{}}
    ],
    "pairing.account_deepened" => [%{"round" => 5}],
    "tournament.settings_updated" => [
      %{
        "changed_fields" => %{
          "rounds_count" => [7, 9],
          "tiebreaks" => [["BH", "SB"], ["BH", "SB", "DE"]],
          "fide_homologated" => [false, true]
        }
      },
      %{"changed_fields" => %{}}
    ],
    "tournament.locked_field_changed" => [
      %{"field" => "pairing_engine", "from" => "javafo", "to" => "ainalrami"},
      %{"field" => "pair_by_category", "from" => false, "to" => true}
    ],
    "tournament.fide_compliance_lost" => [
      %{"setting" => "pairing_system", "code" => "non_fide_pairing_system", "round" => 3},
      %{"setting" => "pair_by_category", "code" => "categories_paired_separately", "round" => 0},
      %{"setting" => "swiss_match_format", "code" => "match_format", "round" => nil}
    ],
    "tournament.created" => [
      %{"name" => "Paasopen Brugge", "pairing_system" => "swiss"},
      %{"name" => "Paasopen Brugge", "pairing_system" => "round_robin"},
      %{"name" => "Paasopen Brugge", "pairing_system" => "keizer"},
      %{"name" => "Paasopen Brugge"},
      %{"name" => "Paasopen Brugge", "pairing_system" => "scheveningen"}
    ],
    "tournament.deleted" => [%{"name" => "Paasopen Brugge"}],
    "tournament.restored" => [%{"name" => "Paasopen Brugge"}],
    "import.swar" => [%{"name" => "Paasopen Brugge"}],
    "import.trf" => [%{"name" => "Paasopen Brugge"}],
    "import.json" => [%{"name" => "Paasopen Brugge"}],
    "collaborator.invited" => [%{"email" => "an@example.org"}],
    "collaborator.accepted" => [%{"email" => "an@example.org"}],
    "collaborator.declined" => [%{"email" => "an@example.org"}],
    "collaborator.removed" => [%{"email" => "an@example.org"}],
    "forbidden_pairing.added" => [%{"player_a_id" => 3, "player_b_id" => 8}],
    "forbidden_pairing.removed" => [%{"player_a_id" => 3, "player_b_id" => 8}],
    "category.created" => [%{"name" => "U12"}],
    "category.removed" => [%{"name" => "U12"}],
    "category.rules_updated" => [%{}],
    "category.auto_assigned" => [
      %{"matched" => 18, "total" => 40},
      %{"matched" => 1, "total" => 1}
    ],
    "logo.uploaded" => [%{"content_type" => "image/png", "bytes" => 2048}],
    "logo.cleared" => [%{}],
    "standings.manual_reorder" => [
      %{"player_name" => "Anna Peeters", "direction" => "up"},
      %{"player_name" => "Anna Peeters", "direction" => "down"},
      %{"player_name" => "Anna Peeters"}
    ],
    "standings.manual_ranking_enabled" => [%{}],
    "standings.manual_ranking_disabled" => [%{}],
    "standings.manual_reseeded" => [%{}],
    "standings.extra_points_applied" => [
      %{"matched" => 6, "total" => 40},
      %{"matched" => 1, "total" => 1}
    ],
    "standings.published" => [%{"through_round" => 3}, %{"through_round" => 0}],
    "standings.unpublished" => [
      %{"from_round" => 3},
      %{"from_round" => 1},
      %{"from_round" => 0},
      %{}
    ],
    "standings.starting_rank_toggled" => [%{"enabled" => true}, %{"enabled" => false}],
    "tournament.archived" => [%{"name" => "Paasopen Brugge"}],
    "tournament.unarchived" => [%{"name" => "Paasopen Brugge"}],
    "tournament.handoff_forced" => [
      %{"name" => "Paasopen Brugge", "was_handed_off_to" => "Laptop zaal B"},
      %{"name" => "Paasopen Brugge"}
    ],
    "handoff.handed_off" => [
      %{"to" => "Laptop zaal B", "name" => "Paasopen Brugge", "at" => "2026-09-13T09:00:00Z"},
      %{"to" => "", "name" => "Paasopen Brugge"}
    ],
    "handoff.received" => [
      %{
        "from" => "clublaptop",
        "address" => "http://192.168.1.20:4000",
        "name" => "Paasopen Brugge"
      },
      %{"from" => "clublaptop", "address" => "", "name" => "Paasopen Brugge"},
      %{"from" => "", "address" => "http://192.168.1.20:4000", "name" => "Paasopen Brugge"},
      %{"from" => "", "address" => "", "name" => "Paasopen Brugge"}
    ],
    "handoff.returned" => [
      %{
        "to" => "clublaptop",
        "address" => "http://192.168.1.20:4000",
        "name" => "Paasopen Brugge"
      },
      %{
        "to" => "http://192.168.1.20:4000",
        "address" => "http://192.168.1.20:4000",
        "name" => "Paasopen Brugge"
      },
      %{"to" => "", "address" => "", "name" => "Paasopen Brugge"}
    ],
    "handoff.released" => [
      %{"from" => "Laptop zaal B", "name" => "Paasopen Brugge"},
      %{"from" => nil, "name" => "Paasopen Brugge"}
    ],
    "tournament.duplicated" => [%{"from_name" => "Paasopen Brugge"}],
    "tournament.left" => [%{"name" => "Paasopen Brugge"}],
    "snapshot.restored" => [
      %{"restored_to" => "Voor de prijsuitreiking"},
      %{"restored_to" => ""}
    ],
    "snapshot.manual" => [%{"label" => "Voor de prijsuitreiking"}, %{"label" => ""}],
    "categories.toggled" => [%{"enabled" => true}, %{"enabled" => false}],
    "pair_by_category.toggled" => [%{"enabled" => true}, %{"enabled" => false}],
    "public_pages.toggled" => [%{"enabled" => true}, %{"enabled" => false}],
    "public_pages.link_rotated" => [%{"published" => true}],
    "registration.toggled" => [%{"open" => true}, %{"open" => false}],
    "openresults.toggled" => [%{"enabled" => true}, %{"enabled" => false}],
    "openresults.listed" => [%{"listed" => true}, %{"listed" => false}],
    "openresults.display" => [
      %{"hidden" => ["club", "rating"], "hidden_tiebreaks" => ["BH", "SB"]},
      %{"hidden" => ["club"], "hidden_tiebreaks" => []},
      %{"hidden" => [], "hidden_tiebreaks" => ["DE"]},
      %{"hidden" => [], "hidden_tiebreaks" => []},
      # Written before tie-breaks could be hidden (2026-08-30).
      %{"hidden" => ["dates"]}
    ],
    "openresults.taken_down" => [%{"slug" => "k3v9x2"}],
    "openresults.claim_adopted" => [%{"slug" => "k3v9x2"}],
    "openresults.claim_discarded" => [%{}],
    "openresults.public_consent_given" => [
      %{
        "host" => "openresults.zerotwo.cloud",
        "operator" => "ZeroTwo",
        "register_again" => false
      },
      %{"host" => "openresults.zerotwo.cloud", "operator" => nil, "register_again" => false},
      %{"host" => "openresults.zerotwo.cloud", "operator" => "ZeroTwo", "register_again" => true}
    ],
    "openresults.public_consent_declined" => [%{"host" => "openresults.zerotwo.cloud"}],
    "swar.published" => [%{"guid" => "3f2a-77c1"}],
    "swar.publish_failed" => [
      %{"guid" => "3f2a-77c1", "step" => "upload", "error" => "HTTP 500"},
      %{"guid" => "3f2a-77c1", "step" => "index", "error" => "HTTP 502"},
      %{"guid" => "3f2a-77c1", "error" => "HTTP 503"}
    ],
    "admin.role_changed" => [
      %{"email" => "an@example.org", "changed_fields" => %{"role" => ["owner", "admin"]}},
      %{"email" => "an@example.org", "changed_fields" => %{"role" => ["support", "owner"]}},
      %{"email" => "an@example.org", "changed_fields" => %{"role" => "admin"}},
      %{"email" => "an@example.org"}
    ],
    "backup.downloaded" => [%{"filename" => "pairings-2026-09-12.db"}],
    "publishing.endpoint_changed" => [
      %{"changed_fields" => %{"endpoint" => [nil, "https://uitslagen.example.org"]}},
      %{"changed_fields" => %{"endpoint" => "https://uitslagen.example.org"}},
      %{}
    ],
    "publishing.public_base_changed" => [
      %{"changed_fields" => %{"public_base" => ["https://a.example.org", nil]}},
      %{"changed_fields" => %{"public_base" => "https://a.example.org"}},
      %{}
    ],
    "publishing.token_replaced" => [%{}],
    "publishing.token_cleared" => [%{}],
    "publishing.public_consent_given" => [
      %{"host" => "openresults.zerotwo.cloud", "operator" => "ZeroTwo", "register_again" => true},
      %{"host" => "openresults.zerotwo.cloud", "operator" => nil, "register_again" => true}
    ],
    "fide.sync_started" => [%{}]
  }

  # Every action code a `describe/2` clause matches on, read from the source
  # rather than listed a second time here - so the list cannot fall behind.
  defp described_codes do
    {_ast, codes} =
      @source
      |> File.read!()
      |> Code.string_to_quoted!()
      |> Macro.prewalk([], fn
        {:def, _, [{:describe, _, [code, _details]} | _]} = node, acc when is_binary(code) ->
          {node, [code | acc]}

        {:def, _, [{:when, _, [{:describe, _, [code, _details]} | _]} | _]} = node, acc
        when is_binary(code) ->
          {node, [code | acc]}

        node, acc ->
          {node, acc}
      end)

    codes |> Enum.uniq() |> Enum.sort()
  end

  defp render(locale, code, details) do
    Gettext.with_locale(PairingsEngineWeb.Gettext, locale, fn ->
      AuditLive.describe(code, details)
    end)
  end

  defp en(code, details), do: render("en", code, details)
  defp nl(code, details), do: render("nl", code, details)

  # The row's own data - names, labels, codes, recorded messages, and the
  # field names inside a diff - which reads the same in both languages and is
  # taken out before the words are compared.
  defp data_strings(map) when is_map(map) do
    Enum.flat_map(map, fn
      {"changed_fields", fields} when is_map(fields) -> nested_strings(fields)
      {_key, value} -> nested_strings(value)
    end)
  end

  defp nested_strings(v) when is_binary(v), do: [v]
  defp nested_strings(v) when is_list(v), do: Enum.flat_map(v, &nested_strings/1)

  defp nested_strings(v) when is_map(v),
    do: Enum.flat_map(v, fn {k, val} -> nested_strings(k) ++ nested_strings(val) end)

  defp nested_strings(_), do: []

  defp words(text, details) do
    stripped =
      details
      |> data_strings()
      |> Enum.reject(&(&1 == ""))
      |> Enum.sort_by(&String.length/1, :desc)
      |> Enum.reduce(text, fn data, acc ->
        String.replace(acc, ~r/(?<!\p{L})#{Regex.escape(data)}(?!\p{L})/u, " ")
      end)

    ~r/\p{L}+/u
    |> Regex.scan(stripped)
    |> List.flatten()
    |> MapSet.new(&String.downcase/1)
  end

  test "every action describe/2 has a sentence for has an entry here, and only those" do
    described = described_codes()

    # Guards the whole file: a traversal that matches nothing would make
    # every test below check an empty list.
    assert length(described) > 50

    assert described -- Map.keys(@entries) == [],
           """
           describe/2 has a clause for these actions and this test has no entry for them:

             #{inspect(described -- Map.keys(@entries))}

           Add representative details to @entries - one per sentence the clause can
           produce - so its Dutch is checked.
           """

    assert Map.keys(@entries) -- described == [],
           "@entries names actions describe/2 has no clause for: " <>
             inspect(Map.keys(@entries) -- described)
  end

  test "every sentence reads in Dutch, with no English left in it" do
    failures =
      for {code, variants} <- @entries, details <- variants, reduce: [] do
        failures ->
          english = en(code, details)
          dutch = nl(code, details)

          leftover =
            words(english, details)
            |> MapSet.intersection(words(dutch, details))
            |> MapSet.difference(MapSet.new(@shared))
            |> MapSet.to_list()

          problems =
            [
              english == dutch && "renders identically in both languages",
              leftover != [] && "the Dutch keeps English words #{inspect(leftover)}",
              english =~ ~r/%[{\[]/ && "the English leaves a placeholder unfilled",
              dutch =~ ~r/%[{\[]/ && "the Dutch leaves a placeholder unfilled"
            ]
            |> Enum.filter(& &1)

          if problems == [] do
            failures
          else
            [
              "#{code} #{inspect(details)}\n    #{Enum.join(problems, "; ")}\n" <>
                "    en: #{english}\n    nl: #{dutch}"
              | failures
            ]
          end
      end

    assert failures == [], Enum.join(Enum.reverse(failures), "\n\n")
  end

  test "counts take the singular at one and the plural above it, in both languages" do
    assert en("player.ratings_refreshed", %{"players_updated" => 1}) ==
             "Refreshed ratings for 1 player."

    assert en("player.ratings_refreshed", %{"players_updated" => 12}) ==
             "Refreshed ratings for 12 players."

    assert nl("player.ratings_refreshed", %{"players_updated" => 1}) ==
             "Ratings vernieuwd voor 1 speler."

    assert nl("player.ratings_refreshed", %{"players_updated" => 12}) ==
             "Ratings vernieuwd voor 12 spelers."

    assert nl("pairing.results_imported", %{"round" => 2, "results_set" => 1}) ==
             "1 resultaat geïmporteerd voor ronde 2 (CSV)."

    assert nl("pairing.results_imported", %{"round" => 2, "results_set" => 8}) ==
             "8 resultaten geïmporteerd voor ronde 2 (CSV)."

    one = %{"round" => 1, "board_count" => 1, "bye_count" => 1, "floater_count" => 1}
    many = %{"round" => 5, "board_count" => 12, "bye_count" => 2, "floater_count" => 3}

    assert en("pairing.round_paired", one) == "Paired round 1: 1 board, 1 bye, 1 floater."
    assert en("pairing.round_paired", many) == "Paired round 5: 12 boards, 2 byes, 3 floaters."
    assert nl("pairing.round_paired", one) == "Ronde 1 gepaard: 1 bord, 1 bye, 1 doorschuiver."

    assert nl("pairing.round_paired", many) ==
             "Ronde 5 gepaard: 12 borden, 2 byes, 3 doorschuivers."

    assert nl("standings.extra_points_applied", %{"matched" => 1, "total" => 1}) ==
             "Extra punten volgens Elo-schijven toegepast op 1 van 1 speler."

    assert nl("standings.extra_points_applied", %{"matched" => 6, "total" => 40}) ==
             "Extra punten volgens Elo-schijven toegepast op 6 van 40 spelers."

    assert nl("player.bulk_absent_set", %{"absent" => true, "player_count" => 1}) ==
             "Elke speler als afwezig gemarkeerd voor het hele toernooi (1 speler)."

    assert nl("player.bulk_absent_set", %{"absent" => true, "player_count" => 24}) ==
             "Elke speler als afwezig gemarkeerd voor het hele toernooi (24 spelers)."

    assert en("player.clubs_refreshed", %{"players_updated" => 1}) ==
             "Refreshed clubs for 1 player."

    assert nl("player.clubs_refreshed", %{"players_updated" => 5}) ==
             "Clubgegevens vernieuwd voor 5 spelers."

    assert nl("category.auto_assigned", %{"matched" => 1, "total" => 1}) ==
             "Categorieën volgens de regels toegekend aan 1 van 1 speler."

    assert nl("category.auto_assigned", %{"matched" => 18, "total" => 40}) ==
             "Categorieën volgens de regels toegekend aan 18 van 40 spelers."

    # The rounds left alone are counted across every reason they were skipped
    # for, and take their own singular or plural.
    assert en("pairing.account_recomputed", %{"recomputed" => 1, "skipped" => %{":current" => 1}}) ==
             "Recomputed the pairing rationale of 1 round from the boards as played. " <>
               "No pairing was changed. 1 other round was left unchanged."

    assert nl("pairing.account_recomputed", %{
             "recomputed" => 6,
             "skipped" => %{":current" => 2, ":hand_edited" => 1}
           }) ==
             "Paringsverantwoording van 6 rondes herberekend op basis van de borden zoals ze " <>
               "gespeeld zijn. Er is geen enkele paring gewijzigd. 3 andere rondes bleven ongewijzigd."
  end

  test "opposite acts read as opposites in Dutch" do
    assert nl("categories.toggled", %{"enabled" => true}) == "Categorieën ingeschakeld."
    assert nl("categories.toggled", %{"enabled" => false}) == "Categorieën uitgeschakeld."
    assert nl("registration.toggled", %{"open" => true}) =~ "geopend"
    assert nl("registration.toggled", %{"open" => false}) =~ "gesloten"
    assert nl("registration.accepted", %{"player_name" => "Bram"}) =~ "aanvaard"
    assert nl("registration.discarded", %{"player_name" => "Bram"}) =~ "verworpen"

    assert nl("standings.manual_reorder", %{"player_name" => "Bram", "direction" => "up"}) =~
             "omhoog"

    assert nl("standings.manual_reorder", %{"player_name" => "Bram", "direction" => "down"}) =~
             "omlaag"

    assert nl("tournament.archived", %{"name" => "X"}) =~ "alleen-lezen"
    assert nl("tournament.unarchived", %{"name" => "X"}) =~ "weer bewerkt"

    assert nl("pairing.hidden", %{"round" => 3, "board" => 12}) ==
             "Leeg bord 12 van ronde 3 verborgen in de paringen."

    assert nl("pairing.unhidden", %{"round" => 3, "board" => 12}) ==
             "Leeg bord 12 van ronde 3 weer getoond in de paringen."

    assert nl("openresults.toggled", %{"enabled" => true}) =~ "ingeschakeld"
    assert nl("openresults.toggled", %{"enabled" => false}) =~ "uitgeschakeld"
    assert nl("openresults.listed", %{"listed" => true}) =~ "op de voorpagina"
    assert nl("openresults.listed", %{"listed" => false}) =~ "van de voorpagina"
    assert nl("player.bulk_absent_set", %{"absent" => false, "player_count" => 2}) =~ "aanwezig"

    assert nl("player.bulk_category_set", %{"category" => "U12", "added" => true}) =~
             "toegevoegd"

    assert nl("player.bulk_category_set", %{"category" => "U12", "added" => false}) =~
             "verwijderd"
  end

  test "publishing and taking down read as opposites, and say how far public standings go" do
    assert nl("pairing.pairings_published", %{"through_round" => 4}) ==
             "Paringen gepubliceerd tot en met ronde 4."

    # Taking round 4's pairings down takes every later round with it and caps
    # the standings a remaining sheet can imply.
    assert en("pairing.pairings_unpublished", %{"from_round" => 4}) ==
             "Took the pairings of round 4 and every later round off the public page. " <>
               "Public standings now go no further than after round 3."

    assert nl("pairing.pairings_unpublished", %{"from_round" => 4}) ==
             "Paringen van ronde 4 en elke latere ronde van de publieke pagina gehaald. " <>
               "De publieke stand gaat nu niet verder dan na ronde 3."

    refute nl("pairing.pairings_unpublished", %{"from_round" => 4}) =~ "gepubliceerd"

    assert en("pairing.pairings_unpublished", %{"from_round" => 1}) ==
             "Took the pairings of every round off the public page. " <>
               "Public standings now go no further than the initial standings."

    assert nl("standings.published", %{"through_round" => 3}) == "Stand na ronde 3 gepubliceerd."

    assert en("standings.unpublished", %{"from_round" => 3}) ==
             "Took the standings after round 3 and every later round off the public page, " <>
               "together with any public pairings of later rounds. " <>
               "Public standings now go no further than after round 2."

    refute nl("standings.unpublished", %{"from_round" => 3}) =~ "gepubliceerd"
  end

  test "round 0 is the initial standings, never \"after round 0\"" do
    assert en("standings.published", %{"through_round" => 0}) ==
             "Published the initial standings."

    assert nl("standings.published", %{"through_round" => 0}) == "Beginstand gepubliceerd."

    assert en("standings.unpublished", %{"from_round" => 0}) ==
             "Took the initial standings off the public page, together with any public pairings. " <>
               "No standings are public now."

    assert nl("standings.unpublished", %{"from_round" => 0}) ==
             "Beginstand van de publieke pagina gehaald, samen met eventuele publieke paringen. " <>
               "Er is nu geen enkele stand publiek."

    # Taking standings after round 1 down leaves the initial standings as the
    # ceiling - the one place round 0 appears as the round before.
    assert nl("standings.unpublished", %{"from_round" => 1}) =~
             "De publieke stand gaat nu niet verder dan de beginstand."

    for code <- ~w(standings.published standings.unpublished pairing.pairings_unpublished),
        round <- [0, 1],
        details <- [%{"through_round" => round}, %{"from_round" => round}] do
      refute en(code, details) =~ "round 0"
      refute nl(code, details) =~ "ronde 0"
    end
  end

  test "the four hand-off steps read as four different acts in Dutch" do
    handed = nl("handoff.handed_off", %{"to" => "Laptop zaal B", "name" => "Paasopen"})
    returned = nl("handoff.returned", %{"to" => "clublaptop", "name" => "Paasopen"})
    received = nl("handoff.received", %{"from" => "clublaptop", "name" => "Paasopen"})
    released = nl("handoff.released", %{"from" => "Laptop zaal B", "name" => "Paasopen"})

    assert handed =~ "Paasopen overgedragen aan Laptop zaal B."
    assert returned =~ "Paasopen teruggegeven aan clublaptop."
    assert received =~ "Paasopen ontvangen als overdracht van clublaptop."
    assert released =~ "Paasopen teruggehaald van Laptop zaal B"

    # Read-only on the two that send it away; in use on the two that take it
    # in - the fact somebody reconstructing two diverging copies needs first.
    assert handed =~ "alleen-lezen"
    assert returned =~ "alleen-lezen"
    refute received =~ "alleen-lezen"
    refute released =~ "alleen-lezen"
    assert received =~ "in gebruik"
    assert released =~ "weer bewerkt"
  end

  test "a hand edit of a paired round says what kind of edit, and quotes the line it recorded" do
    # `summary` is the confirmation's own subtitle, an English sentence built
    # from the names at the time. It is the only record of who moved, so it is
    # kept - quoted, after a sentence in the reader's language, never inside
    # one.
    row = %{"round" => 3, "summary" => "Chris Maes takes Bram Claes's place"}

    assert en("pairing.player_substituted", row) ==
             "Edited round 3 by hand: replaced a seated player with one who was not playing. " <>
               ~s(Recorded as "Chris Maes takes Bram Claes's place".)

    assert nl("pairing.player_substituted", row) ==
             "Ronde 3 handmatig aangepast: een speler aan een bord vervangen door een speler " <>
               ~s(die niet speelde. Vastgelegd als "Chris Maes takes Bram Claes's place".)

    # No summary, no empty quote.
    assert nl("pairing.deleted", %{"round" => 3}) ==
             "Ronde 3 handmatig aangepast: een leeg bord verwijderd."

    assert en("pairing.deleted", %{"round" => 3, "summary" => ""}) ==
             "Edited round 3 by hand: deleted an empty board."
  end

  test "a value that is a word goes through its own msgid, not into the sentence as English" do
    # On/off, as the settings screens say it.
    assert nl("tournament.locked_field_changed", %{
             "field" => "pair_by_category",
             "from" => false,
             "to" => true
           }) == "Vergrendeling na ronde 1 doorbroken voor pair_by_category: Uit → Aan."

    # A role, as the Admin page names it.
    assert nl("admin.role_changed", %{
             "email" => "an@example.org",
             "changed_fields" => %{"role" => ["owner", "admin"]}
           }) == "Rol van an@example.org gewijzigd van Accounthouder naar Beheerder."

    # The field name and the engine names are identifiers and stay as stored.
    assert nl("tournament.locked_field_changed", %{
             "field" => "pairing_engine",
             "from" => "javafo",
             "to" => "ainalrami"
           }) == "Vergrendeling na ronde 1 doorbroken voor pairing_engine: javafo → ainalrami."
  end

  describe "rows in the shapes older versions wrote" do
    test "a result blanked before result_cleared existed reads as a clear, not a change to nothing" do
      # Until 2026-08-03 clearing a board was logged as `pairing.result_changed`
      # with `to: ""`.
      old = %{
        "round" => 2,
        "board" => 4,
        "white" => "Anna Peeters",
        "black" => "Bram Claes",
        "from" => "1-0",
        "to" => ""
      }

      assert en("pairing.result_changed", old) ==
               "Cleared the result on board 4 (round 2) (was 1-0): Anna Peeters vs Bram Claes."

      assert nl("pairing.result_changed", old) ==
               "Resultaat op bord 4 (ronde 2) gewist (was 1-0): Anna Peeters tegen Bram Claes."
    end

    test "a phone result from before access levels were recorded names the phone and claims no level" do
      old = %{
        "round" => 2,
        "board" => 4,
        "white" => "Anna Peeters",
        "black" => "Bram Claes",
        "to" => "1-0",
        "via" => "mobile",
        "enrollment_id" => 5,
        "enrollment_code" => "12345678",
        "enrollment_label" => "Board 3 tablet"
      }

      assert en("pairing.result_entered", old) ==
               "Entered result 1-0 on board 4 (round 2): Anna Peeters vs Bram Claes. " <>
                 ~s(Via the phone "Board 3 tablet".)

      assert nl("pairing.result_entered", old) ==
               "Resultaat 1-0 ingevoerd op bord 4 (ronde 2): Anna Peeters tegen Bram Claes. " <>
                 ~s(Via de telefoon "Board 3 tablet".)

      # The level, when it was recorded, is the label the Live round page
      # gives it.
      assert nl("pairing.result_entered", Map.put(old, "enrollment_level", "deputy")) =~
               ~s[Via de telefoon "Board 3 tablet" (Deputy).]
    end

    test "a restore point whose name was stored in English is quoted as a name inside the Dutch sentence" do
      # The summary the app wrote when it took the point itself. It was a
      # finished English string in the row from the moment it was written.
      row = %{"snapshot_id" => 9, "restored_to" => "Before unpairing round 3"}

      assert nl("snapshot.restored", row) ==
               ~s(Toernooi teruggezet naar het herstelpunt "Before unpairing round 3". ) <>
                 "De toestand van daarvoor is eerst bewaard."
    end

    test "a public-display save from before tie-breaks could be hidden says nothing about tie-breaks" do
      # `hidden_tiebreaks` was added to the row on 2026-08-30. A save without
      # it did not touch the tie-break list, so "Nothing is hidden" or a
      # tie-break sentence would both be claims the row cannot back.
      assert en("openresults.display", %{"hidden" => ["dates"]}) ==
               "Changed what the public page shows. Hidden: dates."

      assert nl("openresults.display", %{"hidden" => ["dates"]}) ==
               "Weergave van de publieke pagina gewijzigd. Verborgen: dates."

      # Today's shape, for contrast: the keys and codes stay as stored.
      assert nl("openresults.display", %{"hidden" => [], "hidden_tiebreaks" => ["BH", "SB"]}) ==
               "Weergave van de publieke pagina gewijzigd. Verborgen tiebreaks: BH, SB."
    end

    test "0.59.0's starting-rank switch, which nothing emits any more, still reads as a sentence" do
      assert en("standings.starting_rank_toggled", %{"enabled" => false}) ==
               "Turned off publishing the starting rank before round 1."

      assert nl("standings.starting_rank_toggled", %{"enabled" => true}) ==
               "Publiceren van de startranglijst vóór ronde 1 ingeschakeld."
    end

    test "a SWAR failure keeps the message it recorded, after a Dutch sentence naming the step" do
      row = %{"step" => "upload", "error" => "nothing has been uploaded yet"}

      assert nl("swar.publish_failed", row) ==
               "Kon de SWAR-resultatenpagina niet uploaden naar de uitslagensite van de federatie: " <>
                 "nothing has been uploaded yet"
    end

    test "a settings diff holding a list or a map renders instead of raising" do
      # `to_string/1` on the officials map raised Protocol.UndefinedError and
      # took the whole page down; a tie-break list rendered as "BHSB".
      row = %{
        "changed_fields" => %{
          "officials" => [%{}, %{"chief_arbiter" => %{"name" => "Dirk Jacobs"}}],
          "tiebreaks" => [["BH"], ["BH", "SB"]]
        }
      }

      for locale <- ["en", "nl"] do
        text = render(locale, "tournament.settings_updated", row)
        assert text =~ "tiebreaks BH → BH, SB"
        assert text =~ "Dirk Jacobs"
      end
    end

    test "every action survives details that are empty, missing or the wrong shape, in both languages" do
      odd = %{
        "round" => "3",
        "board_count" => "x",
        "bye_count" => nil,
        "changed_fields" => [],
        "allocated_bye" => "someone",
        "label" => 42,
        "restored_to" => %{},
        "player_name" => nil,
        "enrollment_label" => 7,
        "direction" => :sideways
      }

      for code <- described_codes(), details <- [%{}, nil, odd], locale <- ["en", "nl"] do
        text = render(locale, code, details)
        assert is_binary(text) and text != "", "#{code} rendered nothing for #{inspect(details)}"
        refute text =~ ~r/%[{\[]/, "#{code} left a placeholder: #{text}"
      end

      assert nl("player.deleted", %{}) == "Speler (naamloos) verwijderd."
    end
  end

  test "an action with no sentence shows its code, which is an identifier in every language" do
    # A code from a newer version, read by this one - a restored backup, or
    # a row that arrived on a hand-off.
    assert en("pairing.board_renumbered", %{"round" => 2}) == "pairing.board_renumbered"
    assert nl("pairing.board_renumbered", %{"round" => 2}) == "pairing.board_renumbered"
  end

  describe "the other direction: every recorded code has a sentence" do
    # Everything above starts from `describe/2` and asks whether its Dutch is
    # any good. None of it asks the opposite question: a new `Audit.log/4` or
    # `Audit.log_system/3` call site with no `describe/2` clause at all just
    # shows its bare code on the page, in every language, and nothing above
    # would notice - that is how 35 codes went without a sentence until
    # 2026-09-13. `PairingsEngine.AuditActionCodes` (test/support, shared with
    # the category-filter guard in `audit_live_test.exs`) walks every
    # `Audit.log`/`Audit.log_system` call site under `lib/` via
    # `Code.string_to_quoted!/1` and works out which codes the app can write
    # today; these two tests close the gap.

    test "AuditActionCodes' documented non-literal call sites are exactly the ones parsing finds" do
      # Most call sites pass the action as a string literal, read straight off
      # the AST. A handful build it from a variable, a module attribute or a
      # helper function - `@non_literal_call_sites` in AuditActionCodes lists
      # those by hand, because working out what a variable can hold means
      # reading the call site, not parsing it. This is what keeps that list
      # honest: a new non-literal call site (or a literal one going dynamic)
      # changes what parsing finds, and this fails until the list is updated.
      found = AuditActionCodes.found_non_literal_sites()
      documented = AuditActionCodes.documented_non_literal_sites()

      assert found == documented, """
      test/support/audit_action_codes.ex's @non_literal_call_sites no longer \
      matches what parsing finds under lib/.

      Found but undocumented (add an entry, with the codes it can write):
        #{inspect(found -- documented)}

      Documented but not found any more (its action is a literal now, or the \
      call site is gone - remove the entry):
        #{inspect(documented -- found)}
      """
    end

    test "every action code a current Audit.log/Audit.log_system call site can write has a describe/2 clause" do
      recorded = MapSet.new(AuditActionCodes.recorded_codes())
      described = MapSet.new(described_codes())

      missing = recorded |> MapSet.difference(described) |> Enum.sort()

      assert missing == [], """
      These action codes are written by a current Audit.log/4 or \
      Audit.log_system/3 call site under lib/, but describe/2 (in \
      lib/pairings_engine_web/live/audit_live.ex) has no clause for them - an \
      arbiter would see the bare code on the Audit page instead of a \
      sentence. Add the clause, and its row in @entries above, in the same \
      change as the call site:

        #{inspect(missing)}
      """
    end
  end
end
