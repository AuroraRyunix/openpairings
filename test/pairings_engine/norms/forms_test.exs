defmodule PairingsEngine.Norms.FormsTest do
  use ExUnit.Case, async: true

  alias PairingsEngine.Norms.{Forms, XlsxFill}
  alias PairingsEngine.Tournaments.{Tournament, Player}

  # ---------------------------------------------------------------------
  # fixtures (plain structs — no DB needed, the mappers are pure)
  # ---------------------------------------------------------------------

  defp tournament(overrides \\ %{}) do
    struct(
      %Tournament{
        name: "Test Open 2026",
        type: "swiss",
        federation: "BEL",
        venue: "Chess Hall",
        city: "Brussels",
        start_date: "2026-07-10",
        end_date: "2026-07-18",
        organizer: "Jane Organizer",
        chief_arbiter: "John Arbiter",
        time_control: "90 min + 30 sec/move",
        rounds_count: 9,
        standard: "standard",
        acceleration: "none",
        event_code: "BEL2026001",
        fide_tournament_id: "12345",
        officials: %{
          "organizer_id" => "999001",
          "organizer_email" => "organizer@example.com",
          "chief_arbiter_fide_id" => "888001",
          "chief_arbiter_email" => "arbiter@example.com",
          "deputy1_name" => "Deputy One",
          "deputy1_fide_id" => "777001",
          "swiss_variant" => "Dutch",
          "pairing_mode" => "computerized",
          "remark1" => "First remark"
        }
      },
      overrides
    )
  end

  defp player(overrides \\ %{}) do
    struct(
      %Player{
        name: "Doe, Jane",
        title: "",
        federation: "BEL",
        fide_id: 1_400_000,
        fide_rating: 2000,
        norm_data: %{}
      },
      overrides
    )
  end

  # ---------------------------------------------------------------------
  # IT3
  # ---------------------------------------------------------------------

  describe "it3_fills/2" do
    test "maps tournament identity, officials and pairing-system fields" do
      t = tournament()
      fills = Forms.it3_fills(t, [player()])["Invulformulier"]

      assert fills["B1"] == "BEL"
      assert fills["B2"] == 12_345
      assert fills["B3"] == "Test Open 2026"
      assert fills["B4"] == "BEL"
      assert fills["B5"] == "Chess Hall, Brussels"
      assert fills["B6"] == ~D[2026-07-10]
      assert fills["B7"] == ~D[2026-07-18]
      assert fills["B8"] == 999_001
      assert fills["B9"] == "Jane Organizer"
      assert fills["B10"] == "organizer@example.com"
      assert fills["B11"] == 9
      assert fills["B13"] == "90 min + 30 sec/move"
      assert fills["B14"] == "Standard"
      assert fills["B15"] == "Swiss"
      assert fills["B16"] == "Individual"
      assert fills["B17"] == "Dutch"
      assert fills["B18"] == "Normal"
      assert fills["B19"] == ""
      assert fills["B21"] == "X"
      assert fills["B22"] == "OpenPairings (With JaVaFo)"
      assert fills["B23"] == "First remark"
      assert fills["B59"] == 888_001
      assert fills["B60"] == "John Arbiter"
      assert fills["B61"] == "arbiter@example.com"
      assert fills["B62"] == 777_001
      assert fills["B63"] == "Deputy One"
    end

    test "marks manual pairing mode and blanks the computerized cell" do
      t = tournament(%{officials: %{"pairing_mode" => "manual"}})
      fills = Forms.it3_fills(t, [])["Invulformulier"]

      assert fills["B19"] == "X"
      assert fills["B21"] == ""
    end

    test "B22 defaults to Swar (With JaVaFo) when generated from the public Tools page" do
      fills = Forms.it3_fills(tournament(), [], :tools)["Invulformulier"]

      assert fills["B22"] == "Swar (With JaVaFo)"
    end

    test "B22 still honors an explicit pairing_program override on either source" do
      t = tournament(%{officials: %{"pairing_program" => "Custom Engine 1.0"}})

      assert Forms.it3_fills(t, [], :app)["Invulformulier"]["B22"] == "Custom Engine 1.0"
      assert Forms.it3_fills(t, [], :tools)["Invulformulier"]["B22"] == "Custom Engine 1.0"
    end

    test "team tournaments are labelled Team, not Individual" do
      t = tournament(%{type: "team-swiss"})
      fills = Forms.it3_fills(t, [])["Invulformulier"]

      assert fills["B16"] == "Team"
    end

    test "B13 prefers the structured rate_of_play over the free-text time_control" do
      t = tournament(%{rate_of_play: "90min/40moves+30min/end+30sec/move from move 1"})
      fills = Forms.it3_fills(t, [])["Invulformulier"]

      assert fills["B13"] == "90min/40moves+30min/end+30sec/move from move 1"
    end

    test "B13 falls back to time_control when rate_of_play is blank" do
      t = tournament(%{rate_of_play: ""})
      fills = Forms.it3_fills(t, [])["Invulformulier"]

      assert fills["B13"] == "90 min + 30 sec/move"
    end

    test "B12 derives the rounds-per-day schedule from round_dates, chunked by consecutive equal dates" do
      t =
        tournament(%{
          round_dates: [
            "2026-07-10",
            "2026-07-11",
            "2026-07-12",
            "2026-07-12",
            "2026-07-13",
            "2026-07-13",
            "2026-07-14"
          ]
        })

      fills = Forms.it3_fills(t, [])["Invulformulier"]

      assert fills["B12"] == "1-1-2-2-1"
    end

    test "B12 ignores blank round dates and is nil (left untouched) when there are none set" do
      t = tournament(%{round_dates: ["", "", ""]})
      fills = Forms.it3_fills(t, [])["Invulformulier"]

      assert fills["B12"] == nil
    end

    test "B12 treats a rescheduled date landing later in the round order as its own chunk" do
      t = tournament(%{round_dates: ["2026-07-10", "2026-07-10", "2026-07-11", "2026-07-10"]})
      fills = Forms.it3_fills(t, [])["Invulformulier"]

      assert fills["B12"] == "2-1-1"
    end

    test "computes rated/GM/IM/FM/unrated/WGM/WIM/WFM counts by federation" do
      players = [
        player(%{title: "GM", federation: "BEL", fide_rating: 2500}),
        player(%{title: "GM", federation: "NED", fide_rating: 2500}),
        player(%{title: "IM", federation: "BEL", fide_rating: 2400}),
        player(%{title: "", federation: "BEL", fide_rating: 0})
      ]

      t = tournament()
      fills = Forms.it3_fills(t, players)["Invulformulier"]

      # Rated total/feds/host (2 GM + 1 IM = 3 rated; feds BEL+NED = 2; host BEL = 2)
      assert fills["B27"] == 3
      assert fills["B28"] == 2
      assert fills["B29"] == 2

      # GM block: 2 total, 2 feds (BEL, NED), 1 host
      assert fills["B31"] == 2
      assert fills["B32"] == 2
      assert fills["B33"] == 1

      # IM block: 1 total, 1 fed, 1 host
      assert fills["B35"] == 1
      assert fills["B36"] == 1
      assert fills["B37"] == 1

      # Unrated block: 1 total, 1 fed, 1 host
      assert fills["B43"] == 1
      assert fills["B44"] == 1
      assert fills["B45"] == 1
    end

    test "never targets the template's formula cells or the unused orphan B70" do
      fills = Forms.it3_fills(tournament(), [])["Invulformulier"]

      refute Map.has_key?(fills, "B30")
      refute Map.has_key?(fills, "B34")
      refute Map.has_key?(fills, "B38")
      refute Map.has_key?(fills, "B42")
      refute Map.has_key?(fills, "B46")
      refute Map.has_key?(fills, "B50")
      refute Map.has_key?(fills, "B54")
      refute Map.has_key?(fills, "B58")
      refute Map.has_key?(fills, "B70")
    end

    test "produced fills apply cleanly to the real IT3 template" do
      fills = Forms.it3_fills(tournament(), [player(), player(%{title: "IM"})])
      assert {:ok, binary} = XlsxFill.fill(Forms.template_path(:it3), fills)
      assert is_binary(binary)
    end

    test "arbiters 1 and 2 land on the template's own spare rows (formerly '3rd/4th deputy')" do
      t =
        tournament(%{
          officials: %{
            "extra_arbiters_count" => 2,
            "arbiter1_name" => "Cornet, Luc",
            "arbiter1_fide_id" => "205494",
            "arbiter2_name" => "De Vet, Sylvin",
            "arbiter2_fide_id" => "214787"
          }
        })

      fills = Forms.it3_fills(t, [])["Invulformulier"]

      assert fills["B66"] == 205_494
      assert fills["B67"] == "CORNET, Luc"
      assert fills["B68"] == 214_787
      assert fills["B69"] == "DE VET, Sylvin"
    end

    test "arbiter 3 onward lands on the cells ItThreeExpand grew for them" do
      t =
        tournament(%{
          officials: %{
            "extra_arbiters_count" => 3,
            "arbiter3_name" => "Van Dyck, Marc",
            "arbiter3_fide_id" => "207640"
          }
        })

      fills = Forms.it3_fills(t, [])["Invulformulier"]

      assert fills["B70"] == 207_640
      assert fills["B71"] == "VAN DYCK, Marc"
    end

    test "no extra_arbiters_count means no extra-arbiter cells at all" do
      fills = Forms.it3_fills(tournament(), [])["Invulformulier"]

      refute Map.has_key?(fills, "B70")
      refute Map.has_key?(fills, "B71")
    end
  end

  describe "it3_result/3" do
    test "with no extra arbiters, fills the template unexpanded" do
      assert {:ok, binary} = Forms.it3_result(tournament(), [])
      assert is_binary(binary)
    end

    test "with 1-2 extra arbiters (the template's own spare rows), no expansion needed" do
      t =
        tournament(%{
          officials: %{
            "extra_arbiters_count" => 1,
            "arbiter1_name" => "Cornet, Luc",
            "arbiter1_fide_id" => "205494"
          }
        })

      assert {:ok, binary} = Forms.it3_result(t, [])
      {:ok, entries} = :zip.unzip(binary, [:memory])
      entries = Enum.map(entries, fn {n, b} -> {List.to_string(n), b} end)
      {_, invul} = List.keyfind(entries, "xl/worksheets/sheet2.xml", 0)

      assert invul =~ "205494"
      assert invul =~ "CORNET, Luc"
    end

    test "with 3+ extra arbiters, expands the template first and their data survives in the output" do
      t =
        tournament(%{
          officials: %{
            "extra_arbiters_count" => 3,
            "arbiter3_name" => "Van Dyck, Marc",
            "arbiter3_fide_id" => "207640"
          }
        })

      assert {:ok, binary} = Forms.it3_result(t, [])
      {:ok, entries} = :zip.unzip(binary, [:memory])
      entries = Enum.map(entries, fn {n, b} -> {List.to_string(n), b} end)
      {_, invul} = List.keyfind(entries, "xl/worksheets/sheet2.xml", 0)

      assert invul =~ "207640"
      assert invul =~ "VAN DYCK, Marc"
    end
  end

  # ---------------------------------------------------------------------
  # FA1 / IA1
  # ---------------------------------------------------------------------

  describe "fa1_fills/3 and ia1_fills/3" do
    @candidate %{
      "last_name" => "Smith",
      "first_name" => "Alice",
      "fide_id" => "1234567",
      "federation" => "NED"
    }

    test "maps the candidate, tournament identity and player-derived counts" do
      players = [
        player(%{fide_rating: 2000, federation: "BEL", title: "IM"}),
        player(%{fide_rating: 0, federation: "NED", title: ""})
      ]

      fills = Forms.fa1_fills(tournament(), players, @candidate)["Invulformulier"]

      # Surname in capitals is FIDE house style on these forms; the given name
      # keeps its own casing (see `Forms.fide_display_name/1`).
      assert fills["B1"] == "SMITH"
      assert fills["B2"] == "Alice"
      assert fills["B3"] == 1_234_567
      assert fills["B4"] == "NED"
      assert fills["B5"] == "BEL"
      assert fills["B6"] == "BEL2026001"
      assert fills["B7"] == "Test Open 2026"
      assert fills["B8"] == ~D[2026-07-10]
      assert fills["B9"] == ~D[2026-07-18]
      assert fills["B10"] == "Chess Hall, Brussels"
      assert fills["B11"] == "Swiss"
      assert fills["B12"] == 9
      assert fills["B13"] == 2
      assert fills["B14"] == 1
      assert fills["B15"] == 2
      assert fills["B16"] == 1
      assert fills["B18"] == "John Arbiter"
      assert fills["B20"] == "Chief Arbiter"
      assert fills["B21"] == "BEL"
      assert %Date{} = fills["B22"]
    end

    test "ia1_fills/3 has the identical cell layout" do
      assert Forms.fa1_fills(tournament(), [], @candidate) ==
               Forms.ia1_fills(tournament(), [], @candidate)
    end

    test "B18 puts the chief arbiter's name in FIDE house style, same as IT3's B60" do
      t = tournament(%{chief_arbiter: "Cornet, Luc"})
      fills = Forms.fa1_fills(t, [], @candidate)["Invulformulier"]

      assert fills["B18"] == "CORNET, Luc"
    end

    test "B17 prefers the structured rate_of_play over the free-text time_control" do
      t = tournament(%{rate_of_play: "90min/40moves+30min/end+30sec/move from move 1"})
      fills = Forms.fa1_fills(t, [], @candidate)["Invulformulier"]

      assert fills["B17"] == "90min/40moves+30min/end+30sec/move from move 1"
    end

    test "B17 falls back to time_control when rate_of_play is blank" do
      t = tournament(%{rate_of_play: ""})
      fills = Forms.fa1_fills(t, [], @candidate)["Invulformulier"]

      assert fills["B17"] == "90 min + 30 sec/move"
    end

    test "leaves B5/B21 nil when the tournament has no federation, preserving template defaults" do
      # XlsxFill.fill/2 treats a nil value as a no-op, so this leaves the
      # template's pre-filled Belgian-federation defaults untouched.
      fills = Forms.fa1_fills(tournament(%{federation: ""}), [], @candidate)["Invulformulier"]

      assert fills["B5"] == nil
      assert fills["B21"] == nil
    end

    test "never targets the signature fields or the Belgian delegate's pre-printed name/position" do
      fills = Forms.fa1_fills(tournament(), [], @candidate)["Invulformulier"]

      refute Map.has_key?(fills, "B19")
      refute Map.has_key?(fills, "B23")
      refute Map.has_key?(fills, "B24")
      refute Map.has_key?(fills, "B25")
    end

    test "fills both Date fields (B22, B26) with today's date" do
      fills = Forms.fa1_fills(tournament(), [], @candidate)["Invulformulier"]

      assert fills["B22"] == Date.utc_today()
      assert fills["B26"] == Date.utc_today()
    end

    test "produced fills apply cleanly to the real FA1 and IA1 templates" do
      fills = Forms.fa1_fills(tournament(), [player()], @candidate)
      assert {:ok, _} = XlsxFill.fill(Forms.template_path(:fa1), fills)

      fills2 = Forms.ia1_fills(tournament(), [player()], @candidate)
      assert {:ok, _} = XlsxFill.fill(Forms.template_path(:ia1), fills2)
    end
  end

  # ---------------------------------------------------------------------
  # IT4
  # ---------------------------------------------------------------------

  describe "it4_fills/2" do
    defp entry(player, points \\ 6.0),
      do: %{player: player, points: points, total: points, rank: 1}

    test "maps the header block from the tournament and officials" do
      t =
        tournament(%{
          officials:
            Map.put(tournament().officials, "pairings_web_link", "https://example.com/t/1")
        })

      fills = Forms.it4_fills(t, [])["IT 4"]

      assert fills["A4"] == "BEL"
      assert fills["F4"] == "Test Open 2026"
      assert fills["S4"] == "BEL2026001"
      assert fills["Y4"] == "https://example.com/t/1"
      assert fills["A6"] == "John Arbiter (888001)"
      assert fills["I6"] == "BEL, Chess Hall, Brussels"
      assert fills["V6"] == ~D[2026-07-10]
      assert fills["Z6"] == ~D[2026-07-18]
    end

    test "only includes players with a non-blank claimed title, starting at row 11" do
      candidate =
        player(%{
          name: "Norm Candidate",
          norm_data: %{"title_claimed" => "IM", "norm_description" => "IM norm"}
        })

      bystander = player(%{name: "Not A Candidate"})

      fills = Forms.it4_fills(tournament(), [entry(bystander), entry(candidate, 7.0)])["IT 4"]

      assert fills["C11"] == "Norm Candidate"
      assert fills["W11"] == "IM"
      assert fills["Y11"] == "IM norm"
      assert fills["T11"] == 7.0
      refute Map.has_key?(fills, "C12")
    end

    test "caps candidates at 40 rows" do
      candidates =
        for i <- 1..45 do
          player(%{name: "Candidate #{i}", norm_data: %{"title_claimed" => "CM"}})
          |> entry()
        end

      fills = Forms.it4_fills(tournament(), candidates)["IT 4"]

      assert Map.has_key?(fills, "C50")
      refute Map.has_key?(fills, "C51")
    end

    test "never targets the Z or AF verdict-formula columns" do
      candidate = player(%{norm_data: %{"title_claimed" => "GM"}})
      fills = Forms.it4_fills(tournament(), [entry(candidate)])["IT 4"]

      refute Enum.any?(Map.keys(fills), &String.starts_with?(&1, "Z1"))
      refute Enum.any?(Map.keys(fills), &String.starts_with?(&1, "AF1"))
    end

    test "produced fills apply cleanly to the real IT4 template" do
      candidate = player(%{norm_data: %{"title_claimed" => "WIM", "event_group" => "Women"}})
      fills = Forms.it4_fills(tournament(), [entry(candidate)])

      assert {:ok, _} = XlsxFill.fill(Forms.template_path(:it4), fills)
    end
  end

  describe "fide_display_name/1" do
    test "renders \"Last, First\" as \"LASTNAME, First\"" do
      assert Forms.fide_display_name("Burssens, Jorian") == "BURSSENS, Jorian"
      # Multi-word surnames are exactly why the comma decides the split
      # rather than word position.
      assert Forms.fide_display_name("De Vet, Sylvin") == "DE VET, Sylvin"
      assert Forms.fide_display_name("Van Dyck, Marc") == "VAN DYCK, Marc"
    end

    test "a name with no comma is left alone rather than guessed at" do
      assert Forms.fide_display_name("Madonna") == "Madonna"
      assert Forms.fide_display_name("Jorian Burssens") == "Jorian Burssens"
    end

    test "handles blanks and a trailing comma without raising" do
      assert Forms.fide_display_name("") == ""
      assert Forms.fide_display_name("Burssens,") == "BURSSENS"
      assert Forms.fide_display_name(nil) == ""
    end
  end

  describe "titled? — CM/WCM are not FIDE titles" do
    test "CM and WCM are excluded from the IT3 titled count" do
      players = [
        player(%{title: "GM"}),
        player(%{title: "IM"}),
        player(%{title: "CM"}),
        player(%{title: "WCM"}),
        player(%{title: ""})
      ]

      fills = Forms.fa1_fills(tournament(), players, @candidate)["Invulformulier"]

      # GM + IM only — CM/WCM are federation-awarded, not FIDE titles for the
      # purposes of this count.
      assert fills["B16"] == 2
    end
  end

  describe "official names on IT3 follow the same capitalisation" do
    test "chief arbiter and deputies are rendered LASTNAME, First" do
      t =
        tournament(%{
          chief_arbiter: "Cornet, Luc",
          officials: %{
            "chief_arbiter_fide_id" => "205494",
            "deputy1_name" => "De Vet, Sylvin",
            "deputy1_fide_id" => "214787"
          }
        })

      fills = Forms.it3_fills(t, [])["Invulformulier"]

      assert fills["B60"] == "CORNET, Luc"
      assert fills["B63"] == "DE VET, Sylvin"
    end

    test "an official stored without a comma is left as-is, not guessed at" do
      t = tournament(%{chief_arbiter: "Luc Cornet"})
      assert Forms.it3_fills(t, [])["Invulformulier"]["B60"] == "Luc Cornet"
    end
  end
end
