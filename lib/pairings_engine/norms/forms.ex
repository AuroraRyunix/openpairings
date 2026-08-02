defmodule PairingsEngine.Norms.Forms do
  @moduledoc """
  Pure mapper functions from `PairingsEngine.Tournaments.Tournament` /
  `PairingsEngine.Tournaments.Player` / `PairingsEngine.Standings` data onto
  the `fills` maps that `PairingsEngine.Norms.XlsxFill` expects, for each of
  the four official FIDE report templates in `priv/norm_templates/`:

    * **IT3** — Tournament Report Form (whole-tournament, always available)
    * **FA1** — FIDE Arbiter norm report (for one arbiter norm candidate)
    * **IA1** — International Arbiter norm report (same shape as FA1)
    * **IT4** — Title/Norm report (crosstable of up to 40 player candidates)

  Every function here is pure: given already-loaded data it returns a plain
  map, so these are unit-testable without a database. Callers (typically
  `PairingsEngineWeb.NormsController`) are responsible for loading the
  tournament/players/standings and then passing the resulting binary from
  `XlsxFill.fill/2` back to the client.

  Cell references were cross-checked against the fill map derived from the
  four template files — see `docs/norms.md` for the full reference and for
  how to update these mappers if FIDE revises a template.
  """

  alias PairingsEngine.Tournaments.Player

  @templates %{
    it3: "IT3-TournamentReportForm.xlsx",
    fa1: "FA1-norm.xlsx",
    ia1: "IA1-norm.xlsx",
    it4: "IT4.xlsx"
  }

  @doc "Absolute path to `kind`'s (`:it3` | `:fa1` | `:ia1` | `:it4`) template file."
  def template_path(kind) when is_map_key(@templates, kind) do
    Path.join(templates_dir(), Map.fetch!(@templates, kind))
  end

  @doc "Directory holding the read-only FIDE template files."
  def templates_dir, do: Path.join(:code.priv_dir(:pairings_engine), "norm_templates")

  @doc "A sensible download filename for `kind`, scoped to `tournament`."
  def download_filename(kind, tournament) do
    slug =
      tournament.name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    prefix = kind |> Atom.to_string() |> String.upcase()
    "#{prefix}-#{slug}.xlsx"
  end

  # ---------------------------------------------------------------------
  # IT3 — Tournament Report Form
  # ---------------------------------------------------------------------

  @doc """
  Fills for the IT3 "Invulformulier" sheet: tournament identity, officials,
  pairing-system metadata, and rated/titled player counts broken down by
  federation. `players` is the tournament's full player list (from
  `PairingsEngine.Tournaments.list_players/1`).

  `B12` ("Schedule (number of rounds/day)") is derived from
  `tournament.round_dates` (ISO date strings, index = round-1, blanks
  allowed) as a `-`-joined count of rounds per day, e.g. dates spanning 5
  distinct days with two double-round days becomes `"1-1-2-2-1"` — each
  chunk is a run of *consecutive* rounds sharing a date, in round order (not
  sorted), so a rescheduled date out of sequence still reads as its own
  chunk. Left nil (untouched) when every round date is blank.

  `B13` ("Rate(s) of play") prefers `tournament.rate_of_play` (the
  structured `standard`-scoped select on the Settings page) and falls back
  to the older free-text `tournament.time_control` field for tournaments
  that predate it.

  Never targets the formula cells `B30,B34,B38,B42,B46,B50,B54,B58` (each
  `=total-host` on the template) or the unused orphan `B70`.
  """
  def it3_fills(tournament, players) do
    o = officials(tournament)
    rated = rating_counts(players, tournament.federation)

    %{
      "Invulformulier" =>
        %{
          "B1" => blank(tournament.federation),
          "B2" => parse_int(tournament.fide_tournament_id),
          "B3" => blank(tournament.name),
          "B4" => blank(tournament.federation),
          "B5" => place(tournament),
          "B6" => parse_date(tournament.start_date),
          "B7" => parse_date(tournament.end_date),
          "B8" => parse_int(Map.get(o, "organizer_id")),
          "B9" => blank(tournament.organizer),
          "B10" => blank(Map.get(o, "organizer_email")),
          "B11" => tournament.rounds_count,
          "B12" => schedule_label(tournament.round_dates),
          "B13" => blank(tournament.rate_of_play) || blank(tournament.time_control),
          "B14" => standard_label(tournament.standard),
          "B15" => system_family_label(tournament.type),
          "B16" => individual_or_team_label(tournament.type),
          "B17" => swiss_variant_label(tournament, o),
          "B18" => acceleration_label(tournament.acceleration),
          "B19" => manual_mark(o),
          "B20" => blank(Map.get(o, "person_responsible_pairings")),
          "B21" => computerized_mark(o),
          "B22" => pairing_program(o),
          "B23" => blank(Map.get(o, "remark1")),
          "B24" => blank(Map.get(o, "remark2")),
          "B25" => blank(Map.get(o, "remark3")),
          "B26" => blank(Map.get(o, "remark4")),
          "B59" => parse_int(Map.get(o, "chief_arbiter_fide_id")),
          "B60" => blank(fide_display_name(tournament.chief_arbiter)),
          "B61" => blank(Map.get(o, "chief_arbiter_email")),
          "B62" => parse_int(Map.get(o, "deputy1_fide_id")),
          "B63" => blank(fide_display_name(Map.get(o, "deputy1_name"))),
          "B64" => parse_int(Map.get(o, "deputy2_fide_id")),
          "B65" => blank(fide_display_name(Map.get(o, "deputy2_name"))),
          "B66" => parse_int(Map.get(o, "deputy3_fide_id")),
          "B67" => blank(fide_display_name(Map.get(o, "deputy3_name"))),
          "B68" => parse_int(Map.get(o, "deputy4_fide_id")),
          "B69" => blank(fide_display_name(Map.get(o, "deputy4_name")))
        }
        |> Map.merge(counts_fills("B27", rated.rated))
        |> Map.merge(counts_fills("B31", rated.gm))
        |> Map.merge(counts_fills("B35", rated.im))
        |> Map.merge(counts_fills("B39", rated.fm))
        |> Map.merge(counts_fills("B43", rated.unrated))
        |> Map.merge(counts_fills("B47", rated.wgm))
        |> Map.merge(counts_fills("B51", rated.wim))
        |> Map.merge(counts_fills("B55", rated.wfm))
    }
  end

  # Fills the {total, feds, host} triple starting at `base_ref` (e.g. "B27"
  # -> B27 total, B28 feds, B29 host); the 4th cell of each block is always
  # the template's own `=total-host` formula and must stay untouched.
  defp counts_fills(base_ref, %{total: total, feds: feds, host: host}) do
    {col, row} =
      {String.first(base_ref), base_ref |> String.slice(1..-1//1) |> String.to_integer()}

    %{"#{col}#{row}" => total, "#{col}#{row + 1}" => feds, "#{col}#{row + 2}" => host}
  end

  defp rating_counts(players, host_federation) do
    rated = Enum.filter(players, &rated?/1)
    unrated = Enum.reject(players, &rated?/1)

    %{
      rated: category_counts(rated, host_federation),
      unrated: category_counts(unrated, host_federation),
      gm: category_counts(by_title(players, ["GM"]), host_federation),
      im: category_counts(by_title(players, ["IM"]), host_federation),
      fm: category_counts(by_title(players, ["FM"]), host_federation),
      wgm: category_counts(by_title(players, ["WGM"]), host_federation),
      wim: category_counts(by_title(players, ["WIM"]), host_federation),
      wfm: category_counts(by_title(players, ["WFM"]), host_federation)
    }
  end

  # See the `it3_fills/2` doc for the exact shape — grouped by *consecutive*
  # equal dates (in round order), not by sorted date, since the schedule is
  # meant to describe the tournament's actual day-by-day rhythm.
  defp schedule_label(round_dates) do
    case round_dates |> List.wrap() |> Enum.reject(&blank?/1) do
      [] -> nil
      dates -> dates |> Enum.chunk_by(& &1) |> Enum.map_join("-", &length/1)
    end
  end

  defp by_title(players, titles), do: Enum.filter(players, &(&1.title in titles))

  defp category_counts(list, host_federation) do
    %{
      total: length(list),
      feds:
        list |> Enum.map(& &1.federation) |> Enum.reject(&blank?/1) |> Enum.uniq() |> length(),
      host: Enum.count(list, &(&1.federation == host_federation and not blank?(host_federation)))
    }
  end

  # ---------------------------------------------------------------------
  # FA1 / IA1 — Arbiter norm report (identical cell layout)
  # ---------------------------------------------------------------------

  @doc """
  Fills for the FA1 "Invulformulier" sheet for one arbiter norm `candidate`
  (a plain string-keyed map with `"last_name"`, `"first_name"`, `"fide_id"`,
  `"federation"` — the candidate isn't necessarily a tournament `Player`, so
  it's passed in separately rather than looked up).

  Leaves `B5`/`B21` (federation of event / certifying federation) untouched
  (nil) when the tournament has no federation set, so the template's
  pre-filled Belgian-federation defaults survive; setting `tournament.federation`
  overrides them. Signature fields (`B19`, `B25`) and the Belgian
  authenticating official's block (`B23`, `B24`, `B26`) are intentionally
  never written — they're filled in by hand after export.
  """
  def fa1_fills(tournament, players, candidate),
    do: arbiter_norm_fills(tournament, players, candidate)

  @doc "Same cell layout as `fa1_fills/3` — see there for details."
  def ia1_fills(tournament, players, candidate),
    do: arbiter_norm_fills(tournament, players, candidate)

  defp arbiter_norm_fills(tournament, players, candidate) do
    %{
      "Invulformulier" => %{
        # Surname in capitals, FIDE house style (see `fide_display_name/1`).
        "B1" => blank(candidate |> cget("last_name") |> to_string() |> String.upcase()),
        "B2" => blank(cget(candidate, "first_name")),
        "B3" => parse_int(cget(candidate, "fide_id")),
        "B4" => blank(cget(candidate, "federation")),
        "B5" => blank(tournament.federation),
        "B6" => blank(tournament.event_code),
        "B7" => blank(tournament.name),
        "B8" => parse_date(tournament.start_date),
        "B9" => parse_date(tournament.end_date),
        "B10" => place(tournament),
        "B11" => system_label(tournament.type),
        "B12" => tournament.rounds_count,
        "B13" => length(players),
        "B14" => Enum.count(players, &rated?/1),
        "B15" => federations_represented(players),
        "B16" => Enum.count(players, &titled?/1),
        "B17" => blank(tournament.time_control),
        "B18" => blank(tournament.chief_arbiter),
        "B20" => "Chief Arbiter",
        "B21" => blank(tournament.federation),
        "B22" => Date.utc_today()
      }
    }
  end

  defp federations_represented(players) do
    players |> Enum.map(& &1.federation) |> Enum.reject(&blank?/1) |> Enum.uniq() |> length()
  end

  # ---------------------------------------------------------------------
  # IT4 — Title/Norm report (crosstable)
  # ---------------------------------------------------------------------

  @doc """
  Fills for the single `"IT 4"` sheet. `entries` are standings entries from
  `PairingsEngine.Standings.standings/1` (`%{player:, points:, ...}`);
  only entries whose player has a non-blank `norm_data["title_claimed"]`
  are included, capped at the template's 40-row limit (rows 11-50) — a
  tournament with more norm candidates needs a second IT4 file for the rest.

  Never targets `Z` or `AF` in any row (both live verdict formulas).
  """
  def it4_fills(tournament, entries) do
    candidates = entries |> Enum.filter(&it4_candidate?/1) |> Enum.take(40)

    row_fills =
      candidates
      |> Enum.with_index(11)
      |> Enum.map(fn {entry, row} -> it4_row_fills(entry, row) end)
      |> Enum.reduce(%{}, &Map.merge/2)

    %{"IT 4" => Map.merge(it4_header_fills(tournament), row_fills)}
  end

  defp it4_candidate?(%{player: player}), do: not blank?(norm_data(player)["title_claimed"])

  defp it4_header_fills(tournament) do
    o = officials(tournament)

    %{
      "A4" => blank(tournament.federation),
      "F4" => blank(tournament.name),
      "S4" => blank(tournament.event_code),
      "Y4" => blank(Map.get(o, "pairings_web_link")),
      "A6" => it4_chief_arbiter(tournament, o),
      "I6" => it4_country_place(tournament),
      "S6" => blank(Map.get(o, "it4_event_type")),
      "V6" => parse_date(tournament.start_date),
      "Z6" => parse_date(tournament.end_date)
    }
  end

  defp it4_row_fills(entry, row) do
    p = entry.player
    n = norm_data(p)

    %{
      "B#{row}" => blank(p.title),
      "C#{row}" => blank(fide_display_name(p.name)),
      "L#{row}" => blank(p.federation),
      "M#{row}" => p.fide_id,
      "N#{row}" => rating_or_nil(p),
      "P#{row}" => blank(n["event_group"]),
      "R#{row}" => parse_int(n["fed_participating"]),
      "S#{row}" => parse_int(n["fed_members"]),
      "T#{row}" => entry.points,
      "U#{row}" => blank(n["medal_percent"]),
      "W#{row}" => blank(n["title_claimed"]),
      "Y#{row}" => blank(n["norm_description"]),
      "AB#{row}" => blank(n["remarks"])
    }
  end

  defp rating_or_nil(player) do
    case Player.rating(player) do
      r when is_integer(r) and r > 0 -> r
      _ -> nil
    end
  end

  defp it4_chief_arbiter(tournament, o) do
    name = blank(tournament.chief_arbiter)
    id = blank(Map.get(o, "chief_arbiter_fide_id"))

    case {name, id} do
      {nil, nil} -> nil
      {name, nil} -> name
      {nil, id} -> "(#{id})"
      {name, id} -> "#{name} (#{id})"
    end
  end

  defp it4_country_place(tournament) do
    [tournament.federation, place(tournament)]
    |> Enum.reject(&blank?/1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, ", ")
    end
  end

  # ---------------------------------------------------------------------
  # shared helpers
  # ---------------------------------------------------------------------

  defp officials(%{officials: nil}), do: %{}
  defp officials(%{officials: officials}), do: officials

  defp norm_data(%{norm_data: nil}), do: %{}
  defp norm_data(%{norm_data: data}), do: data

  defp cget(candidate, key), do: Map.get(candidate || %{}, key)

  # FIDE's house style on these forms is the given name in normal case and the
  # surname in capitals — "Jorian BURSSENS" — which also removes the ambiguity
  # about which part is the surname for multi-word names ("De Vet", "Van
  # Dyck"). Our records store "Last, First", so the comma is what tells us
  # where to split; a name with no comma is left alone rather than guessed at.
  @doc false
  def fide_display_name(name) do
    case String.split(to_string(name), ",", parts: 2) do
      [last, first] ->
        [String.trim(first), String.upcase(String.trim(last))]
        |> Enum.reject(&(&1 == ""))
        |> Enum.join(" ")

      _ ->
        String.trim(to_string(name))
    end
  end

  defp rated?(%{fide_rating: r}), do: (r || 0) > 0

  @untitled_grades ~w(CM WCM)

  @doc """
  Whether a player counts as **titled** for FIDE reporting.

  CM and WCM do not: they're awarded by federations, not under the FIDE title
  regulations these counts refer to, so including them inflates the figure and
  makes the report disagree with FIDE's own view of the same tournament.

  Public because this is the single source of truth for that rule and more
  than one screen shows a "titled players" figure — `ToolsNormsLive`'s
  uploaded-file table had its own `Enum.count(players, &(&1.title != ""))`,
  which silently disagreed with the generated form the moment CM stopped
  counting. `PairingsEngine.Norms.TitleNorms` applies the same exclusion to
  titled-opponent ratios (see its `~w(GM IM WGM WIM FM WFM)` list).
  """
  def titled?(%{title: t}) do
    not blank?(t) and String.upcase(String.trim(to_string(t))) not in @untitled_grades
  end

  def titled?(_), do: false

  defp place(tournament) do
    [tournament.venue, tournament.city]
    |> Enum.reject(&blank?/1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, ", ")
    end
  end

  # The Settings page no longer offers a "Swiss variant" select (arbiters
  # always run the Dutch system for Swiss pairings, and there's no UI-level
  # variant to pick for other pairing systems) — so a blank
  # `officials["swiss_variant"]` (the common case going forward, though an
  # older tournament could still have one saved from before) now defaults
  # to "Dutch" for `pairing_system == "swiss"` tournaments, and stays blank
  # otherwise.
  defp swiss_variant_label(tournament, o) do
    case blank(Map.get(o, "swiss_variant")) do
      nil -> if tournament.pairing_system == "swiss", do: "Dutch", else: nil
      variant -> variant
    end
  end

  defp standard_label("standard"), do: "Standard"
  defp standard_label("rapid"), do: "Rapid"
  defp standard_label("blitz"), do: "Blitz"
  defp standard_label(_), do: nil

  defp system_family_label("swiss"), do: "Swiss"
  defp system_family_label("team-swiss"), do: "Swiss"
  defp system_family_label("roundrobin"), do: "Round Robin"
  defp system_family_label("team-roundrobin"), do: "Round Robin"
  defp system_family_label(_), do: nil

  defp individual_or_team_label("team-swiss"), do: "Team"
  defp individual_or_team_label("team-roundrobin"), do: "Team"
  defp individual_or_team_label(_), do: "Individual"

  defp acceleration_label("baku"), do: "Accelerated"
  defp acceleration_label(_), do: "Normal"

  # FA1/IA1 B11 dropdown, must match the template's validation list
  # (F2:F7 = Swiss / Round Robin / Double Round Robin / Team (League) /
  # Knockout / Others).
  defp system_label("swiss"), do: "Swiss"
  defp system_label("roundrobin"), do: "Round Robin"
  defp system_label("team-swiss"), do: "Team (League)"
  defp system_label("team-roundrobin"), do: "Team (League)"
  defp system_label(_), do: "Others"

  defp manual_mark(o), do: if(Map.get(o, "pairing_mode") == "manual", do: "X", else: "")

  defp computerized_mark(o), do: if(Map.get(o, "pairing_mode") == "manual", do: "", else: "X")

  defp pairing_program(o) do
    case Map.get(o, "pairing_mode") do
      "manual" -> ""
      _ -> blank(Map.get(o, "pairing_program")) || "OpenPairings"
    end
  end

  defp blank(nil), do: nil
  defp blank(""), do: nil
  defp blank(value), do: value

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  defp parse_int(nil), do: nil
  defp parse_int(""), do: nil
  defp parse_int(n) when is_integer(n), do: n
  defp parse_int(n) when is_float(n), do: trunc(n)

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(String.trim(s)) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_date(nil), do: nil
  defp parse_date(""), do: nil

  defp parse_date(s) when is_binary(s) do
    case Date.from_iso8601(s) do
      {:ok, date} -> date
      {:error, _} -> nil
    end
  end
end
