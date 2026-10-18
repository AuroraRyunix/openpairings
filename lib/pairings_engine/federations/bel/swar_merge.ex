defmodule PairingsEngine.Federations.BEL.SwarMerge do
  @moduledoc """
  Re-uploading a `.swar` file for a tournament that is already here: a
  field-by-field comparison of the file with the tournament, and the
  arbiter's choice of what to take from it - instead of a second copy.

  Two steps, like every other import that needs a human:

    * `review/2` reads the file through the import itself
      (`SwarImport.stage/2`: imported into a throwaway tournament, read
      back, rolled back) and compares that with the tournament as it is.
      Nothing is written.
    * `apply/3` writes what the arbiter chose, in one transaction, after a
      restore point (`Snapshots.capture/4`, pinned) of the tournament as it
      was. A tournament that changed since the review is refused: the
      comparison it was made from no longer describes it.

  What the review holds, and what the arbiter can do with each part:

    * **Settings** the file sets (the import's own attrs - a setting the
      file is silent on, like norms data or a manual ranking, is never
      compared, so it is never at risk). One choice for the section. A
      setting `Tournaments.locked_fields/1` locks - the ones that decide
      how rounds are paired, once a round is - is shown and never taken.
    * **Players**, matched on FIDE id, then national id, then name and
      year of birth. Changed details: one choice for the section. New
      players: add them or not. Players the file does not have are kept,
      always - they have games, or the arbiter added them here on purpose.
      Nobody is renumbered: a new player gets the next pairing number.
    * **Results and byes** in rounds both sides have: one choice per row. A
      result the file adds where this tournament has none defaults to the
      file's; a result that differs from one entered here defaults to
      keeping it. Nothing that exists here is overwritten unless the
      arbiter picks that row.
    * **Pairings** that differ in a round both sides have are shown and
      never changed: a round played here is not re-paired from a file.
    * **New rounds** - the file's rounds after this tournament's last one,
      without a gap - can be added, with the new players who play in them.
      Rounds this tournament has and the file does not are kept.
  """

  import Ecto.Query
  use Gettext, backend: PairingsEngineWeb.Gettext

  alias PairingsEngine.{Audit, Repo, ResultCorrections, Snapshots, Tournaments}
  alias PairingsEngine.Federations.BEL.SwarImport
  alias PairingsEngine.Tournaments.{Pairing, Player, Round, Tournament}

  # A player's details as the import writes them. Never the pairing number
  # (nobody is renumbered), the status or the start round (both this
  # tournament's own business).
  @player_fields ~w(name sex title fide_id fide_rating national_id national_rating federation
    birth_year birth_date club club_number paid affiliated absent forfeit fixed_board
    absent_rounds extra_points category categories)a

  # The settings the review shows first, in this order; any other setting
  # the file sets follows, alphabetically.
  @setting_order ~w(name city organizer organizer_club_number federation start_date end_date
    round_dates rounds_count chief_arbiter deputy_arbiter officials event_code rate_of_play
    standard fide_homologated fide_id_ranges tiebreaks bye_value abs_value abs_jusque abs_nbfois
    points_win points_draw points_loss presence_value presence_on_allocated_bye categories
    categories_enabled categories_ranked_separately pair_by_category swar_category_type
    swar_category_axis2 type pairing_system rr_cycles rr_match_format swiss_match_format
    initial_colour extra_points_mode extra_points_bands count_extra_points late_entry_absences)a

  # Same either way: the guid is how the two were found to be one event.
  @setting_skip [:swar_guid]

  @snapshot_trigger "import.swar_merge"

  ## ---------- review ----------

  @doc """
  Compares `prepared` (`SwarImport.prepare_import/2`) with `existing`.
  Returns `{:ok, review}` or `{:error, reason}` (`error_message/1`).

  The review is a plain map, kept by the caller between the two steps:
  `:settings`, `:player_changes`, `:new_players`, `:only_here_players`,
  `:results`, `:pairing_differences`, `:new_rounds`, `:only_here_rounds`
  and `:skipped_rounds` (file rounds that cannot be added: after a gap),
  plus what `apply/3` needs to write it.
  """
  def review(%Tournament{} = existing, prepared) do
    with :ok <- mergeable(existing),
         {:ok, file} <- SwarImport.stage(prepared, &read_file_side/2) do
      here = read_side(existing.id, file.setting_keys)
      {:ok, compare(existing, here, file)}
    end
  end

  defp read_file_side(%Tournament{id: id}, keys), do: read_side(id, keys)

  @doc """
  Whether `review` found nothing at all that differs.
  """
  def identical?(review) do
    review.settings == [] and review.player_changes == [] and review.new_players == [] and
      review.only_here_players == [] and review.results == [] and
      review.pairing_differences == [] and review.new_rounds == [] and
      review.only_here_rounds == [] and review.skipped_rounds == []
  end

  # A tournament as the comparison sees it, keyed by row id. Read the same
  # way for both sides - the file's side is the staged import - so whatever
  # differs is in the data, not in how it was read.
  defp read_side(tournament_id, setting_keys) do
    t = Repo.get!(Tournament, tournament_id)
    fields = Tournament.__schema__(:fields)
    keys = Enum.filter(setting_keys, &(&1 in fields and &1 not in @setting_skip))

    players =
      from(p in Player, where: p.tournament_id == ^tournament_id, order_by: p.pairing_number)
      |> Repo.all()
      |> Enum.map(fn p ->
        %{id: p.id, pairing_number: p.pairing_number, fields: Map.take(p, @player_fields)}
      end)

    rounds =
      from(r in Round,
        where: r.tournament_id == ^tournament_id,
        order_by: r.number,
        select: %{id: r.id, number: r.number, status: r.status, virtual_points: r.virtual_points}
      )
      |> Repo.all()

    boards =
      from(p in Pairing,
        join: r in Round,
        on: r.id == p.round_id,
        where: r.tournament_id == ^tournament_id,
        order_by: [r.number, p.board, p.id],
        select:
          {r.number,
           %{
             id: p.id,
             board: p.board,
             white: p.white_player_id,
             black: p.black_player_id,
             result: p.result
           }}
      )
      |> Repo.all()
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    byes =
      from(b in "byes",
        where: b.tournament_id == ^tournament_id,
        select: {b.round, b.player_id, b.type}
      )
      |> Repo.all()
      |> Enum.group_by(&elem(&1, 0), fn {_r, player, type} -> {player, type} end)

    %{
      setting_keys: setting_keys,
      settings: Map.new(keys, &{&1, Map.get(t, &1)}),
      swar_settings: t.swar_settings || %{},
      players: players,
      rounds:
        Map.new(rounds, fn r ->
          {r.number,
           %{
             status: r.status,
             virtual_points: r.virtual_points || %{},
             boards: Map.get(boards, r.number, []),
             byes: Map.new(Map.get(byes, r.number, []))
           }}
        end)
    }
  end

  defp compare(existing, here, file) do
    matches = match_players(here.players, file.players)
    here_by_id = Map.new(here.players, &{&1.id, &1})
    file_by_id = Map.new(file.players, &{&1.id, &1})
    name_here = fn id -> name_of(here_by_id, id) end
    # A file player by the name they have here when they are matched -
    # it is the name the arbiter knows them by.
    name_file = fn id ->
      case Map.get(matches, id) do
        nil -> name_of(file_by_id, id)
        here_id -> name_here.(here_id)
      end
    end

    here_max = here.rounds |> Map.keys() |> Enum.max(fn -> 0 end)
    {new_rounds, skipped_rounds} = new_rounds(file, here_max)

    {results, pairing_differences} =
      here.rounds
      |> Map.keys()
      |> Enum.filter(&Map.has_key?(file.rounds, &1))
      |> Enum.sort()
      |> Enum.reduce({[], []}, fn number, {results, diffs} ->
        {r, d} =
          compare_round(
            number,
            here.rounds[number],
            file.rounds[number],
            matches,
            name_here,
            name_file
          )

        {results ++ r, diffs ++ d}
      end)

    new_round_players =
      for number <- new_rounds,
          round = file.rounds[number],
          id <- round_player_ids(round),
          not Map.has_key?(matches, id),
          into: MapSet.new(),
          do: id

    %{
      tournament_id: existing.id,
      tournament_name: existing.name,
      fingerprint: :erlang.phash2(here),
      file: file,
      matches: matches,
      here_max: here_max,
      settings: setting_rows(existing, here, file),
      player_changes: player_changes(here_by_id, file.players, matches),
      new_players:
        for p <- file.players, not Map.has_key?(matches, p.id) do
          %{
            id: p.id,
            name: p.fields.name,
            fields: p.fields,
            in_new_rounds?: MapSet.member?(new_round_players, p.id)
          }
        end,
      only_here_players:
        (
          matched = matches |> Map.values() |> MapSet.new()

          for p <- here.players, not MapSet.member?(matched, p.id) do
            %{id: p.id, name: p.fields.name}
          end
        ),
      results: results,
      pairing_differences: pairing_differences,
      new_rounds:
        Enum.map(new_rounds, fn number ->
          round = file.rounds[number]

          %{
            number: number,
            boards: length(round.boards),
            results: Enum.count(round.boards, &(&1.result not in ["", nil]))
          }
        end),
      only_here_rounds: here.rounds |> Map.keys() |> Enum.reject(&Map.has_key?(file.rounds, &1)),
      skipped_rounds: skipped_rounds
    }
  end

  defp name_of(by_id, id) do
    case Map.get(by_id, id) do
      nil -> "?"
      p -> p.fields.name
    end
  end

  # The file's rounds after this tournament's last one, without a gap: a
  # round 6 cannot be added to a tournament that stops at 4 and has no 5.
  defp new_rounds(file, here_max) do
    later = file.rounds |> Map.keys() |> Enum.filter(&(&1 > here_max)) |> Enum.sort()

    {added, _next} =
      Enum.reduce_while(later, {[], here_max + 1}, fn number, {acc, next} ->
        if number == next, do: {:cont, {acc ++ [number], next + 1}}, else: {:halt, {acc, next}}
      end)

    {added, later -- added}
  end

  defp round_player_ids(round) do
    seated =
      Enum.flat_map(round.boards, &Enum.reject([&1.white, &1.black], fn id -> is_nil(id) end))

    seated ++ Map.keys(round.byes)
  end

  ## ---------- players ----------

  # File player id => player id here. FIDE id first, national id next, name
  # and year of birth last; each player here is taken once, and two ids
  # that both exist and disagree are never the same person.
  defp match_players(here_players, file_players) do
    passes = [
      fn p -> p.fields.fide_id end,
      fn p -> blank_to_nil(p.fields.national_id) end,
      fn p -> {name_key(p.fields.name), p.fields.birth_year} end
    ]

    {matches, _taken} =
      Enum.reduce(passes, {%{}, MapSet.new()}, fn key_fun, {matches, taken} ->
        index =
          here_players
          |> Enum.reject(&MapSet.member?(taken, &1.id))
          |> Enum.group_by(key_fun)

        Enum.reduce(file_players, {matches, taken}, fn f, {matches, taken} ->
          key = key_fun.(f)

          with false <- Map.has_key?(matches, f.id),
               true <- usable_key?(key),
               [h] <- index |> Map.get(key, []) |> Enum.reject(&MapSet.member?(taken, &1.id)),
               false <- ids_disagree?(h, f) do
            {Map.put(matches, f.id, h.id), MapSet.put(taken, h.id)}
          else
            _ -> {matches, taken}
          end
        end)
      end)

    matches
  end

  defp usable_key?(nil), do: false
  defp usable_key?({"", _year}), do: false
  defp usable_key?(_key), do: true

  defp ids_disagree?(h, f) do
    disagree = fn a, b -> a not in [nil, ""] and b not in [nil, ""] and a != b end

    disagree.(h.fields.fide_id, f.fields.fide_id) or
      disagree.(h.fields.national_id, f.fields.national_id)
  end

  # "Peeters, Jan" and "Jan Peeters" and "PEETERS Jan" are the same name;
  # accents do not make a different person either.
  defp name_key(name) when is_binary(name) do
    name
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.downcase()
    |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
    |> Enum.sort()
    |> Enum.join(" ")
  end

  defp name_key(_name), do: ""

  defp player_changes(here_by_id, file_players, matches) do
    for f <- file_players,
        here_id = Map.get(matches, f.id),
        here_id != nil,
        h = Map.fetch!(here_by_id, here_id),
        changes = field_changes(h.fields, f.fields),
        changes != [] do
      %{id: here_id, name: h.fields.name, changes: changes}
    end
  end

  # A FIDE id the file does not have is one SWAR never knew, or one the
  # arbiter picked from the FIDE list at the first import - either way not
  # a reason to take it away.
  defp field_changes(here, file) do
    for field <- @player_fields,
        not (field == :fide_id and is_nil(file.fide_id)),
        not same?(Map.get(here, field), Map.get(file, field)),
        do: %{field: field, here: Map.get(here, field), file: Map.get(file, field)}
  end

  ## ---------- settings ----------

  defp setting_rows(existing, here, file) do
    locked = Tournaments.locked_fields(existing)

    keys =
      file.settings
      |> Map.keys()
      |> Enum.sort_by(fn key ->
        case Enum.find_index(@setting_order, &(&1 == key)) do
          nil -> {1, Atom.to_string(key)}
          i -> {0, i}
        end
      end)

    rows =
      for key <- keys,
          not same?(Map.get(here.settings, key), Map.get(file.settings, key)) do
        %{
          field: key,
          here: Map.get(here.settings, key),
          file: Map.get(file.settings, key),
          locked?: key in locked
        }
      end

    # SWAR's own bookkeeping, kept for the way back: compared without the
    # file's version string, which says only which SWAR saved it.
    if same?(
         Map.drop(here.swar_settings, ["version"]),
         Map.drop(file.swar_settings, ["version"])
       ),
       do: rows,
       else:
         rows ++
           [
             %{
               field: :swar_settings,
               here: here.swar_settings,
               file: file.swar_settings,
               locked?: false
             }
           ]
  end

  ## ---------- rounds ----------

  # One round both sides have. Boards are the same game when they seat the
  # same two players the same way round; the result is then compared. Any
  # other difference is in the pairing itself, and is only reported.
  defp compare_round(number, here, file, matches, name_here, name_file) do
    file_boards =
      Enum.map(file.boards, fn b ->
        Map.merge(b, %{
          here_white: Map.get(matches, b.white),
          here_black: b.black && Map.get(matches, b.black)
        })
      end)

    here_index = Map.new(here.boards, &{{&1.white, &1.black}, &1})

    {pairs, unmatched_file} =
      Enum.reduce(file_boards, {[], []}, fn fb, {pairs, unmatched} ->
        key = {fb.here_white, fb.here_black}

        with false <- is_nil(fb.here_white),
             false <- not is_nil(fb.black) and is_nil(fb.here_black),
             %{} = hb <- Map.get(here_index, key) do
          {[{hb, fb} | pairs], unmatched}
        else
          _ -> {pairs, [fb | unmatched]}
        end
      end)

    matched_here = MapSet.new(pairs, fn {hb, _fb} -> hb.id end)
    unmatched_here = Enum.reject(here.boards, &MapSet.member?(matched_here, &1.id))

    results =
      pairs
      |> Enum.sort_by(fn {hb, _fb} -> {hb.board || 0, hb.id} end)
      |> Enum.reject(fn {hb, fb} -> same?(hb.result, fb.result) end)
      |> Enum.map(fn {hb, fb} ->
        %{
          id: "result-#{hb.id}",
          kind: :result,
          round: number,
          board: hb.board,
          pairing_id: hb.id,
          white: name_here.(hb.white),
          black: hb.black && name_here.(hb.black),
          here: hb.result,
          file: fb.result,
          added?: hb.result in ["", nil]
        }
      end)

    seated_here = MapSet.new(Enum.flat_map(here.boards, &[&1.white, &1.black]))

    seated_file =
      MapSet.new(Enum.flat_map(file_boards, &[&1.here_white, &1.here_black]))

    file_byes =
      for {file_id, type} <- file.byes,
          here_id = Map.get(matches, file_id),
          here_id != nil,
          into: %{},
          do: {here_id, type}

    bye_rows =
      (Map.keys(here.byes) ++ Map.keys(file_byes))
      |> Enum.uniq()
      |> Enum.reject(&(MapSet.member?(seated_here, &1) or MapSet.member?(seated_file, &1)))
      |> Enum.reject(&same?(Map.get(here.byes, &1), Map.get(file_byes, &1)))
      |> Enum.sort_by(name_here)
      |> Enum.map(fn player_id ->
        %{
          id: "bye-#{number}-#{player_id}",
          kind: :bye,
          round: number,
          player_id: player_id,
          player: name_here.(player_id),
          here: Map.get(here.byes, player_id),
          file: Map.get(file_byes, player_id),
          added?: is_nil(Map.get(here.byes, player_id))
        }
      end)

    differences =
      if unmatched_here == [] and unmatched_file == [] do
        []
      else
        [
          %{
            round: number,
            here: Enum.map(unmatched_here, &board_text(&1, &1.white, &1.black, name_here)),
            file:
              unmatched_file
              |> Enum.sort_by(&(&1.board || 0))
              |> Enum.map(&board_text(&1, &1.white, &1.black, name_file))
          }
        ]
      end

    {results ++ bye_rows, differences}
  end

  defp board_text(board, white, nil, name),
    do: %{board: board.board, white: name.(white), black: nil}

  defp board_text(board, white, black, name),
    do: %{board: board.board, white: name.(white), black: name.(black)}

  ## ---------- apply ----------

  @doc """
  Writes what the arbiter chose from `review`, in one transaction, after a
  pinned restore point. `choices`:

    * `:settings`, `:players` - `:file` or `:keep` (the default);
    * `:new_players`, `:rounds` - `:add` (the default) or `:skip`;
    * `:rows` - `%{row_id => :file | :keep}` for `review.results`; a row
      not named takes its default (the file's for a result or bye added
      where there was none, OpenPairings' otherwise).

  Returns `{:ok, summary}` - counts of what was written - or
  `{:error, reason}` (`error_message/1`), with nothing written.
  """
  def apply(review, choices, scope) do
    result =
      Tournaments.with_broadcast_suppressed(fn ->
        Repo.transaction(fn ->
          tournament = Repo.get!(Tournament, review.tournament_id)

          with :ok <- mergeable(tournament),
               :ok <- unchanged(review),
               :ok <- rounds_have_their_players(review, choices),
               :ok <- restore_point(tournament, scope) do
            summary = write(tournament, review, choices, scope)
            Audit.log(tournament.id, scope, "import.swar_merged", audit_details(review, summary))
            summary
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end)
      end)

    case result do
      {:ok, summary} ->
        Tournaments.broadcast_tournament_change(review.tournament_id, :tournament)
        Tournaments.refresh_status!(review.tournament_id)
        {:ok, summary}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "The default choice for one row of `review.results`."
  def default_row_choice(%{added?: true}), do: :file
  def default_row_choice(_row), do: :keep

  defp mergeable(%Tournament{} = t) do
    cond do
      Tournament.team?(t) -> {:error, :team_tournament}
      true -> Tournaments.ensure_writable(t)
    end
  end

  defp unchanged(review) do
    here = read_side(review.tournament_id, review.file.setting_keys)
    if :erlang.phash2(here) == review.fingerprint, do: :ok, else: {:error, :changed_since_review}
  end

  defp rounds_have_their_players(review, choices) do
    needed? = Enum.any?(review.new_players, & &1.in_new_rounds?)

    if review.new_rounds != [] and choice(choices, :rounds, :add) == :add and needed? and
         choice(choices, :new_players, :add) == :skip,
       do: {:error, :rounds_need_new_players},
       else: :ok
  end

  defp restore_point(tournament, scope) do
    case Snapshots.capture(tournament, @snapshot_trigger, scope,
           summary: "Before merging a SWAR file",
           pinned: true
         ) do
      {:ok, _snapshot} -> :ok
      {:error, _reason} -> {:error, :no_restore_point}
    end
  end

  defp choice(choices, key, default), do: Map.get(choices, key) || default

  defp write(tournament, review, choices, scope) do
    settings = write_settings(tournament, review, choice(choices, :settings, :keep))
    players = write_player_changes(review, choice(choices, :players, :keep))
    {added, ids} = write_new_players(review, choice(choices, :new_players, :add))
    rows = write_rows(review, Map.get(choices, :rows, %{}), scope)

    rounds =
      if choice(choices, :rounds, :add) == :add,
        do: write_rounds(review, Map.merge(review.matches, ids)),
        else: 0

    %{settings: settings, players: players, new_players: added, rows: rows, rounds: rounds}
  end

  defp write_settings(_tournament, _review, :keep), do: 0

  defp write_settings(tournament, review, :file) do
    rows = Enum.reject(review.settings, & &1.locked?)
    {swar, plain} = Enum.split_with(rows, &(&1.field == :swar_settings))
    attrs = Map.new(plain, &{&1.field, &1.file})

    tournament =
      if attrs == %{} do
        tournament
      else
        case Tournaments.update_tournament(tournament, attrs) do
          {:ok, updated} -> updated
          {:error, reason} -> Repo.rollback({:settings, reason})
        end
      end

    Enum.each(swar, fn row ->
      tournament |> Ecto.Changeset.change(swar_settings: row.file) |> Repo.update!()
    end)

    length(rows)
  end

  defp write_player_changes(_review, :keep), do: 0

  defp write_player_changes(review, :file) do
    Enum.each(review.player_changes, fn change ->
      player = Repo.get!(Player, change.id)
      attrs = Map.new(change.changes, &{&1.field, &1.file})

      case Tournaments.update_player(player, attrs) do
        {:ok, _player} -> :ok
        {:error, reason} -> Repo.rollback({:player, change.name, reason})
      end
    end)

    length(review.player_changes)
  end

  defp write_new_players(_review, :skip), do: {0, %{}}

  # The next pairing numbers, in the file's order; joining in the round
  # after this tournament's last, as a player added by hand would.
  defp write_new_players(review, :add) do
    first =
      (Repo.one(
         from p in Player,
           where: p.tournament_id == ^review.tournament_id,
           select: max(p.pairing_number)
       ) || 0) + 1

    ids =
      review.new_players
      |> Enum.with_index(first)
      |> Map.new(fn {p, pairing_number} ->
        attrs =
          p.fields
          |> Map.put(:pairing_number, pairing_number)
          |> Map.put(:start_round, review.here_max + 1)

        case Tournaments.create_player(review.tournament_id, attrs) do
          {:ok, player} -> {p.id, player.id}
          {:error, reason} -> Repo.rollback({:player, p.name, reason})
        end
      end)

    {map_size(ids), ids}
  end

  defp write_rows(review, row_choices, scope) do
    review.results
    |> Enum.filter(fn row -> Map.get(row_choices, row.id, default_row_choice(row)) == :file end)
    |> Enum.map(&write_row(review, &1, scope))
    |> length()
  end

  # The arbiter picked this row with both results in front of them, which
  # is the confirmation a postponed game's result and a correction ask for.
  # A result already sent to the federation is not confirmed here: that one
  # is changed on the Pairings page, where it says so.
  defp write_row(review, %{kind: :result} = row, scope) do
    pairing = Repo.get!(Pairing, row.pairing_id) |> Repo.preload([:white_player, :black_player])
    result = row.file || ""
    correction? = ResultCorrections.correction?(pairing, result)

    case Tournaments.update_pairing_result(pairing, result,
           acknowledged: [:adjourned_non_draw_result, :result_correction]
         ) do
      {:ok, _pairing} ->
        if correction? do
          # A Correction PIBE (VCL4THP Q112), logged as the Pairings page
          # logs one; the restore point was taken before anything changed.
          Audit.log(review.tournament_id, scope, "pibe.correction", %{
            pairing_id: pairing.id,
            round: row.round,
            board: pairing.board,
            line:
              ResultCorrections.line(
                row.round,
                pairing.white_player && pairing.white_player.pairing_number,
                pairing.black_player && pairing.black_player.pairing_number,
                pairing.result,
                result
              )
          })
        end

        :ok

      {:error, reason} ->
        Repo.rollback({:result, row, reason})
    end
  end

  defp write_row(review, %{kind: :bye} = row, _scope) do
    from(b in "byes",
      where:
        b.tournament_id == ^review.tournament_id and b.round == ^row.round and
          b.player_id == ^row.player_id
    )
    |> Repo.delete_all()

    if row.file do
      Repo.insert_all("byes", [
        %{
          tournament_id: review.tournament_id,
          player_id: row.player_id,
          round: row.round,
          type: row.file
        }
      ])
    end

    :ok
  end

  # The file's new rounds as the import writes a round: its boards, its
  # byes, the extra points it was paired with.
  defp write_rounds(review, ids) do
    Enum.each(review.new_rounds, fn %{number: number} ->
      round = review.file.rounds[number]

      inserted =
        Repo.insert!(%Round{
          tournament_id: review.tournament_id,
          number: number,
          status: round.status,
          virtual_points:
            Map.new(round.virtual_points, fn {id, v} ->
              {to_string(Map.fetch!(ids, String.to_integer(id))), v}
            end)
        })

      Enum.each(round.boards, fn b ->
        Repo.insert!(%Pairing{
          round_id: inserted.id,
          board: b.board,
          white_player_id: Map.fetch!(ids, b.white),
          black_player_id: b.black && Map.fetch!(ids, b.black),
          result: b.result
        })
      end)

      byes =
        for {player, type} <- round.byes, Map.has_key?(ids, player) do
          %{
            tournament_id: review.tournament_id,
            player_id: Map.fetch!(ids, player),
            round: number,
            type: type
          }
        end

      if byes != [], do: Repo.insert_all("byes", byes)

      Tournaments.freeze_round_display_boards!(inserted.id)
    end)

    length(review.new_rounds)
  end

  defp audit_details(review, summary) do
    %{
      name: review.tournament_name,
      settings: summary.settings,
      players: summary.players,
      new_players: summary.new_players,
      results: summary.rows,
      rounds: summary.rounds,
      pairing_differences_kept: length(review.pairing_differences)
    }
  end

  ## ---------- what the arbiter reads ----------

  @doc "The arbiter's message for an `apply/3` or `review/2` refusal."
  def error_message(:team_tournament),
    do: gettext("A team tournament cannot be merged with a SWAR file.")

  def error_message(:archived),
    do: gettext("This tournament is archived - unarchive it before merging a file into it.")

  def error_message(:handed_off),
    do:
      gettext(
        "This tournament has been handed off to another copy - take it back before merging a file into it."
      )

  def error_message(:changed_since_review),
    do:
      gettext(
        "The tournament changed while you were looking at the comparison, so nothing was merged. Upload the file again to compare with what it is now."
      )

  def error_message(:rounds_need_new_players),
    do:
      gettext(
        "The new rounds can only be added together with the new players who play in them. Add the new players too, or do not add the rounds."
      )

  def error_message(:no_restore_point),
    do: gettext("The restore point could not be saved, so nothing was merged.")

  def error_message({:settings, :locked_after_pairing}),
    do:
      gettext(
        "A setting that is locked once rounds are paired would have changed, so nothing was merged."
      )

  def error_message({:settings, :locked_in_fide_mode}),
    do: gettext("A setting that FIDE mode locks would have changed, so nothing was merged.")

  def error_message({:settings, %Ecto.Changeset{} = changeset}),
    do:
      gettext("The file's settings could not be saved (%{errors}), so nothing was merged.",
        errors: changeset_errors(changeset)
      )

  def error_message({:player, name, :duplicate_fide_id}),
    do:
      gettext("%{name} has a FIDE id another player already has, so nothing was merged.",
        name: name
      )

  def error_message({:player, name, %Ecto.Changeset{} = changeset}),
    do:
      gettext("%{name} could not be saved (%{errors}), so nothing was merged.",
        name: name,
        errors: changeset_errors(changeset)
      )

  def error_message({:result, row, {:needs_acknowledgement, _ids}}),
    do:
      gettext(
        "The result of round %{round}, board %{board} was already sent to the federation. Change it on the Pairings page, where that is confirmed; nothing was merged.",
        round: row.round,
        board: row.board
      )

  def error_message({:result, row, reason}),
    do:
      gettext(
        "The result of round %{round}, board %{board} could not be changed (%{reason}), so nothing was merged.",
        round: row.round,
        board: row.board,
        reason: reason_text(reason)
      )

  def error_message(reason), do: SwarImport.error_message(reason)

  defp reason_text(atom) when is_atom(atom),
    do: atom |> Atom.to_string() |> String.replace("_", " ")

  defp reason_text(other), do: inspect(other)

  defp changeset_errors(changeset) do
    Enum.map_join(changeset.errors, "; ", fn {field, {msg, _}} -> "#{field} #{msg}" end)
  end

  @doc "A setting's or a player field's name, as the arbiter knows it."
  def field_label(:name), do: gettext("Name")
  def field_label(:city), do: gettext("City")
  def field_label(:organizer), do: gettext("Organiser")
  def field_label(:organizer_club_number), do: gettext("Organising club number")
  def field_label(:federation), do: gettext("Federation")
  def field_label(:start_date), do: gettext("Start date")
  def field_label(:end_date), do: gettext("End date")
  def field_label(:round_dates), do: gettext("Round dates")
  def field_label(:rounds_count), do: gettext("Number of rounds")
  def field_label(:chief_arbiter), do: gettext("Chief arbiter")
  def field_label(:deputy_arbiter), do: gettext("Deputy arbiters")
  def field_label(:officials), do: gettext("Officials")
  def field_label(:event_code), do: gettext("FIDE event code")
  def field_label(:rate_of_play), do: gettext("Rate of play")
  def field_label(:standard), do: gettext("Rating list (standard, rapid or blitz)")
  def field_label(:fide_homologated), do: gettext("FIDE rated")
  def field_label(:fide_id_ranges), do: gettext("FIDE tournament ids")
  def field_label(:tiebreaks), do: gettext("Tie-breaks")
  def field_label(:bye_value), do: gettext("Points for a bye")
  def field_label(:abs_value), do: gettext("Points for an absence")
  def field_label(:abs_jusque), do: gettext("Absences paid up to round")
  def field_label(:abs_nbfois), do: gettext("Absences paid at most")
  def field_label(:points_win), do: gettext("Points for a win")
  def field_label(:points_draw), do: gettext("Points for a draw")
  def field_label(:points_loss), do: gettext("Points for a loss")
  def field_label(:presence_value), do: gettext("Points for turning up")
  def field_label(:categories), do: gettext("Categories")
  def field_label(:categories_enabled), do: gettext("Categories on")
  def field_label(:categories_ranked_separately), do: gettext("Rank each category separately")
  def field_label(:pair_by_category), do: gettext("Pair each category separately")
  def field_label(:type), do: gettext("Tournament type")
  def field_label(:pairing_system), do: gettext("Pairing system")
  def field_label(:initial_colour), do: gettext("Colour of the top seed in round 1")
  def field_label(:extra_points_mode), do: gettext("Extra points mode")
  def field_label(:extra_points_bands), do: gettext("Extra points bands")
  def field_label(:count_extra_points), do: gettext("Count extra points")

  def field_label(:late_entry_absences),
    do: gettext("Rounds before a late entry count as absences")

  def field_label(:swar_settings),
    do: gettext("SWAR's own settings (used when exporting back to SWAR)")

  def field_label(:sex), do: gettext("Sex")
  def field_label(:title), do: gettext("Title")
  def field_label(:fide_id), do: gettext("FIDE id")
  def field_label(:fide_rating), do: gettext("FIDE rating")
  def field_label(:national_id), do: gettext("National id")
  def field_label(:national_rating), do: gettext("National rating")
  def field_label(:birth_year), do: gettext("Year of birth")
  def field_label(:birth_date), do: gettext("Date of birth")
  def field_label(:club), do: gettext("Club")
  def field_label(:club_number), do: gettext("Club number")
  def field_label(:paid), do: gettext("Paid")
  def field_label(:affiliated), do: gettext("Affiliated")
  def field_label(:absent), do: gettext("Absent")
  def field_label(:forfeit), do: gettext("Withdrawn")
  def field_label(:fixed_board), do: gettext("Fixed board")
  def field_label(:absent_rounds), do: gettext("Absent in rounds")
  def field_label(:extra_points), do: gettext("Extra points")
  def field_label(:category), do: gettext("Category")

  def field_label(field),
    do: field |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()

  @doc "A setting's or a player field's value, for reading."
  def format_value(:swar_settings, value) when is_map(value),
    do: ngettext("%{count} value", "%{count} values", map_size(value))

  def format_value(_field, value) when value in [nil, "", []], do: gettext("(empty)")
  def format_value(_field, true), do: gettext("yes")
  def format_value(_field, false), do: gettext("no")
  def format_value(_field, %Date{} = date), do: Date.to_iso8601(date)

  def format_value(_field, value) when is_float(value) do
    if value == Float.round(value), do: Integer.to_string(trunc(value)), else: to_string(value)
  end

  def format_value(field, list) when is_list(list),
    do: Enum.map_join(list, ", ", &format_value(field, &1))

  def format_value(_field, map) when is_map(map) do
    map
    |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
    |> Enum.sort()
    |> Enum.map_join(", ", fn {k, v} -> "#{k}: #{v}" end)
  end

  def format_value(_field, value), do: to_string(value)

  @doc "A board's result, for reading."
  def format_result(result) when result in [nil, ""], do: gettext("no result")
  def format_result("bye"), do: gettext("bye")
  def format_result(result), do: String.replace(result, "1/2", "½")

  @doc "A bye row's value, for reading."
  def format_bye(nil), do: gettext("nothing")
  def format_bye("absent"), do: gettext("absent")
  def format_bye("requested-half"), do: gettext("half-point bye")
  def format_bye("requested-zero"), do: gettext("zero-point bye")
  def format_bye("full-point"), do: gettext("full-point bye")
  def format_bye(other), do: other

  ## ---------- comparing values ----------

  # Blank is blank whichever way it is spelled, and 1 is 1.0.
  defp same?(a, b) do
    cond do
      blank?(a) and blank?(b) -> true
      is_number(a) and is_number(b) -> a == b
      true -> a == b
    end
  end

  defp blank?(value), do: value in [nil, "", []] or value == %{}

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
