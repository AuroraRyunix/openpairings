defmodule PairingsEngineWeb.PrintLive do
  use PairingsEngineWeb, :live_view

  alias PairingsEngine.Tournaments

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    tournament = Tournaments.get_authorized_tournament!(socket.assigns.current_scope, id)

    {:ok,
     assign(socket,
       tournament: tournament,
       page_title: "#{tournament.name} · Print",
       # Standings, cross table and prize lists printed while a postponed
       # game is still to be played are provisional: the page says so
       # before anything is printed, with a link to each game.
       postponed_open: PairingsEngine.PostponedGames.open_games(tournament),
       category: nil
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
  def handle_event("pick_category", params, socket) do
    id = socket.assigns.tournament.id

    to =
      case params["category"] do
        name when is_binary(name) and name != "" -> ~p"/t/#{id}/print?#{[category: name]}"
        _ -> ~p"/t/#{id}/print"
      end

    {:noreply, push_patch(socket, to: to)}
  end

  # Appends `category=<name>` to a document link that supports filtering,
  # URL-encoded. "All players" and the unavailable (nil) links stay as they are.
  defp with_category(nil, _category), do: nil
  defp with_category(href, nil), do: href

  defp with_category(href, category) do
    sep = if String.contains?(href, "?"), do: "&", else: "?"
    href <> sep <> URI.encode_query([{"category", category}])
  end

  defp documents(tournament, postponed_open, category) do
    rounds_paired = PairingsEngine.Standings.rounds_paired(tournament.id)
    latest = max(rounds_paired, 1)

    team_documents(tournament, rounds_paired, latest) ++
      Enum.map(
        individual_documents(tournament, rounds_paired, latest),
        &%{&1 | href: with_category(&1.href, category)}
      ) ++
      postponed_documents(tournament, postponed_open)
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
            gettext("Per board number, the players ranked by percentage, points and performance."),
          href: if(rounds_paired > 0, do: ~p"/t/#{tournament.id}/print/board-prizes")
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
        name: "Player list",
        desc: "All registered players with ratings, federation and club.",
        href: ~p"/t/#{tournament.id}/print/players"
      },
      %{
        id: "print-doc-cards",
        name: "Player cards",
        desc: "One card per player with their round-by-round schedule to fill in.",
        href: ~p"/t/#{tournament.id}/print/cards"
      },
      %{
        id: "print-doc-pairings",
        name: "Pairing list (latest round)",
        desc: "Board-by-board pairings for posting at the venue.",
        href: if(rounds_paired > 0, do: ~p"/t/#{tournament.id}/print/pairings?round=#{latest}")
      },
      %{
        id: "print-doc-standings",
        name: "Standings",
        desc: "Current ranking with points and tiebreaks.",
        href: if(rounds_paired > 0, do: ~p"/t/#{tournament.id}/print/standings")
      },
      %{
        id: "print-doc-results",
        name: "Result cards (latest round)",
        desc: "One slip per board to record the result over the board.",
        href: if(rounds_paired > 0, do: ~p"/t/#{tournament.id}/print/results?round=#{latest}")
      },
      %{
        id: "print-doc-pairings-alpha",
        name: "Alphabetical pairing list",
        desc: "\"Where do I sit\" list, sorted by player name.",
        href:
          if(rounds_paired > 0, do: ~p"/t/#{tournament.id}/print/pairings-alpha?round=#{latest}")
      },
      %{
        id: "print-doc-scoresheets",
        name: "Score sheets",
        desc: "Pre-filled per board: names, ratings, move columns, signatures.",
        href: if(rounds_paired > 0, do: ~p"/t/#{tournament.id}/print/scoresheets?round=#{latest}")
      },
      %{
        id: "print-doc-crosstable",
        name: "Cross table",
        desc: "Full results grid of the tournament.",
        href: ~p"/t/#{tournament.id}/print/crosstable"
      },
      %{
        id: "print-doc-placecards",
        name: "Place cards",
        desc: "A folded name card per player, to stand at their seat.",
        href: ~p"/t/#{tournament.id}/print/placecards"
      },
      %{
        id: "print-doc-next-round-preview",
        name: "Next round preview",
        desc:
          "The next round's boards that are already certain. Work it out on the Pairings page first; until then there is nothing to print.",
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
            <tr :for={doc <- documents(@tournament, @postponed_open, @category)} id={doc[:id]}>
              <td><strong>{doc.name}</strong></td>

              <td class="hint">{doc.desc}</td>

              <td style="text-align: right">
                <a :if={doc.href} class="pe-btn primary" href={doc.href} target="_blank">{gettext(
                  "Print…"
                )}</a>
                <button
                  :if={!doc.href}
                  class="pe-btn"
                  disabled
                  title={gettext("Available once rounds are paired")}
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
