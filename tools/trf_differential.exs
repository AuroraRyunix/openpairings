# Differential harness: PairingsEngine.Trf vs Ainalrami.Trf.
#
# Both modules are loadable in one BEAM because mix.exs currently carries a
# PATH dependency on ../openpair, so this needs no fixture exchange and no
# subprocess - it calls the two implementations on identical inputs and
# compares what comes back.
#
# Run with:  mix run tools/trf_differential.exs
#
# The point is to replace the estimate in docs/trf-consolidation.md ("mostly
# the same module, plus extensions") with a measurement, before deleting
# lib/pairings_engine/trf.ex and moving its four production callers onto
# Ainalrami.Trf. Divergences are GROUPED BY CAUSE: a thousand cases differing
# because Ainalrami pads the last round block is one finding, not a thousand.

alias PairingsEngine.Trf, as: OP
alias Ainalrami.Trf, as: AI

defmodule TrfDiff do
  @moduledoc false

  # Same column map both modules use privately. Duplicated here on purpose:
  # naming the field a byte offset falls in is what makes a divergence
  # diagnosable, and neither module exposes it.
  @player_cols [
    {"code", 1, 3},
    {"starting_rank", 5, 8},
    {"sex", 10, 10},
    {"title", 11, 13},
    {"name", 15, 47},
    {"fide_rating", 49, 52},
    {"federation", 54, 56},
    {"fide_number", 58, 68},
    {"birth_date", 70, 79},
    {"points", 81, 84},
    {"rank", 86, 89}
  ]

  def field_at(col) when col < 92 do
    case Enum.find(@player_cols, fn {_n, s, e} -> col >= s and col <= e end) do
      {name, _, _} -> name
      nil -> "gap@#{col}"
    end
  end

  def field_at(col) do
    round = div(col - 92, 10) + 1
    offset = rem(col - 92, 10)

    part =
      case offset do
        o when o in 0..3 -> "opponent"
        4 -> "sep"
        5 -> "colour"
        6 -> "sep"
        7 -> "result"
        _ -> "pad"
      end

    "round#{round}.#{part}"
  end

  # ---------------------------------------------------------------
  # running one comparison
  # ---------------------------------------------------------------

  def attempt(fun) do
    {:ok, fun.()}
  rescue
    e -> {:raised, e.__struct__, Exception.message(e)}
  catch
    kind, value -> {:threw, kind, inspect(value)}
  end

  # A message shape, so "Alpha, round 1: ..." and "Bravo, round 3: ..." group
  # as one cause rather than as two.
  def shape(message) do
    message
    |> String.replace(~r/^[^:]*: /, "")
    |> String.replace(~r/\d+/, "N")
    |> String.slice(0, 110)
  end

  # ---------------------------------------------------------------
  # serialize comparison
  # ---------------------------------------------------------------

  # Every cause is a {key, detail} pair: the report groups on the KEY (so one
  # reason is one finding however many cases hit it) and prints the detail of
  # the first case that hit it.
  def compare_serialize(data, opts) do
    op = attempt(fn -> OP.serialize(data, opts) end)
    ai = attempt(fn -> AI.serialize(data, opts) end)

    case {op, ai} do
      {{:ok, same}, {:ok, same}} ->
        :identical

      {{:ok, a}, {:ok, b}} ->
        {:differ, [byte_cause(a, b)]}

      {{:ok, _}, {:raised, mod, msg}} ->
        {:differ, [{{:ainalrami_raised, inspect(mod), shape(msg)}, msg}]}

      {{:raised, mod, msg}, {:ok, _}} ->
        {:differ, [{{:openpairings_raised, inspect(mod), shape(msg)}, msg}]}

      {{:raised, m1, s1}, {:raised, m2, s2}} ->
        if shape(s1) == shape(s2) and inspect(m1) == inspect(m2) do
          :identical_raise
        else
          {:differ, [{{:both_raised_differently, shape(s1), shape(s2)}, s1 <> " | " <> s2}]}
        end

      {a, b} ->
        {:differ, [{{:outcome_kind, kind_of(a), kind_of(b)}, ""}]}
    end
  end

  defp kind_of(tuple), do: tuple |> elem(0) |> inspect()

  # The cause of a byte difference, reduced to something groupable: what kind
  # of line went missing or arrived, or - when both files have the same lines
  # in the same order - which FIELD the first differing column falls in.
  def byte_cause(a, b) do
    la = lines(a)
    lb = lines(b)

    ca = Enum.map(la, &line_code/1)
    cb = Enum.map(lb, &line_code/1)

    extra_in_ai = multiset_minus(cb, ca)
    extra_in_op = multiset_minus(ca, cb)

    cond do
      extra_in_ai != [] or extra_in_op != [] ->
        {{:line_set, Enum.sort(Enum.uniq(extra_in_op)), Enum.sort(Enum.uniq(extra_in_ai))},
         "openpairings-only lines #{inspect(Enum.sort(extra_in_op))}, " <>
           "ainalrami-only lines #{inspect(Enum.sort(extra_in_ai))}"}

      true ->
        {x, y} = first_differing_line(la, lb)
        col = first_differing_col(x, y)

        {{:field, line_code(x), field_at(col)},
         "col #{col}: openpairings #{sample(x, col)} / ainalrami #{sample(y, col)}"}
    end
  end

  defp lines(text), do: text |> String.split("\r\n") |> Enum.reject(&(&1 == ""))

  # Classify a line for set comparison. The legend/ruler block has no code of
  # its own, so it gets synthetic ones.
  defp line_code(""), do: "BLANK"

  defp line_code(line) do
    code = String.slice(line, 0, 3)

    cond do
      code == "DDD" -> "LEGEND"
      code in ~w(XXR XXP XXA XXC BBW BBD BBL BBZ BBF BBU) -> code
      String.match?(code, ~r/^\d\d\d$/) -> code
      true -> "RULER"
    end
  end

  defp multiset_minus(a, b) do
    Enum.reduce(b, a, fn x, acc -> List.delete(acc, x) end)
  end

  defp first_differing_line(la, lb) do
    Enum.zip(la, lb)
    |> Enum.find({Enum.at(la, 0) || "", Enum.at(lb, 0) || ""}, fn {x, y} -> x != y end)
  end

  # 1-indexed column of the first difference, matching TRF's own numbering.
  defp first_differing_col(x, y) do
    gx = String.graphemes(x)
    gy = String.graphemes(y)
    len = max(length(gx), length(gy))

    Enum.find(1..max(len, 1)//1, len + 1, fn i ->
      Enum.at(gx, i - 1) != Enum.at(gy, i - 1)
    end)
  end

  defp sample(line, col) do
    start = max(col - 4, 1)
    "…" <> String.slice(line, start - 1, 14) <> "…"
  end

  # ---------------------------------------------------------------
  # parse comparison
  # ---------------------------------------------------------------

  def compare_parse(text) do
    op = attempt(fn -> OP.parse(text) end)
    ai = attempt(fn -> AI.parse(text) end)

    case {op, ai} do
      {{:ok, a}, {:ok, b}} ->
        case diff_terms(a, b, "", []) do
          [] -> :identical
          causes -> {:differ, causes}
        end

      {{:ok, _}, {:raised, mod, msg}} ->
        {:differ, [{{:ainalrami_raised, inspect(mod), shape(msg)}, msg}]}

      {{:raised, mod, msg}, {:ok, _}} ->
        {:differ, [{{:openpairings_raised, inspect(mod), shape(msg)}, msg}]}

      {{:raised, m1, s1}, {:raised, m2, s2}} ->
        if shape(s1) == shape(s2) and inspect(m1) == inspect(m2),
          do: :identical_raise,
          else: {:differ, [{{:both_raised_differently, shape(s1), shape(s2)}, s1 <> " | " <> s2}]}

      {a, b} ->
        {:differ, [{{:outcome_kind, kind_of(a), kind_of(b)}, ""}]}
    end
  end

  # Structural diff. List indices are collapsed to "[]" in the path so that a
  # difference on every player groups as one cause.
  def diff_terms(a, b, path, acc) when is_map(a) and is_map(b) do
    keys = (Map.keys(a) ++ Map.keys(b)) |> Enum.uniq() |> Enum.sort()

    Enum.reduce(keys, acc, fn k, acc ->
      p = path <> "." <> to_string(k)

      case {Map.fetch(a, k), Map.fetch(b, k)} do
        {:error, {:ok, v}} -> [{{p, :only_in_ainalrami}, trunc_inspect(v)} | acc]
        {{:ok, v}, :error} -> [{{p, :only_in_openpairings}, trunc_inspect(v)} | acc]
        {{:ok, x}, {:ok, y}} -> diff_terms(x, y, p, acc)
      end
    end)
  end

  def diff_terms(a, b, path, acc) when is_list(a) and is_list(b) do
    if length(a) != length(b) do
      [{{path, :length}, "#{length(a)} vs #{length(b)}"} | acc]
    else
      Enum.zip(a, b)
      |> Enum.reduce(acc, fn {x, y}, acc -> diff_terms(x, y, path <> "[]", acc) end)
    end
  end

  def diff_terms(a, b, path, acc) do
    if a === b,
      do: acc,
      else: [{{path, :value}, "#{trunc_inspect(a)} vs #{trunc_inspect(b)}"} | acc]
  end

  defp trunc_inspect(v), do: v |> inspect() |> String.slice(0, 60)
end

# =====================================================================
# generators - plain maps in the %{tournament:, players:} shape both take
# =====================================================================

defmodule TrfGen do
  @moduledoc false

  # Borrowed wholesale from test/pairings_engine/trf_property_test.exs, minus
  # StreamData: this needs a fixed, reproducible corpus rather than shrinking,
  # so it is the same construction driven by a seeded :rand.
  @legal_pairs [
    {"1", "0"},
    {"0", "1"},
    {"0", "0"},
    {"=", "="},
    {"=", "0"},
    {"0", "="},
    {"+", "-"},
    {"-", "+"},
    {"-", "-"}
  ]

  # The three UNRATED played codes only PairingsEngine.Trf knows about.
  @unrated_pairs [{"W", "L"}, {"L", "W"}, {"D", "D"}]

  @bye_codes ~w(H F U Z)

  @names [
    "Verstraeten, Jan",
    "Hendricks, Björn",
    "Müller-Schmidt, Käthe",
    "Ødegård, Åsmund",
    "Straße, Weiß",
    "Nguyễn, Hoàng",
    "Иванов, Дмитрий",
    "Παπαδόπουλος, Γιώργος",
    "田中, 太郎",
    "A",
    "Averyveryverylongsurnamethatoverflowsthecolumn, Christopher-Alexander",
    "Ćwiąkała, Łukasz"
  ]

  def rand(list) when is_list(list), do: Enum.at(list, :rand.uniform(length(list)) - 1)

  def player(rank, opts \\ []) do
    base = %{
      rank: rank,
      name: Keyword.get(opts, :name, rand(@names)),
      federation: rand(["BEL", "NED", "FRA", "", nil]),
      title: rand(["", "GM", "IM", "WFM", nil]),
      sex: rand(["m", "w", "", nil]),
      fide_rating: rand([0, nil, 1200, 2401, 2900]),
      fide_number: rand([nil, 0, 1_234_567, 99_999_999_999]),
      birth_date: rand([nil, "", "1985-04-02"]),
      points: :rand.uniform(120) / 2,
      games: []
    }

    Enum.reduce(Keyword.get(opts, :drop, []), base, &Map.delete(&2, &1))
  end

  # One legal round over `ranks`: consecutive pairs draw a mutually-consistent
  # {code, opponent code}, the odd player out gets a bye code.
  def build_round(ranks, pool, bye_code) do
    {pairs, leftover} =
      case rem(length(ranks), 2) do
        1 -> {Enum.chunk_every(Enum.drop(ranks, 1), 2), Enum.at(ranks, 0)}
        0 -> {Enum.chunk_every(ranks, 2), nil}
      end

    games =
      pairs
      |> Enum.flat_map(fn
        [a, b] ->
          {ca, cb} = rand(pool)

          [
            {a, %{opponent_rank: b, colour: "w", result: ca}},
            {b, %{opponent_rank: a, colour: "b", result: cb}}
          ]

        [a] ->
          [{a, %{opponent_rank: nil, colour: nil, result: bye_code}}]
      end)
      |> Map.new()

    if leftover,
      do: Map.put(games, leftover, %{opponent_rank: nil, colour: nil, result: bye_code}),
      else: games
  end

  def roster(n, rounds, opts \\ []) do
    pool = Keyword.get(opts, :pool, @legal_pairs)
    players = Enum.map(1..n//1, &player(&1, opts))
    ranks = Enum.map(players, & &1.rank)

    round_maps =
      Enum.map(1..rounds//1, fn _ ->
        build_round(Enum.shuffle(ranks), pool, rand(@bye_codes))
      end)

    Enum.map(players, fn p ->
      games =
        Enum.map(
          round_maps,
          &Map.get(&1, p.rank, %{opponent_rank: nil, colour: nil, result: nil})
        )

      %{p | games: games}
    end)
  end

  def tournament(extra \\ %{}) do
    Map.merge(
      %{
        name: "Diff Open #{:rand.uniform(999)}",
        city: "Brugge",
        federation: "BEL",
        type: "swiss",
        start_date: "2026-03-01",
        end_date: "2026-03-08",
        chief_arbiter: "Peeters, An",
        time_control: "90'+30\""
      },
      extra
    )
  end

  def unrated_pairs, do: @unrated_pairs
  def legal_pairs, do: @legal_pairs
  def names, do: @names
end

# =====================================================================
# the corpus
# =====================================================================

:rand.seed(:exsss, {20_260_827, 1, 1})

# --- baseline: legal rosters, both parities, 0..5 rounds -------------
# --- unrated played codes W/D/L, which only OpenPairings lists -------
# --- a round paired but not yet played (blank result column) --------
# --- names: accents, non-Latin, overlong, control characters --------
# --- missing optional fields ----------------------------------------
# --- header lines ----------------------------------------------------
# --- fields only Ainalrami knows -------------------------------------
serialize_cases =
  [
    # --- shape and size -------------------------------------------------
    {"empty roster", %{tournament: TrfGen.tournament(), players: []}},
    {"one player, no rounds", %{tournament: TrfGen.tournament(), players: TrfGen.roster(1, 0)}},
    {"one player, byes only", %{tournament: TrfGen.tournament(), players: TrfGen.roster(1, 3)}}
  ] ++
    for n <- [2, 3, 8, 9, 40, 41], r <- 0..5 do
      {"baseline n=#{n} r=#{r}", %{tournament: TrfGen.tournament(), players: TrfGen.roster(n, r)}}
    end ++
    for n <- [2, 6, 7], r <- 1..3 do
      {"unrated W/D/L n=#{n} r=#{r}",
       %{
         tournament: TrfGen.tournament(),
         players: TrfGen.roster(n, r, pool: TrfGen.unrated_pairs())
       }}
    end ++
    for n <- [4, 10], r <- 2..3 do
      {"mixed rated+unrated n=#{n} r=#{r}",
       %{
         tournament: TrfGen.tournament(),
         players: TrfGen.roster(n, r, pool: TrfGen.legal_pairs() ++ TrfGen.unrated_pairs())
       }}
    end ++
    [
      {"round in progress: blank result on last round",
       %{
         tournament: TrfGen.tournament(),
         players: [
           %{
             rank: 1,
             name: "Alpha, One",
             points: 1.0,
             games: [
               %{opponent_rank: 2, colour: "w", result: "1"},
               %{opponent_rank: 2, colour: "b", result: nil}
             ]
           },
           %{
             rank: 2,
             name: "Bravo, Two",
             points: 0.0,
             games: [
               %{opponent_rank: 1, colour: "b", result: "0"},
               %{opponent_rank: 1, colour: "w", result: nil}
             ]
           }
         ]
       }},
      {"round in progress: single unplayed round",
       %{
         tournament: TrfGen.tournament(),
         players: [
           %{
             rank: 1,
             name: "Alpha, One",
             points: 0.0,
             games: [%{opponent_rank: 2, colour: "w", result: nil}]
           },
           %{
             rank: 2,
             name: "Bravo, Two",
             points: 0.0,
             games: [%{opponent_rank: 1, colour: "b", result: nil}]
           }
         ]
       }},
      {"late entrant: leading blank round",
       %{
         tournament: TrfGen.tournament(),
         players: [
           %{
             rank: 1,
             name: "Alpha, One",
             points: 1.0,
             games: [
               %{opponent_rank: nil, colour: nil, result: "U"},
               %{opponent_rank: 2, colour: "w", result: "1"}
             ]
           },
           %{
             rank: 2,
             name: "Bravo, Two",
             points: 0.0,
             games: [
               %{opponent_rank: nil, colour: nil, result: nil},
               %{opponent_rank: 1, colour: "b", result: "0"}
             ]
           }
         ]
       }}
    ] ++
    for name <- TrfGen.names() do
      {"name fidelity: #{String.slice(name, 0, 18)}",
       %{
         tournament: TrfGen.tournament(),
         players: [%{rank: 1, name: name, points: 0.0, federation: "BEL", games: []}]
       }}
    end ++
    [
      {"control characters in name",
       %{
         tournament: TrfGen.tournament(),
         players: [%{rank: 1, name: "Alpha,\tOne\r\nInjected", points: 0.0, games: []}]
       }},
      {"accented tournament header",
       %{
         tournament:
           TrfGen.tournament(%{
             name: "Österreichische Meisterschaft",
             city: "Liège",
             chief_arbiter: "Nguyễn, Hoàng"
           }),
         players: TrfGen.roster(4, 1)
       }}
    ] ++
    [
      {"players missing every optional key",
       %{
         tournament: %{name: "Bare", type: "swiss"},
         players: [%{rank: 1, name: "Solo, Player", points: 0.0, games: []}]
       }},
      {"player map without :games key",
       %{tournament: %{name: "Bare", type: "swiss"}, players: [%{rank: 1, name: "Solo, Player"}]}},
      {"tournament with only a name",
       %{tournament: %{name: "Bare"}, players: TrfGen.roster(4, 1)}},
      {"rating 0 and nil, fide number 0 and nil",
       %{
         tournament: TrfGen.tournament(),
         players: [
           %{
             rank: 1,
             name: "Zero, Rating",
             fide_rating: 0,
             fide_number: 0,
             points: 0.0,
             games: []
           },
           %{
             rank: 2,
             name: "Nil, Rating",
             fide_rating: nil,
             fide_number: nil,
             points: nil,
             games: []
           }
         ]
       }}
    ] ++
    [
      {"round dates",
       %{
         tournament:
           TrfGen.tournament(%{round_dates: ["2026-03-01", "2026-03-02", "2026-03-03"]}),
         players: TrfGen.roster(4, 3)
       }},
      {"round dates all blank",
       %{
         tournament: TrfGen.tournament(%{round_dates: [nil, "", nil]}),
         players: TrfGen.roster(4, 3)
       }},
      {"deputy arbiters",
       %{
         tournament: TrfGen.tournament(%{deputy_arbiters: ["De Smet, Jo", "Claes, Ine"]}),
         players: TrfGen.roster(4, 1)
       }},
      {"number_of_rounds + rated players + generator",
       %{
         tournament:
           TrfGen.tournament(%{
             number_of_rounds: 9,
             number_of_rated_players: 3,
             generator: "OpenPairings 0.17.1"
           }),
         players: TrfGen.roster(4, 1)
       }},
      {"unknown tournament type label",
       %{tournament: TrfGen.tournament(%{type: "knockout"}), players: TrfGen.roster(4, 1)}},
      {"teams",
       %{
         tournament: TrfGen.tournament(%{type: "team-swiss"}),
         players: TrfGen.roster(6, 2),
         teams: [
           %{name: "KGSRL", player_ranks: [1, 2, 3]},
           %{name: "Deurne", player_ranks: [4, 5, 6]}
         ]
       }}
    ] ++
    [
      {"initial_colour (152)",
       %{tournament: TrfGen.tournament(%{initial_colour: "b"}), players: TrfGen.roster(4, 1)}},
      {"point_system (BB*)",
       %{
         tournament:
           TrfGen.tournament(%{
             point_system: %{
               win: 3.0,
               draw: 1.0,
               loss: 0.0,
               pairing_allocated_bye: 1.0,
               forfeit_loss: 0.0,
               zero_point_bye: 0.0
             }
           }),
         players: TrfGen.roster(4, 1)
       }},
      {"forbidden_pairs (XXP)",
       %{
         tournament: TrfGen.tournament(%{forbidden_pairs: [[1, 2], [3, 4, 5]]}),
         players: TrfGen.roster(6, 1)
       }},
      {"accelerations (XXA)",
       %{
         tournament: TrfGen.tournament(),
         players: TrfGen.roster(4, 1) |> Enum.map(&Map.put(&1, :accelerations, [1.0, 1.0, 0.0]))
       }}
    ]

# Every case is run under three option sets - the two known option gaps plus
# the default.
option_sets = [
  {"default", []},
  {"ascii: true", [ascii: true]},
  {"column_legend: true", [column_legend: true]}
]

IO.puts("\n=== SERIALIZE ===\n")

serialize_results =
  for {label, data} <- serialize_cases, {oname, opts} <- option_sets do
    {label, oname, TrfDiff.compare_serialize(data, opts)}
  end

# =====================================================================
# parse corpus
# =====================================================================

fixture_files =
  (Path.wildcard("../openpair/test/fixtures/**/*.trf") ++
     Path.wildcard("test/**/*.trf") ++
     Path.wildcard("priv/**/*.trf"))
  |> Enum.uniq()

# Hand-built texts aimed at the parser rather than at the writer: every
# extension line, both line-ending conventions, TRF06 vintage, blank blocks.
crlf = fn lines -> Enum.map_join(lines, "", &(&1 <> "\r\n")) end

base_player = fn rank, name, games ->
  String.pad_trailing("001 " <> String.pad_leading("#{rank}", 4), 14) <>
    String.pad_trailing(name, 33) <>
    " 2000 BEL      1234567 1985/04/02  1.0    1" <> games
end

synthetic_parse_cases = [
  {"unrated codes W/D/L in the result column",
   crlf.([
     "012 Unrated Test",
     "062 2",
     base_player.(1, "Alpha, One", "     2 w W"),
     base_player.(2, "Bravo, Two", "     1 b L")
   ])},
  {"unrated draw D/D",
   crlf.([
     "012 Unrated Draw",
     base_player.(1, "Alpha, One", "     2 w D"),
     base_player.(2, "Bravo, Two", "     1 b D")
   ])},
  {"TRF06 vintage: dangling playing code against 0000",
   crlf.([
     "012 Vintage",
     base_player.(1, "Alpha, One", "  0000 - 1"),
     base_player.(2, "Bravo, Two", "  0000 - 0")
   ])},
  {"fully blank round block followed by a real game",
   crlf.([
     "012 Late Entrant",
     base_player.(1, "Alpha, One", "          " <> "     2 w 1"),
     base_player.(2, "Bravo, Two", "          " <> "     1 b 0")
   ])},
  {"XXR round count", crlf.(["012 XXR", "XXR 9", base_player.(1, "Alpha, One", "  0000 - U")])},
  {"XXR disagreeing with 142",
   crlf.(["012 XXR clash", "142 9", "XXR 5", base_player.(1, "Alpha, One", "  0000 - U")])},
  {"XXR agreeing with 142",
   crlf.(["012 XXR agree", "142 9", "XXR 9", base_player.(1, "Alpha, One", "  0000 - U")])},
  {"XXP forbidden pair",
   crlf.([
     "012 XXP",
     base_player.(1, "Alpha, One", "  0000 - U"),
     base_player.(2, "Bravo, Two", "  0000 - U"),
     "XXP 1 2"
   ])},
  {"XXP malformed",
   crlf.(["012 XXP bad", base_player.(1, "Alpha, One", "  0000 - U"), "XXP 1 abc"])},
  {"XXA acceleration",
   crlf.(["012 XXA", base_player.(1, "Alpha, One", "  0000 - U"), "XXA    1  1.0  1.0"])},
  {"XXC white1", crlf.(["012 XXC", "XXC white1", base_player.(1, "Alpha, One", "  0000 - U")])},
  {"XXC black1", crlf.(["012 XXC", "XXC black1", base_player.(1, "Alpha, One", "  0000 - U")])},
  {"XXC rank", crlf.(["012 XXC", "XXC rank", base_player.(1, "Alpha, One", "  0000 - U")])},
  {"152 initial colour",
   crlf.(["012 152", "152 B", base_player.(1, "Alpha, One", "  0000 - U")])},
  {"250 acceleration range",
   crlf.([
     "012 250",
     base_player.(1, "Alpha, One", "  0000 - U"),
     "250        1.0   1   2    1    1"
   ])},
  # Built by column rather than typed out: `readForbiddenPairs260`
  # (trf.cpp:519-548) puts the first round in 5-7, the last in 9-11 and each
  # id in a four-character field every five columns from 13. A hand-typed
  # line that misses those columns measures the fixture, not the parser.
  {"260 round-limited forbidden pair",
   crlf.([
     "012 260",
     base_player.(1, "Alpha, One", "  0000 - U"),
     base_player.(2, "Bravo, Two", "  0000 - U"),
     "260 " <>
       String.pad_leading("1", 3) <>
       " " <>
       String.pad_leading("9", 3) <>
       " " <> String.pad_leading("1", 4) <> " " <> String.pad_leading("2", 4)
   ])},
  {"BB* point system",
   crlf.([
     "012 BB",
     "BBW  3.0",
     "BBD  1.0",
     "BBU  1.0",
     base_player.(1, "Alpha, One", "  0000 - U")
   ])},
  # `readPointSystem` (trf.cpp:573-631) reads nine columns per entry from
  # column 6: one symbol then a four-column score, then four columns of gap.
  {"162 packed point system",
   crlf.([
     "012 162",
     "162  " <> "W 3.0    " <> "D 1.0    " <> "L 0.0    ",
     base_player.(1, "Alpha, One", "  0000 - U")
   ])},
  {"bare CR line endings (bbpPairings' own output convention)",
   Enum.map_join(
     ["012 Bare CR", "062 1", base_player.(1, "Alpha, One", "  0000 - U")],
     "",
     &(&1 <> "\r")
   )},
  {"bare LF line endings",
   Enum.map_join(
     ["012 Bare LF", "062 1", base_player.(1, "Alpha, One", "  0000 - U")],
     "",
     &(&1 <> "\n")
   )},
  {"teams",
   crlf.([
     "012 Teams",
     "082 1",
     base_player.(1, "Alpha, One", "  0000 - U"),
     "013 KGSRL                            1"
   ])},
  {"round dates 132",
   crlf.(["012 Dates", String.pad_trailing("132", 91) <> " 26/03/01 26/03/02"])},
  {"unknown extension code",
   crlf.([
     "012 Unknown",
     "XXZ whatever",
     "999 nonsense",
     base_player.(1, "Alpha, One", "  0000 - U")
   ])}
]

# Anything the two serialisers agreed on is also fed back through both
# parsers - the round trip is where a writer/reader disagreement shows.
serialized_texts =
  serialize_cases
  |> Enum.flat_map(fn {label, data} ->
    # Whichever writer accepts the case supplies the text; if both do and they
    # agree, one copy is enough. A case only OpenPairings can write (the
    # unrated codes) still gets its text read back by both parsers.
    [AI, OP]
    |> Enum.map(fn mod -> TrfDiff.attempt(fn -> mod.serialize(data, []) end) end)
    |> Enum.flat_map(fn
      {:ok, text} -> [text]
      _ -> []
    end)
    |> Enum.uniq()
    |> Enum.map(&{"round-trip: " <> label, &1})
  end)

file_cases =
  for path <- fixture_files do
    {"fixture: " <> Path.basename(path), File.read!(path)}
  end

parse_cases = synthetic_parse_cases ++ file_cases ++ serialized_texts

IO.puts("\n=== PARSE ===\n")

parse_results =
  for {label, text} <- parse_cases do
    {label, "-", TrfDiff.compare_parse(text)}
  end

# =====================================================================
# report
# =====================================================================

report = fn title, results ->
  total = length(results)

  {same, differing} =
    Enum.split_with(results, fn {_, _, r} -> r in [:identical, :identical_raise] end)

  groups =
    differing
    |> Enum.flat_map(fn {label, opts, {:differ, causes}} ->
      Enum.map(causes, fn {key, detail} -> {key, {"#{label} [#{opts}]", detail}} end)
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

  IO.puts("--------------------------------------------------------------")
  IO.puts(title)
  IO.puts("  cases run:       #{total}")
  IO.puts("  identical:       #{length(same)}")
  IO.puts("  differing:       #{length(differing)}")
  IO.puts("  distinct causes: #{map_size(groups)}")
  IO.puts("")

  groups
  |> Enum.sort_by(fn {_cause, cases} -> -length(cases) end)
  |> Enum.with_index(1)
  |> Enum.each(fn {{cause, cases}, i} ->
    {_first_label, detail} = hd(cases)

    IO.puts("  [#{i}] #{length(cases)} case(s)")
    IO.puts("      cause:  #{inspect(cause)}")
    IO.puts("      detail: #{detail}")
    IO.puts("      e.g.:   #{cases |> Enum.take(3) |> Enum.map_join(" | ", &elem(&1, 0))}")
    IO.puts("")
  end)
end

report.("SERIALIZE  (PairingsEngine.Trf vs Ainalrami.Trf)", serialize_results)
report.("PARSE      (PairingsEngine.Trf vs Ainalrami.Trf)", parse_results)

# =====================================================================
# round-trip fidelity, per module against itself
# =====================================================================
#
# A byte difference only matters if it changes what a reader gets back. Each
# module writes a case and reads its OWN output, and the round count is
# compared against what went in - the direct test of whether trimming the
# last round block off a `001` line loses it.

roundtrip_results =
  for {label, data} <- serialize_cases, mod <- [OP, AI] do
    expected = Enum.reduce(data.players, 0, &max(&2, length(&1[:games] || [])))

    outcome =
      case TrfDiff.attempt(fn -> mod.serialize(data, []) end) do
        {:ok, text} ->
          case TrfDiff.attempt(fn -> mod.parse(text) end) do
            {:ok, parsed} ->
              got = Enum.reduce(parsed.players, 0, &max(&2, length(&1[:games] || [])))
              if got == expected, do: :ok, else: {:lost_rounds, expected, got}

            other ->
              {:parse_failed, elem(other, 0)}
          end

        other ->
          {:serialize_failed, elem(other, 0)}
      end

    {label, mod, outcome}
  end

IO.puts("--------------------------------------------------------------")
IO.puts("ROUND-TRIP FIDELITY  (each module writes and reads back its own output)")

for mod <- [OP, AI] do
  mine = Enum.filter(roundtrip_results, fn {_, m, _} -> m == mod end)
  lost = Enum.filter(mine, fn {_, _, o} -> match?({:lost_rounds, _, _}, o) end)
  failed = Enum.filter(mine, fn {_, _, o} -> match?({:serialize_failed, _}, o) end)

  IO.puts(
    "  #{inspect(mod)}: #{length(mine)} cases, " <>
      "#{length(lost)} lost a round on the way back, " <>
      "#{length(failed)} could not be written at all"
  )

  lost
  |> Enum.take(4)
  |> Enum.each(fn {label, _, {:lost_rounds, want, got}} ->
    IO.puts("      #{label}: wrote #{want} rounds, read back #{got}")
  end)
end

IO.puts("")

# --- the four production-surface entry points -------------------------

IO.puts("--------------------------------------------------------------")
IO.puts("PUBLIC SURFACE")

for {mod, name} <- [{OP, "PairingsEngine.Trf"}, {AI, "Ainalrami.Trf"}] do
  exports = mod.__info__(:functions) |> Enum.sort()
  IO.puts("  #{name}: #{inspect(exports)}")
end

IO.puts("")
IO.puts("RESULT-CODE ACCEPTANCE  (does serialize/2 accept this code at all?)")

# Measured rather than read off the private @playing_codes: each code is put
# in a mutually-consistent two-player pairing (or an opponentless bye where
# that is the code's only legal use) and the two writers are asked to write
# it. This is the same question `Standings.presence_earning_codes/0` and
# `TrfImport`'s compile-time `@playing_codes` ask.
code_probes = [
  {"1", {"1", "0"}},
  {"=", {"=", "="}},
  {"0", {"0", "1"}},
  {"+", {"+", "-"}},
  {"-", {"-", "+"}},
  {"W", {"W", "L"}},
  {"D", {"D", "D"}},
  {"L", {"L", "W"}},
  {"H", :bye},
  {"F", :bye},
  {"U", :bye},
  {"Z", :bye}
]

for {code, spec} <- code_probes do
  players =
    case spec do
      :bye ->
        [
          %{
            rank: 1,
            name: "Solo, Player",
            points: 0.0,
            games: [%{opponent_rank: nil, colour: nil, result: code}]
          }
        ]

      {a, b} ->
        [
          %{
            rank: 1,
            name: "Alpha, One",
            points: 0.0,
            games: [%{opponent_rank: 2, colour: "w", result: a}]
          },
          %{
            rank: 2,
            name: "Bravo, Two",
            points: 0.0,
            games: [%{opponent_rank: 1, colour: "b", result: b}]
          }
        ]
    end

  data = %{tournament: %{name: "Codes", type: "swiss"}, players: players}

  verdict = fn mod ->
    case TrfDiff.attempt(fn -> mod.serialize(data, []) end) do
      {:ok, _} -> "accepted"
      {:raised, _, _} -> "REJECTED"
      _ -> "error"
    end
  end

  IO.puts("  #{code}: openpairings #{verdict.(OP)} / ainalrami #{verdict.(AI)}")
end

IO.puts("")
IO.puts("  PairingsEngine.Trf.playing_codes/0: #{inspect(OP.playing_codes())}")
IO.puts("  PairingsEngine.Trf.bye_codes/0:     #{inspect(OP.bye_codes())}")

IO.puts(
  "  Ainalrami.Trf.playing_codes/0:      #{if function_exported?(AI, :playing_codes, 0), do: inspect(AI.playing_codes()), else: "NOT EXPORTED"}"
)

IO.puts(
  "  Ainalrami.Trf.bye_codes/0:          #{if function_exported?(AI, :bye_codes, 0), do: inspect(AI.bye_codes()), else: "NOT EXPORTED"}"
)

IO.puts("  PairingsEngine.Trf.result_codes/0:  #{inspect(OP.result_codes())}")
IO.puts("  Ainalrami.Trf.result_codes/0:       #{inspect(AI.result_codes())}")
IO.puts("")
