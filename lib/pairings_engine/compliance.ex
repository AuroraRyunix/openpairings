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

  The list below is three entries long, and that is the finding rather than
  an omission. Every candidate setting was checked against what FIDE
  actually says, and most of them came back "FIDE requires this to be
  configurable" or "FIDE's own report format has a record for it":

    * **Scoring values** (`points_win`/`points_draw`/`points_loss`,
      `bye_value`, `abs_value` and its two caps, `presence_value`).
      `VCL.16` requires the pairing-allocated bye value to be configurable
      and `VCL.17` requires half-point byes to be assignable; `VCL.12`
      requires the TRF16 export to stay analyzable "even under a non-default
      scoring system", which is the checklist *assuming* non-default scoring
      exists. A rule that fired on these would contradict the checklist we
      are being measured against.
    * **Extra points** (`count_extra_points`). TRF26 has a dedicated `299`
      record for "points assigned outside the scoring system - a bonus or a
      penalty an arbiter added by hand", and FIDE's own wording for it
      allows a negative value. `TrfExport.free_point_records/2` already
      writes it. FIDE does not merely permit these, it asks to be told about
      them. Pairing never counts them and neither do the C.07 tie-breaks
      (docs/extra-points.md).
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
      pairing outright.
    * **Acceleration** (`acceleration`). Baku is FIDE's own, C.04.7. Both
      values are FIDE's.
    * **Pairing engine** (`pairing_engine`). JaVaFo is the FIDE-endorsed
      one; Ainalrami is not endorsed yet, and implements the edition of
      C.04.3 in force since 1 February 2026 where JaVaFo implements the 2022
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
      `Tournaments.add_forbidden_pairing/4` is where it lands.
    * **`rr_match_format`.** It reorders a fixed Berger schedule; every
      pairing in it is still a Berger pairing and everybody still meets
      everybody with the same colours. It changes the order of rounds, not
      who meets whom.
    * **`allow_swiss321`** is not a tournament setting at all - it is an
      option on `Federations.BEL.SwarImport.parse/2`, and the import is
      refused without it for data-fidelity reasons that have nothing to do
      with FIDE.

  The line that survived all of that: **a departure is a setting that
  changes who plays whom, away from what a FIDE pairing system produces.**
  All three below do exactly that, all three are frozen after the first
  round is paired (`Tournaments.locked_fields/1`), and all three default off.

  ## The Levels

  VCL4THP v13's Level 1-5 warning scale is not public and is not modelled
  here. When the definitions arrive, a level is one more key on each entry
  in `@departures` - the mechanism underneath does not change. Do not invent
  a severity scale in the meantime; a guessed level is worse than none,
  because the levels are what verification reads.
  """

  alias PairingsEngine.Tournaments.Tournament

  # One entry per way a tournament's settings can stop describing a FIDE
  # pairing, in the order they are reported. `restore_to` is every value of
  # that setting that brings compliance back - a list, because
  # `pairing_system` has two.
  #
  # The table holds only what a module attribute can hold; the actual test
  # per setting is `departed?/2` below, one clause each, so the two cannot
  # drift: a setting listed here with no clause is a FunctionClauseError on
  # the first call rather than a rule that silently never fires.
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
    for entry <- @departures, departed?(entry.setting, tournament) do
      %{
        setting: entry.setting,
        code: entry.code,
        value: Map.get(tournament, entry.setting),
        restore_to: entry.restore_to
      }
    end
  end

  # Keizer is not a FIDE pairing system. C.04.3 defines the Dutch Swiss and
  # C.05 Annex 1 the round-robin Berger tables; nothing in the handbook
  # defines a Keizer ladder, which is also why this app's own tie-break code
  # says FIDE tie-breaks do not apply to one. `VCL.03` requires the pairing
  # system a standard invocation activates to be one the program is endorsed
  # for, and no program can be endorsed for a system FIDE has not written
  # down.
  defp departed?(:pairing_system, t), do: t.pairing_system not in ["swiss", "round_robin"]

  # Each category is paired completely independently - its own engine run and
  # its own pairing-allocated bye - and the results are merged into one
  # Round. The event is then reported to FIDE as one tournament whose rounds
  # were not paired by C.04.3 over that tournament's field: two players on
  # the same score never meet if they are in different categories, which is
  # not a thing C.04.3 can produce. Running the sections as separate
  # tournaments is the compliant way to do the same thing.
  defp departed?(:pair_by_category, t), do: swiss?(t) and t.pair_by_category == true

  # The second leg of a match is inserted as an exact colour-reversed mirror
  # of the first, with no pairing decision behind it at all (see
  # `Pairing.do_pair/2`). Half the rounds in the tournament were therefore not
  # paired by C.04.3, and a checker fed the TRF would say so about every
  # even-numbered one.
  defp departed?(:swiss_match_format, t), do: swiss?(t) and t.swiss_match_format == true

  # Both booleans above are inert unless the tournament actually pairs Swiss
  # - their own schema comments say "never read otherwise", the same
  # tolerance `acceleration` gets. Reporting a departure that no round will
  # ever act on is the cry-wolf failure this module is written to avoid: an
  # arbiter who learns one entry is noise stops reading the others.
  defp swiss?(%Tournament{pairing_system: "swiss"}), do: true
  defp swiss?(%Tournament{}), do: false

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
  The schema fields that have a FIDE-compliance dimension at all.

  Used by the Settings pages to decide whether a page hosts anything worth
  showing a compliance notice for, so the notice cannot drift out of sync
  with the rules above by being rendered in one place and forgotten in
  another.
  """
  @spec settings() :: [atom()]
  def settings, do: Enum.map(@departures, & &1.setting)

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
