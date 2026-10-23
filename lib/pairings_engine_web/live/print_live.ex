defmodule PairingsEngineWeb.PrintLive do
  use PairingsEngineWeb, :live_view

  alias PairingsEngine.Tournaments

  # The ticks beside the schedule and the player cards, each one a query
  # parameter of the document's link (`SchedulePrintController`). The
  # documents print everything there is unless told otherwise, so only a
  # tick moved off its default reaches the link.
  @default_options %{
    "schedule_results" => true,
    "schedule_postponed" => true,
    "schedule_boards" => true,
    "cards_blank" => false
  }

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    tournament = Tournaments.get_authorized_tournament!(socket.assigns.current_scope, id)

    # The list of documents depends on what is paired and what is postponed,
    # which change while this page is open in a tab beside the Pairings page.
    if connected?(socket) do
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))
    end

    {:ok,
     assign(socket,
       tournament: tournament,
       page_title: "#{tournament.name} · #{gettext("Print")}",
       # Standings, cross table and prize lists printed while a postponed
       # game is still to be played are provisional: the page says so
       # before anything is printed, with a link to each game.
       postponed_open: PairingsEngine.PostponedGames.open_games(tournament),
       category: nil,
       options: @default_options
     )}
  end

  # The chosen category lives in the URL (`?category=`), so a reload keeps it.
  # A name the tournament does not list is dropped rather than trusted.
  @impl true
  def handle_params(params, _uri, socket) do
    wanted = params["category"]

    category =
      if is_binary(wanted) and wanted != "" and
           wanted in (socket.assigns.tournament.categories || []),
         do: wanted

    {:noreply, assign(socket, :category, category)}
  end

  @impl true
  def handle_info({:tournament_changed, _tournament_id, _hint}, socket) do
    case Tournaments.get_authorized_tournament(
           socket.assigns.current_scope,
           socket.assigns.tournament.id
         ) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("This tournament was deleted."))
         |> push_navigate(to: ~p"/")}

      tournament ->
        {:noreply,
         assign(socket,
           tournament: tournament,
           postponed_open: PairingsEngine.PostponedGames.open_games(tournament)
         )}
    end
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def handle_event("pick_category", params, socket) do
    id = socket.assigns.tournament.id

    to =
      case params["category"] do
        name when is_binary(name) and name != "" -> ~p"/t/#{id}/print?#{[category: name]}"
        _ -> ~p"/t/#{id}/print"
      end

    {:noreply, push_patch(socket, to: to)}
  end

  def handle_event("toggle_option", %{"key" => key}, socket) do
    options = socket.assigns.options

    {:noreply,
     if(Map.has_key?(options, key),
       do: assign(socket, :options, Map.update!(options, key, &(not &1))),
       else: socket
     )}
  end

  # The query a document's ticks add to its link: `results=0`,
  # `postponed=0`, `boards=0` for a schedule with that part left off,
  # `blank=1` for empty player cards.
  defp with_options(nil, _keys, _options), do: nil

  defp with_options(href, keys, options) do
    query =
      Enum.flat_map(keys, fn key ->
        value = Map.fetch!(options, key)

        if value == Map.fetch!(@default_options, key),
          do: [],
          else: [{option_param(key), if(value, do: "1", else: "0")}]
      end)

    case query do
      [] ->
        href

      query ->
        href <> if(String.contains?(href, "?"), do: "&", else: "?") <> URI.encode_query(query)
    end
  end

  defp option_param("schedule_results"), do: "results"
  defp option_param("schedule_postponed"), do: "postponed"
  defp option_param("schedule_boards"), do: "boards"
  defp option_param("cards_blank"), do: "blank"

  defp option_label("schedule_results"), do: gettext("with results")
  defp option_label("schedule_postponed"), do: gettext("with postponed dates")
  defp option_label("schedule_boards"), do: gettext("with board line-ups")
  defp option_label("cards_blank"), do: gettext("blank, to fill in by hand")

  # Appends `category=<name>` to a document link that supports filtering,
  # URL-encoded. "All players" and the unavailable (nil) links stay as they are.
  defp with_category(nil, _category), do: nil
  defp with_category(href, nil), do: href

  defp with_category(href, category) do
    sep = if String.contains?(href, "?"), do: "&", else: "?"
    href <> sep <> URI.encode_query([{"category", category}])
  end

  defp documents(tournament, postponed_open, category, options) do
    rounds_paired = PairingsEngine.Standings.rounds_paired(tournament.id)
    latest = max(rounds_paired, 1)

    (team_documents(tournament, rounds_paired, latest) ++
       Enum.map(
         individual_documents(tournament, rounds_paired, latest),
         &%{&1 | href: with_category(&1.href, category)}
       ) ++
       postponed_documents(tournament, postponed_open))
    |> Enum.map(&%{&1 | href: with_options(&1.href, Map.get(&1, :options, []), options)})
  end

  # The whole schedule, every round paired or not, for a tournament whose
  # rounds are fixed in advance: a round robin. Swiss has no schedule to
  # print until it is played, which is what the pairing list is for.
  defp schedule_document(tournament) do
    if PairingsEngine.PrintSchedule.round_robin?(tournament) and
         not PairingsEngine.Tournaments.Tournament.team_round_robin?(tournament) do
      [
        %{
          id: "print-doc-schedule",
          name: gettext("Schedule (all rounds)"),
          desc:
            gettext(
              "Every round of the round robin with its date and boards, including the rounds not paired yet, as the Berger table will pair them."
            ),
          href: ~p"/t/#{tournament.id}/print/schedule",
          options: ["schedule_results", "schedule_postponed"]
        }
      ]
    else
      []
    end
  end

  # The notice each player of a postponed game gets: round, board, opponent,
  # agreed date and venue. Listed only while a game is still to be played.
  defp postponed_documents(_tournament, []), do: []

  defp postponed_documents(tournament, _open) do
    [
      %{
        id: "print-postponed-notices",
        name: gettext("Postponed-game notices"),
        desc:
          gettext(
            "One slip per player of every postponed game still to be played: round, board, opponent, agreed date and venue."
          ),
        href: ~p"/t/#{tournament.id}/print/postponed"
      }
    ]
  end

  # A tournament paired as teams leads with its own sheets: the matches with their
  # boards, and the team table. The individual documents stay below - result
  # slips, score sheets and the player list are still per board and per player.
  defp team_documents(tournament, rounds_paired, latest) do
    if PairingsEngine.Tournaments.Tournament.paired_as_teams?(tournament) do
      team_schedule_documents(tournament) ++
        [
          %{
            name: gettext("Team pairings (latest round)"),
            desc: gettext("Each match, team against team, with its board lines."),
            href:
              if(rounds_paired > 0,
                do: ~p"/t/#{tournament.id}/print/team-pairings?round=#{latest}"
              )
          },
          %{
            name: gettext("Team standings"),
            desc: gettext("Teams ranked by match points, with the team tie-breaks."),
            href: if(rounds_paired > 0, do: ~p"/t/#{tournament.id}/print/team-standings")
          },
          %{
            id: "print-team-crosstable",
            name: gettext("Team cross table"),
            desc:
              gettext(
                "Round robin: team against team with the game points of each match. Swiss: per round the opponent, the colour of board 1, the match score and the running match points."
              ),
            href: if(rounds_paired > 0, do: ~p"/t/#{tournament.id}/print/team-crosstable")
          },
          %{
            id: "print-team-match-sheets",
            name: gettext("Match result sheets (latest round)"),
            desc:
              gettext(
                "One A4 sheet per match: both line-ups with colours and ratings, result boxes, the match score, captain and arbiter signatures."
              ),
            href:
              if(rounds_paired > 0,
                do: ~p"/t/#{tournament.id}/print/team-match-sheets?round=#{latest}"
              )
          },
          %{
            id: "print-team-rosters",
            name: gettext("Team rosters"),
            desc: gettext("Each team's board order with ratings, FIDE IDs and federations."),
            href: ~p"/t/#{tournament.id}/print/team-rosters"
          },
          %{
            id: "print-board-prizes",
            name: gettext("Board prizes"),
            desc:
              gettext(
                "Per board number, the players ranked by percentage, points and performance."
              ),
            href: if(rounds_paired > 0, do: ~p"/t/#{tournament.id}/print/board-prizes")
          }
        ]
    else
      []
    end
  end

  # A team round robin's schedule: every round's matches, and one sheet per
  # team with its own rounds.
  defp team_schedule_documents(tournament) do
    if PairingsEngine.Tournaments.Tournament.team_round_robin?(tournament) do
      [
        %{
          id: "print-doc-team-schedule",
          name: gettext("Schedule (all rounds)"),
          desc:
            gettext(
              "Every round with its date and matches, board by board, including the rounds not paired yet, as the Berger table will pair them."
            ),
          href: ~p"/t/#{tournament.id}/print/team-schedule",
          options: ["schedule_results", "schedule_postponed", "schedule_boards"]
        },
        %{
          id: "print-doc-team-cards",
          name: gettext("Team schedules"),
          desc:
            gettext(
              "One schedule per team: opponent, date, colour on board 1, match score and match points, round by round."
            ),
          href: ~p"/t/#{tournament.id}/print/team-cards",
          options: ["schedule_results"]
        }
      ]
    else
      []
    end
  end

  defp individual_documents(tournament, rounds_paired, latest) do
    [
      %{
        id: "print-doc-players",
        name: gettext("Player list"),
        desc: gettext("All registered players with ratings, federation and club."),
        href: ~p"/t/#{tournament.id}/print/players"
      },
      %{
        id: "print-doc-cards",
        name: gettext("Player cards"),
        desc:
          if(PairingsEngine.PrintSchedule.round_robin?(tournament),
            do:
              gettext(
                "One card per player with every round: date, opponent, colour, result and running score."
              ),
            else:
              gettext(
                "One card per player, round by round: the rounds played filled in, the rest to fill in."
              )
          ),
        href: ~p"/t/#{tournament.id}/print/cards",
        options: ["cards_blank"]
      }
    ] ++
      schedule_document(tournament) ++
      [
        %{
          id: "print-doc-pairings",
          name: gettext("Pairing list (latest round)"),
          desc: gettext("Board-by-board pairings for posting at the venue."),
          href: if(rounds_paired > 0, do: ~p"/t/#{tournament.id}/print/pairings?round=#{latest}")
        },
        %{
          id: "print-doc-standings",
          name: gettext("Standings"),
          desc: gettext("Current ranking with points and tiebreaks."),
          href: if(rounds_paired > 0, do: ~p"/t/#{tournament.id}/print/standings")
        },
        %{
          id: "print-doc-results",
          name: gettext("Result cards (latest round)"),
          desc: gettext("One slip per board to record the result over the board."),
          href: if(rounds_paired > 0, do: ~p"/t/#{tournament.id}/print/results?round=#{latest}")
        },
        %{
          id: "print-doc-pairings-alpha",
          name: gettext("Alphabetical pairing list"),
          desc: gettext("\"Where do I sit\" list, sorted by player name."),
          href:
            if(rounds_paired > 0,
              do: ~p"/t/#{tournament.id}/print/pairings-alpha?round=#{latest}"
            )
        },
        %{
          id: "print-doc-scoresheets",
          name: gettext("Score sheets"),
          desc: gettext("Pre-filled per board: names, ratings, move columns, signatures."),
          href:
            if(rounds_paired > 0, do: ~p"/t/#{tournament.id}/print/scoresheets?round=#{latest}")
        },
        %{
          id: "print-doc-crosstable",
          name: gettext("Cross table"),
          desc: gettext("Full results grid of the tournament."),
          href: ~p"/t/#{tournament.id}/print/crosstable"
        },
        %{
          id: "print-doc-placecards",
          name: gettext("Place cards"),
          desc: gettext("A folded name card per player, to stand at their seat."),
          href: ~p"/t/#{tournament.id}/print/placecards"
        },
        %{
          id: "print-doc-next-round-preview",
          name: gettext("Next round preview"),
          desc:
            gettext(
              "The next round's boards that are already certain. Work it out on the Pairings page first; until then there is nothing to print."
            ),
          disabled_reason: gettext("Work out the preview on the Pairings page first"),
          href:
            if(next_round_preview_ready?(tournament),
              do: ~p"/t/#{tournament.id}/print/next-round-preview"
            )
        }
      ]
  end

  # The controller refuses (409) a preview the Pairings page has not worked
  # out for the tournament as it is now, so the link is only offered when it
  # would print something.
  defp next_round_preview_ready?(tournament) do
    fingerprint = PairingsEngine.NextRoundPreview.fingerprint(tournament.id)
    PairingsEngine.NextRoundPreview.Cache.get(tournament.id, fingerprint) != nil
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      publish_status={assigns[:publish_status]}
      update_notice={assigns[:update_notice]}
      fide_notice={assigns[:fide_notice]}
      flash={@flash}
      current_path={assigns[:current_path]}
      current_scope={@current_scope}
      tournament={@tournament}
      active="print"
    >
      <div class="page-header">
        <div>
          <h1>{@tournament.name}</h1>

          <p class="subtitle" style="margin: 0">{gettext("Print documents")}</p>
        </div>
      </div>

      <PairingsEngineWeb.Postponed.unplayed_guard
        tournament={@tournament}
        games={@postponed_open}
        id="print-postponed-unplayed"
        note={
          gettext(
            "Standings, the cross table and prize lists printed now are provisional: each postponed game counts provisionally until its result is entered."
          )
        }
      />
      <form
        :if={@tournament.categories != []}
        id="print-category-form"
        class="card mb-4 flex flex-wrap items-center gap-3"
        phx-change="pick_category"
      >
        <label for="print-category" class="font-semibold">{gettext("Print for")}</label>
        <select id="print-category" name="category" class="pe-select">
          <option value="" selected={@category == nil}>{gettext("All players")}</option>
          <option :for={name <- @tournament.categories} value={name} selected={@category == name}>
            {name}
          </option>
        </select>
        <span class="hint">
          {gettext(
            "Applies to the player list, cards, pairings, result slips, score sheets, standings and cross table."
          )}
        </span>
      </form>

      <div class="card table-card">
        <table class="pe-table">
          <thead>
            <tr>
              <th>{gettext("Document")}</th>

              <th>{gettext("Description")}</th>

              <th><span class="sr-only">{gettext("Actions")}</span></th>
            </tr>
          </thead>

          <tbody>
            <tr
              :for={doc <- documents(@tournament, @postponed_open, @category, @options)}
              id={doc[:id]}
            >
              <td><strong>{doc.name}</strong></td>

              <td class="hint">
                {doc.desc}
                <span
                  :if={doc[:options] not in [nil, []]}
                  class="mt-1 flex flex-wrap gap-x-4 gap-y-1"
                  id={"#{doc[:id]}-options"}
                >
                  <label
                    :for={key <- doc[:options]}
                    class="inline-flex cursor-pointer items-center gap-1.5"
                  >
                    <input
                      type="checkbox"
                      id={"#{doc[:id]}-#{key}"}
                      checked={@options[key]}
                      phx-click="toggle_option"
                      phx-value-key={key}
                    />
                    {option_label(key)}
                  </label>
                </span>
              </td>

              <td style="text-align: right">
                <a :if={doc.href} class="pe-btn primary" href={doc.href} target="_blank">{gettext(
                  "Print…"
                )}</a>
                <button
                  :if={!doc.href}
                  class="pe-btn"
                  disabled
                  title={doc[:disabled_reason] || gettext("Available once rounds are paired")}
                >
                  {gettext("Print…")}
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div class="card mt-4 flex flex-wrap items-center justify-between gap-3" id="print-badges">
        <div>
          <strong>{gettext("Accreditation badges")}</strong>
          <p class="hint m-0">
            {gettext(
              "A6 badges for the players and officials, plus press and guests, two to an A4 sheet."
            )}
          </p>
        </div>

        <.link href={~p"/t/#{@tournament.id}/badges"} class="pe-btn" id="print-badges-link">
          {gettext("Badges…")}
        </.link>
      </div>
    </Layouts.app>
    """
  end
end
