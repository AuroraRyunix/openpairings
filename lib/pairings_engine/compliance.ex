defmodule PairingsEngine.Compliance do
  @moduledoc """
  Whether a tournament is still being handled the way FIDE's pairing
  regulations say it must be - **computed from its settings, never stored.**

  ## Why there is no switch

  FIDE Mode is per tournament, it is the default, and there is no toggle
  (`docs/design-fide-mode.md`, section 0c). The 2017 checklist says the same
  thing twice: `VCL.01` requires the FIDE mode to be the DEFAULT OPERATING
  MODE and `VCL.02` that it be reachable by a standard installation and a
  standard invocation. Neither describes a control, and a program that ships
  compliant and warns you on your way out satisfies both without ever
  drawing a checkbox.

  So compliance is not a flag anybody sets. Every setting this module looks
  at ships at a compliant default; a tournament stops being compliant
  because an arbiter deliberately changed one of them. `check/1` answers
  *which* ones, and what each would have to be to come back.

  This module is pure. It takes a `%Tournament{}` and returns data - no
  Repo, no gettext. Sentences live in the web layer
  (`PairingsEngineWeb.SettingsSupport.compliance_notice/1`); everything here
  is a code an atom can carry. Getting that backwards produces warnings that
  cannot be translated.

  ## What is deliberately NOT here

  The list below is short, and that is the finding rather than an omission.
  Every candidate setting was checked against what FIDE actually says, and
  most of them came back "FIDE requires this to be configurable" or "FIDE's
  own report format has a record for it":

    * **Scoring values in general** (`points_win`/`points_draw`/`points_loss`,
      `bye_value`, `abs_value` and its two caps, `presence_value`).
      `VCL.16` requires the pairing-allocated bye value to be configurable
      and `VCL.17` requires half-point byes to be assignable; `VCL.12`
      requires the TRF16 export to stay analyzable "even under a non-default
      scoring system", which is the checklist *assuming* non-default scoring
      exists, and VCL4THP v13 asks for 3-1-0 and custom systems outright
      (Q71-Q73). What v13 does fail is narrower: scores no game can give
      (Q74, Q81, Q83). Those three are entries below; the rest of scoring
      is not. That scoring and the bye's value cannot CHANGE once the event
      is under way (Q75, Q85) is a lock, not a departure -
      `Tournaments.fide_locked_fields/1`.
    * **Extra points** (`count_extra_points`). TRF26 has a dedicated `299`
      record for "points assigned outside the scoring system - a bonus or a
      penalty an arbiter added by hand", and FIDE's own wording for it
      allows a negative value. `TrfExport.free_point_records/2` already
      writes it. FIDE does not merely permit these, it asks to be told about
      them. The C.07 tie-breaks never count them (docs/extra-points.md).
      In the PAIRING they are a departure - since the extra-points modes a
      counted handicap and acceleration-mode points reach the engine as
      virtual points - but not one a setting can show: acceleration mode
      changes nothing until a player holds points, which no pure function
      over a `%Tournament{}` can see. So the pairing marks it instead, in
      the first round the points actually reach the engine
      (`Pairing.pairing_deviations/2`, which stamps
      `fide_compliance_lost_round` like a setting does), and the Extra
      points page warns before it is saved. Baku is FIDE's own and is not
      marked.
    * **Manual standings order** (`manual_ranking`). C.07 ends in
      mechanisms - a play-off, drawing of lots - whose outcome an arbiter
      has to be able to record, and recording one is the feature's first
      documented use (docs/manual-standings.md). A permanent non-conformance
      mark for doing the correct thing is the definition of crying wolf. The
      case that WOULD be a departure - a hand-set order that contradicts the
      score order - is a fact about the players, not the tournament's
      settings, and no pure function over a `%Tournament{}` can see it.
    * **Tie-break selection** (`tiebreaks`). C.07 lists systems and the
      tournament's own regulations choose among them and announce them in
      advance. FIDE mandates no particular selection. An empty list is
      already refused by `Tournament.missing_setup_fields/1`, which blocks
      pairing outright. Changing the list once the event is under way is
      what VCL4THP fails (Q200/Q201), and that is a FIDE-mode lock.
    * **Acceleration** (`acceleration`). Baku is FIDE's own, C.04.7. Both
      values are FIDE's. Removing or changing it after round 1 (Q109/Q110)
      is a FIDE-mode lock, like the tie-breaks.
    * **Pairing engine** (`pairing_engine`). JaVaFo is the FIDE-endorsed
      one; Ainalrami is not endorsed yet, and implements the edition of
      C.04.3 in force since 1 February 2026 where JaVaFo implements the 2017
      one. `VCL.03` ("a system the program is endorsed for") points at
      JaVaFo and rules-currency points at Ainalrami, so the regulations
      cannot settle it either way and this module does not pretend to. The
      advisory note on the Options page is the right treatment and stays.
    * **Forbidden pairings, club and federation exclusions, soft rules.**
      `XXP` is FIDE's own TRF extension and the endorsed engine implements
      it. VCL4THP's Q196 does make adding a prohibited pairing *after round
      1* a hard failure, citing C.05:5.2 - but that is an act at a round,
      not a setting, and `docs/tec-feedback-2026-09.md:179-193` is a live
      disagreement with TEC about whether that reading is right at all.
      Encoding one side of an open argument as a permanent mark on an
      arbiter's tournament is not this module's call. When Q196 settles,
      `Tournaments.add_forbidden_pairing/4` is where it lands. The SOFT
      rules ("only if possible" pairs, clubmates apart) are the exception:
      they are not `XXP`, they replace the Dutch system's own choice among
      equally good pairings, and the round they change is not the one a FIDE
      checker reproduces. Like extra points, that is a fact about a round,
      so the pairing marks it when they move a board
      (`Pairing.pairing_deviations/2`) and not before; so does an
      organiser's bye exclusion that moves the bye.
    * **`rr_match_format`.** It reorders a fixed Berger schedule; every
      pairing in it is still a Berger pairing and everybody still meets
      everybody with the same colours. It changes the order of rounds, not
      who meets whom.

  The line that survived all of that: **a departure is a setting that
  changes who plays whom, or what a game is worth, away from what the FIDE
  rules allow.** The first three below change who plays whom; the postponed
  outcomes and the three scoring entries change what a game is worth. All of
  them default to the FIDE value.

  ## The Levels, and what FIDE mode refuses

  The TEC Manual draft that came with VCL4THP v13 defines five warning
  levels; Level 5 is "rejected in FIDE mode, or allowed only after leaving
  it". This module still carries no level per entry - a departure is the
  act of leaving, which the draft puts at Level 4. What FIDE mode refuses
  outright lives in `Tournaments` (`fide_locked_fields/1`,
  `ensure_round_editable/2`) and reads `fide_mode?/1` below; the one
  explicit way out is `Tournaments.leave_fide_mode/1`.
  """

  alias PairingsEngine.Tournaments.Tournament

  # One entry per way a tournament's settings can stop describing a FIDE
  # pairing, in the order they are reported. `restore_to` is every value of
  # that setting that brings compliance back - a list, because
  # `pairing_system` has two.
  #
  # The table holds only what a module attribute can hold; the actual test
  # per entry is `departed?/2` below, one clause per code, so the two cannot
  # drift: a code listed here with no clause is a FunctionClauseError on
  # the first call rather than a rule that silently never fires. Keyed by
  # code rather than setting because `bye_value` carries two.
  @departures [
    %{
      setting: :pairing_system,
      code: :non_fide_pairing_system,
      restore_to: ["swiss", "round_robin"]
    },
    %{
      setting: :pair_by_category,
      code: :categories_paired_separately,
      restore_to: [false]
    },
    %{
      setting: :swiss_match_format,
      code: :mirrored_second_leg,
      restore_to: [false]
    },
    %{
      setting: :postponed_requester_outcome,
      code: :postponed_requester_not_draw,
      restore_to: ["draw"]
    },
    %{
      setting: :postponed_opponent_outcome,
      code: :postponed_opponent_not_draw,
      restore_to: ["draw"]
    },
    # The three scoring entries below are relations between values, not one
    # bad value, so their `restore_to` is worked out per tournament
    # (`restore_to/2`): the values listed are each one that would do.
    %{
      setting: :points_draw,
      code: :draws_outscore_win,
      restore_to: :computed
    },
    %{
      setting: :bye_value,
      code: :bye_above_win,
      restore_to: :computed
    },
    %{
      setting: :bye_value,
      code: :bye_not_a_game_score,
      restore_to: :computed
    }
  ]

  @typedoc """
  One reason a tournament is not compliant.

    * `:setting` - the schema field an arbiter would change to fix it.
    * `:code` - what is wrong, as an atom the web layer turns into a
      sentence. Never a sentence itself.
    * `:value` - what the setting is now.
    * `:restore_to` - the values that would restore compliance, any one of
      them.
  """
  @type departure :: %{
          setting: atom(),
          code: atom(),
          value: term(),
          restore_to: [term()]
        }

  @doc """
  Every departure `tournament`'s settings currently carry, in a stable
  order - `[]` when it is still compliant.

  Pure: same struct in, same list out, no query. Safe to call from a render.
  """
  @spec check(Tournament.t()) :: [departure()]
  def check(%Tournament{} = tournament) do
    for entry <- @departures, departed?(entry.code, tournament) do
      %{
        setting: entry.setting,
        code: entry.code,
        value: Map.get(tournament, entry.setting),
        restore_to: restore_to(entry, tournament)
      }
    end
  end

  defp restore_to(%{restore_to: :computed, code: :draws_outscore_win}, t),
    do: [(win(t) + loss(t)) / 2]

  defp restore_to(%{restore_to: :computed, code: :bye_above_win}, t),
    do: Enum.uniq([win(t), draw(t), loss(t)])

  defp restore_to(%{restore_to: :computed, code: :bye_not_a_game_score}, _t),
    do: [1.0, 0.5, 0.0]

  defp restore_to(%{restore_to: values}, _t), do: values

  # Keizer is not a FIDE pairing system. C.04.3 defines the Dutch Swiss and
  # C.05 Annex 1 the round-robin Berger tables; nothing in the handbook
  # defines a Keizer ladder, which is also why this app's own tie-break code
  # says FIDE tie-breaks do not apply to one. `VCL.03` requires the pairing
  # system a standard invocation activates to be one the program is endorsed
  # for, and no program can be endorsed for a system FIDE has not written
  # down.
  defp departed?(:non_fide_pairing_system, t),
    do: t.pairing_system not in ["swiss", "round_robin"]

  # Each category is paired completely independently - its own engine run and
  # its own pairing-allocated bye - and the results are merged into one
  # Round. The event is then reported to FIDE as one tournament whose rounds
  # were not paired by C.04.3 over that tournament's field: two players on
  # the same score never meet if they are in different categories, which is
  # not a thing C.04.3 can produce. Running the sections as separate
  # tournaments is the compliant way to do the same thing.
  defp departed?(:categories_paired_separately, t), do: swiss?(t) and t.pair_by_category == true

  # The second leg of a match is inserted as an exact colour-reversed mirror
  # of the first, with no pairing decision behind it at all (see
  # `Pairing.do_pair/2`). Half the rounds in the tournament were therefore not
  # paired by C.04.3, and a checker fed the TRF would say so about every
  # even-numbered one.
  defp departed?(:mirrored_second_leg, t), do: swiss?(t) and t.swiss_match_format == true

  # A postponed game counts as a draw until it is played - VCL4THP Q167 fails
  # a program that allows any other provisional score. A club may still want
  # to "punish" the player who asked for it by counting it as a win for them
  # (they are then paired higher up), and that is a legitimate club rule,
  # but not a FIDE one. Only while the tournament allows postponed games at
  # all: with them off, the two values are never read.
  defp departed?(:postponed_requester_not_draw, t),
    do: t.postponed_games == true and t.postponed_requester_outcome not in [nil, "draw"]

  defp departed?(:postponed_opponent_not_draw, t),
    do: t.postponed_games == true and t.postponed_opponent_outcome not in [nil, "draw"]

  # Scoring. VCL4THP v13 fails a program on which, in FIDE mode, two draws
  # can be worth more than a win plus a loss (Q74), a pairing-allocated bye
  # can be worth more than a win (Q81), or a bye can be anything but 1, ½
  # or 0 under the standard 1-½-0 scoring (Q83) - Laws of Chess 10.2: a
  # player's score is one a game can give. Each of those is still a club's
  # right; it just is not a FIDE event any more, so they are departures
  # rather than refusals. Other scoring - 3-1-0, a bye worth a draw, a bye
  # of 2 under 3-1-0 (Q84) - stays in.
  #
  # The bye's value is what a pairing-allocated bye actually pays, SWAR
  # 3-2-1's presence bonus included (`Tournament.engine_point_system/1`).
  # Keizer is left out: it is already a departure, and its own scoring is
  # not FIDE's to judge, so a second line about it would be noise.
  defp departed?(:draws_outscore_win, t),
    do: fide_system?(t) and 2 * draw(t) > win(t) + loss(t)

  defp departed?(:bye_above_win, t),
    do: fide_system?(t) and bye(t) > win(t)

  defp departed?(:bye_not_a_game_score, t),
    do: fide_system?(t) and standard_scoring?(t) and bye(t) not in [1.0, 0.5, 0.0]

  # The two Swiss-only booleans above are inert unless the tournament actually pairs Swiss
  # - their own schema comments say "never read otherwise", the same
  # tolerance `acceleration` gets. Reporting a departure that no round will
  # ever act on is the cry-wolf failure this module is written to avoid: an
  # arbiter who learns one entry is noise stops reading the others.
  defp swiss?(%Tournament{pairing_system: "swiss"}), do: true
  defp swiss?(%Tournament{}), do: false

  defp fide_system?(%Tournament{pairing_system: system}), do: system in ["swiss", "round_robin"]

  defp standard_scoring?(t), do: win(t) == 1.0 and draw(t) == 0.5 and loss(t) == 0.0

  defp win(t), do: number(t.points_win, 1.0)
  defp draw(t), do: number(t.points_draw, 0.5)
  defp loss(t), do: number(t.points_loss, 0.0)
  defp bye(t), do: Tournament.engine_point_system(t).pairing_allocated_bye * 1.0

  defp number(value, _default) when is_number(value), do: value * 1.0
  defp number(_nil, default), do: default

  @doc """
  Whether `tournament`'s settings still describe a FIDE-handled event.

  Note what this does NOT read: `fide_compliance_lost_round`. That column
  records that compliance was once lost and is never cleared, because the
  `###` TRF comment has to name the round it happened in. Putting the
  setting back makes this function true again while the record stands - the
  two answer different questions ("is it compliant now" against "was it
  ever not"), and a caller that wants the second one reads the column.
  """
  @spec compliant?(Tournament.t()) :: boolean()
  def compliant?(%Tournament{} = tournament), do: check(tournament) == []

  @doc """
  Whether `tournament` is in FIDE mode: its settings are compliant now AND
  it has never left - `fide_compliance_lost_round` is nil.

  This is the state VCL4THP's questions are asked in, so it is the one the
  FIDE-mode locks read (`Tournaments.fide_locked_fields/1`,
  `Tournaments.ensure_round_editable/2`). There is no way back in once it
  is false: the record is never cleared (Q45), and settings put back
  afterwards do not make an event that once left a FIDE-handled one again.
  """
  @spec fide_mode?(Tournament.t()) :: boolean()
  def fide_mode?(%Tournament{} = tournament),
    do: is_nil(tournament.fide_compliance_lost_round) and compliant?(tournament)

  @doc """
  The schema fields that have a FIDE-compliance dimension at all.

  Used by the Settings pages to decide whether a page hosts anything worth
  showing a compliance notice for, so the notice cannot drift out of sync
  with the rules above by being rendered in one place and forgotten in
  another.
  """
  @spec settings() :: [atom()]
  def settings, do: @departures |> Enum.map(& &1.setting) |> Enum.uniq()

  @doc "Every departure code, one per entry - `bye_value` has two."
  @spec codes() :: [atom()]
  def codes, do: Enum.map(@departures, & &1.code)

  @doc """
  The departures `after_tournament` has that `before` did not - what a save
  just did, rather than what the tournament looks like now.

  This is what the warning at the point of change is keyed on. A save that
  touches a compliance setting without changing its meaning (the ordinary
  case: a disabled input round-trips its own value) introduces nothing and
  warns about nothing.
  """
  @spec introduced(Tournament.t(), Tournament.t()) :: [departure()]
  def introduced(%Tournament{} = before, %Tournament{} = after_tournament) do
    had = before |> check() |> MapSet.new(& &1.code)

    after_tournament
    |> check()
    |> Enum.reject(&MapSet.member?(had, &1.code))
  end
end
