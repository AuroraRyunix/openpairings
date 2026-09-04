defmodule PairingsEngine.Federations.BEL.SwarPublish do
  @moduledoc """
  Writes a SWAR-compatible HTML results page for a tournament - the same
  document shape the Belgian federation's own SWAR program produces and
  the federation's results site (frbe-kbsb.be) expects to receive.

  ## What this generates, and what it deliberately does not

  A real SWAR export is one document built from several independent
  sections; the KBSB maintainer asked for exactly three of them, plus the
  document head:

    * `<head>` - the `<meta>` tags the results site reads to file the
      upload (tournament identity, dates, the `Version` string).
    * `<table id='Top' class='tableEnteteA'>` - the banner (name, club
      logo, organiser/arbiter/type/tempo/dates/tiebreak-systems block).
    * `<table class='tableClassement'>` - the final standings, with
      whichever tiebreak columns this tournament actually has configured.
    * `<table class='tableResultats' style='width:100%;'>`, one per round -
      board number, both players (with their incoming score and rating)
      and the result.

  Left out on purpose, per that scope: the player-card popups
  (`ficheTable`), the Berger/American cross table (`tableRondesFermees`,
  `id='Americaine'`) and `tableGrille`. Those three sections make up
  roughly half of a real file and none of the data behind them (a
  round-by-round mini crosstable per player, an American-tournament pool
  grid) is needed for what this exists to do. A standings-row name that
  would otherwise link to a skipped player card
  (`<a href='#jou_009'>...</a>` in a real file) is written as plain text
  instead - a link to an id this document never emits would be a dangling
  anchor, and the round tables below do the same for the same reason.
  Likewise `<table class='tableLiens'>` (the round/Fiches/Amerikaans
  Rooster jump-link bar right under the banner) is left out entirely
  rather than reproduced with two of its links pointing nowhere - it was
  not on the maintainer's list of three tables, and a "Kaarten" link to a
  section this file never has is worse than no jump bar at all. The
  standings table's own "Begin van de pagina" footer link and each round
  table's matching footer link stay, though - both point at `#Top`, which
  this document always has.

  ## Licensing - read this before touching SWAR's own source again

  SWAR is Georges Marchal's proprietary program (see the `Author` meta tag
  below - copied verbatim because the results site's own parser expects
  it, not as an attribution nicety). `Html.cpp` in a real SWAR install was
  read to understand the *shape* of its output - which meta tags exist,
  how the banner nests two tables, which CSS class goes on which cell -
  exactly the way one reads a file-format spec. Nothing here is a
  translation of that C++: every function below is original Elixir, built
  from OpenPairings' own data (`PairingsEngine.Standings`,
  `PairingsEngine.Tournaments`), and none of `Html.cpp`'s comments,
  variable names or control flow made it into this file. The handful of
  short, fixed strings this module DOES reproduce - the seven-character
  result tokens (`"1ff-0"`, `"  0-1ff"`...), the Dutch tiebreak
  abbreviations (`"OR"`, `"Koya"`, `"# Z"`...) - are the wire format
  itself, not expression: a results site parsing this file needs those
  exact tokens the same way a TRF16 reader needs `Rk`/`SNo` in the right
  columns, and reproducing a format's fixed vocabulary is not what
  copyright protects. See `PairingsEngine.Federations.BEL.SwarImport` and
  `SwarExport`'s moduledocs for the same house position on the `.swar`
  binary format.

  ## Judgment calls made without a second reference file to check them against

  The one real file this was built against (`docs/swar-import.md`'s
  sibling investigation, a KBSB club's actual published page) is a
  finished 19-round round-robin with no byes, no draws, and every game
  rated. Several cells below therefore rest on inference rather than a
  second data point:

    * **Bye rows.** Not a single one appears in the reference file, so
      `board_row/3`'s bye branch (blank board number, the player's own
      cells, a `Vrij` marker where `Res.` goes, and the opponent's three
      cells left blank) follows the same STRUCTURAL convention the
      reference uses elsewhere (`tdcb` for the special-case marker column,
      `&nbsp;` for a cell with nothing to show) rather than a proven byte
      sequence.
    * **The `OR` (Direct Encounter) tiebreak's dash.** The reference shows
      literal `-` for players SWAR judges "not usefully comparable" (no
      tie, or a tie the players never all played each other in) rather
      than a numeric `0`. `PairingsEngine.Standings.standings/2` stores
      both of those cases as the same `0.0` - there is no bit anywhere
      that distinguishes "genuinely tied at zero" from "not applicable".
      Reproducing SWAR's own grouping test exactly would mean duplicating
      `Standings`' own tie-detection logic here; instead `classement_row/4`
      treats a `0.0` "DE" value as the dash, which matches the reference in
      every case that file demonstrates and is wrong only in the genuinely
      rare case of a player who played their entire score-group and lost
      every one of those games outright.
    * **`MacGuid`/`MacSend`.** A real SWAR install stamps its host's
      network MAC address here - meaningless for a multi-tenant web app,
      and not something worth asking a server to introspect for a cosmetic
      federation-facing tag. `installation_pseudo_mac/0` generates one
      colon-separated pseudo-MAC ONCE per installation (stored in `meta`,
      same durability as `swar_guid`) and reuses it for both tags, which
      is the closest honest analogue: stable per machine, meaningless as
      an actual address.
    * **Non-round-robin tournament types.** The reference proves the exact
      Dutch phrase for `"roundrobin"` ("Enkelrondige Round Robin"). The
      other three of OpenPairings' own `Tournament.types/0` values have no
      reference example; `tournoi_type_label/1` gives each a plausible
      Dutch phrase built from the same vocabulary, clearly marked as
      unverified in its own comment.
    * **`Fede`.** SWAR's own field is "which Belgian regional body (or
      FIDE) is this homologated under", a distinction OpenPairings does
      not model - it has one boolean, `tournament.fide_homologated`. This
      writes `"FIDE"` when that is set and `"KBSB"` otherwise (this pack
      IS the KBSB pack), rather than inventing a value for a dimension
      that does not exist in this schema.

  ## The version string

  `<meta name='Version'>` is the one thing the maintainer asked to be a
  setting rather than a constant - the federation's public tournament list
  shows a "Vers" column built by extracting the `vX.YY` out of this exact
  string, so an installation gets to say what shows up there. Stored in
  the shared `meta` table via `PairingsEngine.Meta` (see that module for
  why it isn't yet another private `meta_get`/`meta_put` pair), defaulting
  to `"v7.00"` - see `version/0`/`put_version/1`.

  ## The GUID, and where the club prefix comes from

  `tournament.swar_guid` already exists (added for `.swar` round-trip
  detection - see `PairingsEngine.Tournaments.find_tournament_by_swar_guid/2`).
  If it is set, `ensure_guid!/1` uses it verbatim, so re-downloading this
  page for the same tournament keeps producing the same `Guid`/filename and
  a later upload overwrites the federation's copy instead of duplicating
  it. If it is blank, one is generated in the documented shape
  (`[ClubPrefix]-[YYMMDD]-[8 hex]-{[UUIDv4]}`) and persisted back onto the
  tournament, so every later download of the same tournament reuses it too.

  The club prefix is `tournament.organizer_club_number` - the "Organizer
  club nr / logo" field on the Tournament settings page, already the exact
  field `SwarExport` writes into a `.swar` file's `[TOURNOI]` section and
  the one `SwarImport` reads a `.swar` file's club/logo number back into.
  It is the only club-identifying number this schema has that isn't a
  PLAYER's club (which says nothing about who organized the event), and on
  the one reference file available it is exactly the number the file's own
  guid, logo filename (`351.jpg`) and upload path all agree on. Left
  blank when the arbiter hasn't filled that field in yet, rather than
  guessed at - a wrong club number is worse than an admittedly-incomplete
  one, since the federation server files an upload by it.
  """

  alias PairingsEngine.{Meta, PlayerStats, Standings, Tournaments}
  alias PairingsEngine.Tournaments.{Player, Tournament}

  use Gettext, backend: PairingsEngineWeb.Gettext

  @default_version "v7.00"

  # Where a real SWAR install's own asset hand-off points - the results
  # site pulls the stylesheet and every logo from here regardless of which
  # club's page it is. Reproduced because a page that pointed anywhere else
  # would not render the way the federation's own pages do; it is a shared
  # public asset location, not anything specific to one tournament.
  @logos_base "https://frbe-kbsb.be/sites/manager/Swar/Logos/"

  ## ================================================================
  ## Version setting
  ## ================================================================

  @doc "The `Version` meta content this installation stamps into every SWAR HTML export. Defaults to `\"v7.00\"`."
  def version do
    case Meta.get("bel_swar_version") do
      value when is_binary(value) and value != "" -> value
      _ -> @default_version
    end
  end

  @doc """
  Sets the `Version` meta content. Blank restores the default rather than
  storing an empty tag content - the same "blank clears" convention
  `PairingsEngine.Publishing.put_endpoint/1` uses.
  """
  def put_version(value) when is_binary(value) do
    case String.trim(value) do
      "" -> Meta.delete("bel_swar_version")
      trimmed -> Meta.put("bel_swar_version", trimmed)
    end
  end

  def put_version(nil), do: Meta.delete("bel_swar_version")

  ## ================================================================
  ## GUID
  ## ================================================================

  @doc """
  Returns `tournament` with a non-blank `swar_guid`, persisting a freshly
  generated one when it had none. Safe to call repeatedly - a tournament
  that already has a guid is returned unchanged (no write).

  Persisting can fail (an archived or handed-off tournament refuses
  writes - see `PairingsEngine.Tournaments.ensure_writable/1`); this still
  returns a tournament with a usable guid for THIS download either way,
  since refusing to export an old tournament over that would be a worse
  outcome than one download whose guid does not survive to the next one.
  """
  def ensure_guid!(%Tournament{swar_guid: guid} = tournament) when guid not in [nil, ""],
    do: tournament

  def ensure_guid!(%Tournament{} = tournament) do
    guid = generate_guid(tournament)

    case Tournaments.update_tournament(tournament, %{"swar_guid" => guid}) do
      {:ok, updated} -> updated
      {:error, _reason} -> %{tournament | swar_guid: guid}
    end
  end

  defp generate_guid(tournament) do
    prefix = tournament.organizer_club_number || ""
    hex = 4 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    "#{prefix}-#{guid_date(tournament)}-#{hex}-{#{Ecto.UUID.generate()}}"
  end

  # The tournament's START date, not today's.
  #
  # `GenerateGUID()` in SWAR's `TournoiReadWrite.cpp` reads it out of
  # `DateDebut` - `Mid(8, 2)` for the two-digit year, `Mid(3, 2)` for the
  # month, `Mid(0, 2)` for the day of a `DD/MM/YYYY` string - so a tournament
  # starting on 01/08/2026 is stamped `260801`, whenever the id happened to be
  # minted.
  #
  # It is frozen from then on, because the whole block is guarded by "only if
  # the guid is empty". The reference file proves it: its id says `250905`
  # while its `DateStart` meta says `01/08/2026` - that event was created with
  # a September 2025 start, the date moved later, and the id did not follow.
  # That is the behaviour to copy, not a discrepancy to fix: the id is what
  # the results site overwrites in place, so it must survive an edit to the
  # dates or a second upload would publish a second tournament.
  #
  # Falls back to today only when the tournament has no start date at all,
  # which the six digits still have to be filled with somehow.
  defp guid_date(%{start_date: date}) when is_binary(date) and date != "" do
    case Date.from_iso8601(date) do
      {:ok, d} -> Calendar.strftime(d, "%y%m%d")
      _ -> Calendar.strftime(Date.utc_today(), "%y%m%d")
    end
  end

  defp guid_date(_), do: Calendar.strftime(Date.utc_today(), "%y%m%d")

  ## ================================================================
  ## Public export
  ## ================================================================

  @doc """
  Builds the SWAR HTML results page for `tournament` (or its id) as a
  binary. Always ensures a `swar_guid` first - see `ensure_guid!/1`.
  """
  def export(%Tournament{} = tournament) do
    tournament = ensure_guid!(tournament)
    entries = Standings.standings(tournament)
    tiebreak_codes = Standings.effective_tiebreaks(tournament)

    head(tournament) <>
      "\n<body>\n<div align='center'>\n" <>
      banner(tournament) <>
      "\n" <>
      classement(entries, tiebreak_codes) <>
      "\n" <>
      results(tournament) <>
      "\n</div>\n</body>\n</html>\n"
  end

  def export(tournament_id) when is_integer(tournament_id),
    do: tournament_id |> Tournaments.get_tournament!() |> export()

  @doc "The filename convention a real SWAR install saves this document under: its own guid, verbatim, plus `.html`."
  def filename(%Tournament{} = tournament), do: "#{ensure_guid!(tournament).swar_guid}.html"

  def filename(tournament_id) when is_integer(tournament_id),
    do: tournament_id |> Tournaments.get_tournament!() |> filename()

  ## ================================================================
  ## <head>
  ## ================================================================

  defp head(tournament) do
    year = year_of(tournament.start_date)
    fede = federation_label(tournament)

    """
    <!DOCTYPE html>
    <html lang='#{locale()}'>
    <head>
    <meta charset='utf-8'>
    <meta name='Guid' content='#{esc(tournament.swar_guid)}'>
    <meta name='MacGuid' content='#{esc(installation_pseudo_mac())}'>
    <meta name='MacSend' content='#{esc(installation_pseudo_mac())}'>
    <meta name='Annee' content='#{esc(year)}'>
    <meta name='Fede' content='#{esc(fede)}'>
    <meta name='Organisateur' content='#{esc(tournament.organizer)}'>
    <meta name='Type' content='#{esc(standard_label(tournament.standard))}'>
    <meta name='Round' content='All'>
    <meta name='DateStart' content='#{esc(fmt_date_dmy(tournament.start_date))}'>
    <meta name='DateEnd' content='#{esc(fmt_date_dmy(tournament.end_date))}'>
    <meta name='Tournoi' content='#{esc(tournament.name)}'>
    <meta name='DateSend' content='#{esc(date_send())}'>
    <meta name='Version' content='#{esc(version())}'>
    <meta name='Cache-Control' content='no-cache, no-store , must-revalidate'>
    <meta name='Description' content='Classement des tournois échecs'>
    <meta name='Author' content='OpenPairings'>
    <meta name='Keywords' content='échecs,echecs,chess,jeux,game,belgique,belgium,forum'>
    <meta name='Keywords' content='liège,liege,666,elo,classement,tournoi,interclub'>
    <meta name='Keywords' content='Swar, kbsb,frbe,fefb,vsf,svdb,666'>
    <meta name='Robots' content='all'>
    <link rel='stylesheet' type='text/css' href='Logos/swarnew.css'>
    <link rel='stylesheet' type='text/css' href='#{@logos_base}/swarnew.css'>
    <title>#{esc(tournament.name)}</title>
    </head>
    """
  end

  defp locale, do: Gettext.get_locale(PairingsEngineWeb.Gettext)

  # `Description`, `Keywords` and `Robots` are the results site's own fixed
  # identification of what kind of file this is - not tournament data, and not
  # content OpenPairings authored. They are reproduced verbatim, in French,
  # exactly as every SWAR install writes them, whatever its own language.
  #
  # `Author` is NOT reproduced. SWAR writes "Georges Marchal" there, and this
  # file was not written by him: copying it would put another person's name on
  # output he had no hand in. The documented intake reads `Guid`, `MacGuid`,
  # `MacSend`, `Annee`, `Fede`, `Organisateur`, `Type`, `Round`, `DateStart`,
  # `DateEnd`, `Tournoi`, `DateSend` and `Version` - `Author` is not among
  # them, so nothing should depend on it. If a first upload ever proves
  # otherwise, that is worth knowing on its own before deciding what to do.
  #
  # `Version` is settable for the same reason in reverse: the federation's
  # public list shows the version it extracts from that string, so what
  # appears there is the operator's call, not ours.

  defp federation_label(%Tournament{fide_homologated: true}), do: "FIDE"
  defp federation_label(%Tournament{}), do: "KBSB"

  defp year_of(iso_date) when is_binary(iso_date) do
    case String.split(iso_date, "-") do
      [y, _m, _d] when byte_size(y) == 4 -> y
      _ -> to_string(Date.utc_today().year)
    end
  end

  defp year_of(_), do: to_string(Date.utc_today().year)

  defp date_send, do: Calendar.strftime(DateTime.utc_now(), "%Y/%m/%d %H:%M")

  # One pseudo-MAC per installation, generated once and kept in `meta` -
  # see the moduledoc's "Judgment calls" section for why this cannot be a
  # real hardware address here. The high nibble of the first byte is
  # forced to `2` (the "locally administered, unicast" bit pattern real
  # MACs use for non-hardware-assigned addresses) so this is never
  # mistaken for a real vendor-assigned one if it ever leaks somewhere.
  defp installation_pseudo_mac do
    case Meta.get("bel_swar_pseudo_mac") do
      value when is_binary(value) and value != "" ->
        value

      _ ->
        mac = generate_pseudo_mac()
        Meta.put("bel_swar_pseudo_mac", mac)
        mac
    end
  end

  defp generate_pseudo_mac do
    <<first, rest::binary-size(5)>> = :crypto.strong_rand_bytes(6)
    first = Bitwise.bor(Bitwise.band(first, 0xFE), 0x02)

    [first | :binary.bin_to_list(rest)]
    |> Enum.map_join(":", &(&1 |> Integer.to_string(16) |> String.pad_leading(2, "0")))
  end

  ## ================================================================
  ## tableEnteteA / tableEnteteB (banner)
  ## ================================================================

  defp banner(tournament) do
    logo =
      if blank?(tournament.organizer_club_number),
        do: "spacepic",
        else: tournament.organizer_club_number

    fede = federation_label(tournament)

    """
    <table id='Top' class='tableEnteteA'>
        <tr><th colspan='3'>
    <img src='#{@logos_base}SwarLogo.png' alt='SwarLogo' style='float:left;'>
    #{esc(tournament.name)}
    <img src='#{@logos_base}SwarLogo.png' alt='SwarLogo' style='float:right;'></th></tr>
        <tr><td class='tdimage'>
    <img src='#{@logos_base}#{esc(logo)}.jpg' height='80' alt='#{esc(logo)}'></td>
            <td><table class='tableEnteteB'>
    #{banner_rows(tournament)}
                </table>
            </td>
            <td class='tdimage'><img src='#{@logos_base}#{esc(fede)}.jpg' height='80' alt='#{esc(fede)}'></td>
        </tr>
    </table>
    """
  end

  defp banner_rows(tournament) do
    [
      banner_row(gettext("Organisator"), esc(tournament.organizer)),
      arbiter_row(tournament),
      banner_row(gettext("Toernooi"), toernooi_line(tournament)),
      banner_row(gettext("Speeltempo"), esc(tournament.rate_of_play)),
      banner_row(gettext("Datums"), dates_line(tournament)),
      tiebreak_row(tournament)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp banner_row(label, value_html),
    do:
      "              <tr><td class='tdli'>#{esc(label)}: </td><td class='tdlb'>#{value_html}</td></tr>"

  # Only shown when a chief arbiter is on record - mirrors the reference
  # (and SWAR's own source): an event with nobody down as arbiter yet
  # simply omits the row rather than showing an empty one.
  defp arbiter_row(%Tournament{chief_arbiter: chief}) when chief in [nil, ""], do: nil

  defp arbiter_row(tournament) do
    names =
      [tournament.chief_arbiter, tournament.deputy_arbiter]
      |> Enum.reject(&blank?/1)
      |> Enum.map_join(", ", &esc/1)

    banner_row(gettext("Arbiter"), names)
  end

  defp toernooi_line(tournament) do
    type = tournoi_type_label(tournament.type)
    standard = standard_label(tournament.standard)
    rounds = tournament.rounds_count || 0

    "#{esc(type)} #{esc(standard)} (#{rounds} #{esc(ngettext("Ronde", "Rondes", rounds))})"
  end

  # Confirmed against the reference for "roundrobin" only ("Enkelrondige
  # Round Robin"). The other three are this project's own best Dutch
  # phrasing, built from the same chess vocabulary, with no second file to
  # check them against - see the moduledoc.
  defp tournoi_type_label("roundrobin"), do: "Enkelrondige Round Robin"
  defp tournoi_type_label("swiss"), do: "Zwitsers systeem"
  defp tournoi_type_label("team-swiss"), do: "Landenwedstrijd Zwitsers systeem"
  defp tournoi_type_label("team-roundrobin"), do: "Landenwedstrijd Round Robin"
  defp tournoi_type_label(_), do: "Zwitsers systeem"

  # SWAR's own `Type` meta and this banner line both use the bare English
  # word ("Standard"/"Rapid"/"Blitz") rather than a Dutch translation - see
  # the reference's own `<meta name='Type' content='Standard'>`. Not run
  # through gettext for that reason: it is the wire format's own word, not
  # UI copy this project chose.
  defp standard_label("rapid"), do: "Rapid"
  defp standard_label("blitz"), do: "Blitz"
  defp standard_label(_), do: "Standard"

  defp dates_line(tournament) do
    gettext("van %{start} tot %{end}",
      start: fmt_date_dmy(tournament.start_date),
      end: fmt_date_dmy(tournament.end_date)
    )
    |> esc()
  end

  defp tiebreak_row(tournament) do
    case Standings.effective_tiebreaks(tournament) do
      [] ->
        nil

      codes ->
        banner_row(
          gettext("Scheidingssystemen"),
          Enum.map_join(codes, ", ", &esc(tiebreak_abbr(&1)))
        )
    end
  end

  ## ================================================================
  ## tableClassement (standings)
  ## ================================================================

  defp classement(entries, tiebreak_codes) do
    total_cols = 8 + length(tiebreak_codes)
    players_by_id = Map.new(entries, &{&1.player.id, &1.player})

    """
    <!-- CLASSEMENT -->
    <table class='tableClassement'>
        <tr><td colspan='#{total_cols}' class='other'>#{esc(gettext("Eindstand"))}</td></tr>
        <tr>
    <td class='tdrib'>#{esc(gettext("Cl."))}</td>
            <td class='tdlib'>#{esc(gettext("Aanw"))}</td>
            <td class='tdlib'>#{esc(gettext("Naam Voornaam"))}</td>
            <td class='tdlib'>#{esc(gettext("Geslacht"))}</td>
            <td class='tdrib'>#{esc(gettext("F-Elo"))}</td>
            <td class='tdrib'>#{esc(gettext("#Part."))}</td>
            <td class='tdrib'>#{esc(gettext("#Ptn"))}</td>
            <td class='tdrib'>#{esc(gettext("Perf"))}</td>
    #{Enum.map_join(tiebreak_codes, "\n", &"        <td class='tdrib'>#{esc(tiebreak_abbr(&1))}</td>")}
        </tr>
    #{Enum.map_join(entries, "\n", &classement_row(&1, tiebreak_codes, players_by_id))}
    <tr style='empty-cells: hide;'><td colspan='3'><a href='#Top'>#{esc(gettext("Begin van de pagina"))}</a></td><td colspan='#{total_cols - 3}'></td></tr>
    </table>
    """
  end

  defp classement_row(entry, tiebreak_codes, players_by_id) do
    player = entry.player
    played_games = Enum.filter(entry.games, & &1.played)

    opponent_ratings =
      played_games
      |> Enum.map(&Map.get(players_by_id, &1.opponent_id))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&Player.rating/1)

    wins = Enum.count(played_games, &(&1.outcome == :win))
    losses = Enum.count(played_games, &(&1.outcome == :loss))
    perf = PlayerStats.performance(opponent_ratings, wins, losses)

    """
    <tr class='#{if rem(entry.rank, 2) == 1, do: "odd", else: "even"}'>
            <td class='tdr'>#{entry.rank}</td>
            <td class='tdl'></td>
            <td class='tdlb'>#{player_name(player)}</td>
            <td class='tdl'>#{esc(sex_label(player.sex))}</td>
            <td class='tdr'>#{Player.rating(player)}</td>
            <td class='tdr'>#{length(played_games)}</td>
            <td class='tdrb'>#{fmt_points(entry.points)}</td>
            <td class='tdr'>#{perf || "-"}</td>
    #{Enum.map_join(tiebreak_codes, "\n", &tiebreak_cell(&1, entry))}
        </tr>\
    """
  end

  defp tiebreak_cell(code, entry) do
    value = Map.get(entry.tiebreaks, code, 0.0)
    "        <td class='tdr'>#{tiebreak_display(code, value)}</td>"
  end

  # See the moduledoc's "OR dash" note: a `0.0` "DE" value is displayed as
  # SWAR's own not-applicable dash rather than as the digit zero.
  defp tiebreak_display("DE", value) when value == 0.0, do: "-"
  defp tiebreak_display(_code, value), do: fmt_tb(value)

  defp player_name(player) do
    title = if blank?(player.title), do: "", else: "#{player.title} "
    esc(title <> player.name)
  end

  defp sex_label(sex) do
    case Player.sex_label(sex) do
      "" -> "-"
      label -> label
    end
  end

  ## ================================================================
  ## tableResultats (one per round)
  ## ================================================================

  defp results(tournament) do
    rounds =
      tournament.id
      |> Tournaments.list_rounds()
      |> Enum.map(&Tournaments.get_round(tournament.id, &1.number))
      |> Enum.reject(&(&1 == nil or &1.pairings == []))

    inner = Enum.map_join(rounds, "\n", &round_table(tournament, &1))

    "<!-- RESULTATS -->\n<table class='tableResultats'>\n#{inner}\n</table>\n"
  end

  defp round_table(tournament, round) do
    scores_before = Standings.player_scores_before_round(tournament, round.number)
    all_results? = Enum.all?(round.pairings, &(&1.result not in [nil, ""]))
    heading = if all_results?, do: gettext("Uitslagen"), else: gettext("Paringen")

    rows =
      round.pairings
      |> Enum.sort_by(& &1.board)
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {pairing, index} ->
        board_row(pairing, scores_before, index, tournament.bye_value)
      end)

    """
      <tr><td>
      <table class='tableResultats' style='width:100%;'>
      <tr id='Round#{round.number}'><td colspan='8' class='catego'>#{esc(gettext("Ronde"))} #{round.number} (#{esc(fmt_date_dmy(round.date))}) <span class='appariement'>#{esc(heading)}</span></td></tr>
    <tr class='trTitre'>
          <th class='tdrb'>#{esc(gettext("Bordnr."))}</th>
          <th class='tdlb'>#{esc(gettext("Naam Voornaam"))}</th>
          <th class='tdcb'>#{esc(gettext("Punten"))}</th>
          <th class='tdrb'>#{esc(gettext("Elo"))}</th>
          <th class='tdrb'>#{esc(gettext("Res."))}</th>
          <th class='tdlb'>#{esc(gettext("Naam Voornaam"))}</th>
          <th class='tdrb'>#{esc(gettext("Punten"))}</th>
          <th class='tdrb'>#{esc(gettext("Elo"))}</th>
    </tr>
    #{rows}
      <tr class='yell'><td colspan='8'><a href='#Top'>#{esc(gettext("Begin van de pagina"))}</a></td></tr>

    </table></td></tr>
    """
  end

  # A board with nobody on it at all.
  #
  # An arbiter can vacate a seat rather than delete the pairing - PairingsLive
  # hides a fully-vacated row for the same reason - so a round legitimately
  # carries pairings with one seat empty, or none. Reading `player.id` off the
  # nil that is there took the whole page down with a 500.
  defp board_row(%{white_player_id: nil, black_player_id: nil}, _scores_before, _index, _bye),
    do: nil

  # Only black is seated: the mirror of the bye below, with the player shown on
  # the side they actually sat.
  defp board_row(%{white_player_id: nil} = pairing, scores_before, index, bye) do
    seated_row(pairing.black_player, scores_before, index, bye)
  end

  defp board_row(%{black_player_id: nil} = pairing, scores_before, index, bye) do
    seated_row(pairing.white_player, scores_before, index, bye)
  end

  defp board_row(pairing, scores_before, index, _bye) do
    white = pairing.white_player
    black = pairing.black_player
    white_points = Map.get(scores_before, white.id, 0.0)
    black_points = Map.get(scores_before, black.id, 0.0)

    """
      <tr class='#{row_class(index)}'>
        <td class='tdr'> #{pairing.board}</td>
        <td class='tdl'>#{player_name(white)}</td>
        <td class='tdc'>#{fmt_points(white_points)}</td>
        <td class='tdr'>(#{Player.rating(white)})</td>
        <td class='tdResult'>#{esc(result_token(pairing.result))}</td>
        <td class='tdl'>#{player_name(black)}</td>
        <td class='tdr'>#{fmt_points(black_points)}</td>
        <td class='tdr'>(#{Player.rating(black)})</td>
      </tr>\
    """
  end

  # A board with one player on it, whichever side they sat.
  #
  # Shaped from a real published file rather than guessed: SWAR puts the
  # POINTS AWARDED in the result cell and the word in the opponent's name
  # cell, and the row is seven cells rather than the usual eight -
  #
  #   <td class='tdcb'>1</td><td class='tdlb'><i>Bye</i></td><td class='tdl'>&nbsp;</td>
  #
  # An earlier guess put the word in the result cell and left the opponent
  # blank, which read as a label floating in the wrong column. An absence is
  # the identical row with 0 and "Afwezig", so the same function writes both.
  defp seated_row(player, scores_before, index, bye) do
    points = Map.get(scores_before, player.id, 0.0)

    """
      <tr class='#{row_class(index)}'>
        <td class='tdr'>&nbsp;</td>
        <td class='tdl'>#{player_name(player)}</td>
        <td class='tdc'>#{fmt_points(points)}</td>
        <td class='tdr'>(#{Player.rating(player)})</td>
        <td class='tdcb'>#{esc(fmt_points(bye))}</td>
        <td class='tdlb'><i>#{esc(gettext("Bye"))}</i></td>
        <td class='tdl'>&nbsp;</td>
      </tr>\
    """
  end

  defp row_class(index), do: if(rem(index, 2) == 0, do: "odd", else: "even")

  # The two-sided result text this file format shows in a board's `Res.`
  # cell, derived from `PairingsEngine.Results.classify/1`'s
  # {white, black, played?, forfeit?} for each of this project's own
  # result codes. `"ff"` marks whichever side's point came from a forfeit
  # rather than a played game - both sides for a double forfeit, only the
  # winner's digit for a one-sided one; see the moduledoc for how that
  # rule was read off the reference file's `"1ff-0"` (win)/`"0-1ff"`
  # (loss) pair. A real SWAR file pads every one of these to a fixed
  # 7-character field (`"1ff-0  "`, `"  0-1  "`...) - not reproduced here;
  # nothing about the file format's MEANING depends on that padding, only
  # its historical fixed-width C rendering, so this writes the same text
  # trimmed.
  defp result_token(code) do
    case code do
      "1-0" -> "1-0"
      "1/2-1/2" -> "½-½"
      "0-1" -> "0-1"
      "1/2-0" -> "½-0"
      "0-1/2" -> "0-½"
      "1-0FF" -> "1ff-0"
      "0-1FF" -> "0-1ff"
      "0-0FF" -> "0ff-0ff"
      "0-0" -> "0-0"
      "1-0U" -> "1-0"
      "0-1U" -> "0-1"
      "1/2-1/2U" -> "½-½"
      "+--" -> "1ff-0"
      "--+" -> "0-1ff"
      _ -> "-"
    end
  end

  ## ================================================================
  ## Shared formatting helpers
  ## ================================================================

  # Every SWAR abbreviation below is read off the SWAR Dutch language
  # file's `_ABR_*` strings (see the moduledoc's licensing note - these are
  # the wire format's own short column headers, not prose). Only DE, WIN,
  # SB, KS and BPG are proven against the reference file's actual "OR,
  # #Win, SB, Koya, # Z" header row; the rest follow the same source but
  # have no tournament in the reference to confirm them against. Anything
  # this table has no SWAR analogue for (WON, and the team-only breaks this
  # installation cannot even compute - see `PairingsEngine.Tiebreaks`)
  # falls back to its own FIDE code, which is at least never wrong about
  # what it means.
  @tiebreak_abbr %{
    "BH" => "Buch",
    "BHC1" => "B Cut1",
    "BHC2" => "B Cut2",
    # SWAR's "Median 2" (drop both the highest- and lowest-scoring
    # opponent) is the closer match to this catalogue's MBH than "Median
    # 1" - see the moduledoc.
    "MBH" => "B Med2",
    "SB" => "SB",
    "DE" => "OR",
    "WIN" => "#Win",
    "PS" => "Vsch.",
    "KS" => "Koya",
    "ARO" => "ARO",
    "AROC1" => "AROct",
    "BPG" => "# Z"
  }

  defp tiebreak_abbr(code), do: Map.get(@tiebreak_abbr, code, code)

  defp fmt_points(value) when is_float(value), do: Float.to_string(value)
  defp fmt_points(value) when is_integer(value), do: Float.to_string(value * 1.0)
  defp fmt_points(_), do: "0.0"

  # Same convention `PairingsEngineWeb.StandingsLive`'s own tiebreak column
  # already uses: a tiebreak value that is a whole number prints without a
  # decimal point (SWAR's own "#Win" column shows "17", not "17.0"); one
  # that isn't prints in full (its "SB" column shows "186.25"). Kept as its
  # own small copy rather than a shared call - the LiveView's version is
  # private to that module and this generator has no other reason to
  # depend on a `_web` module.
  defp fmt_tb(value) when is_float(value) do
    if value == Float.round(value, 0), do: to_string(trunc(value)), else: to_string(value)
  end

  defp fmt_tb(value), do: to_string(value)

  # `"2026-08-01"` -> `"01/08/2026"`. Falls back to the raw value (rather
  # than raising) for a date that isn't well-formed - a blank or malformed
  # date should show as itself, not take the whole export down with it.
  defp fmt_date_dmy(iso_date) when is_binary(iso_date) do
    case String.split(iso_date, "-") do
      [y, m, d] when byte_size(y) == 4 -> "#{d}/#{m}/#{y}"
      _ -> iso_date
    end
  end

  defp fmt_date_dmy(_), do: ""

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  defp esc(nil), do: ""

  defp esc(text) when is_binary(text) do
    text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
  end

  defp esc(other), do: other |> to_string() |> esc()
end
