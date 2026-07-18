defmodule PairingsEngineWeb.PrintLive do
  use PairingsEngineWeb, :live_view

  alias PairingsEngine.Tournaments

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    tournament = Tournaments.get_authorized_tournament!(socket.assigns.current_scope, id)

    {:ok, assign(socket, tournament: tournament, page_title: "#{tournament.name} · Print")}
  end

  defp documents(tournament) do
    rounds_paired = PairingsEngine.Standings.rounds_paired(tournament.id)
    latest = max(rounds_paired, 1)

    [
      %{
        name: "Player list",
        desc: "All registered players with ratings, federation and club.",
        href: ~p"/t/#{tournament.id}/print/players"
      },
      %{
        name: "Player cards",
        desc: "One card per player with their round-by-round schedule to fill in.",
        href: ~p"/t/#{tournament.id}/print/cards"
      },
      %{
        name: "Pairing list (latest round)",
        desc: "Board-by-board pairings for posting at the venue.",
        href: if(rounds_paired > 0, do: ~p"/t/#{tournament.id}/print/pairings?round=#{latest}")
      },
      %{
        name: "Standings",
        desc: "Current ranking with points and tiebreaks.",
        href: if(rounds_paired > 0, do: ~p"/t/#{tournament.id}/print/standings")
      },
      %{
        name: "Result cards (latest round)",
        desc: "One slip per board to record the result over the board.",
        href: if(rounds_paired > 0, do: ~p"/t/#{tournament.id}/print/results?round=#{latest}")
      },
      %{
        name: "Alphabetical pairing list",
        desc: "\"Where do I sit\" list, sorted by player name.",
        href: nil
      },
      %{
        name: "Score sheets",
        desc: "Pre-filled per board: names, ratings, move columns, signatures.",
        href: nil
      },
      %{
        name: "Cross table",
        desc: "Full results grid of the tournament.",
        href: ~p"/t/#{tournament.id}/print/crosstable"
      }
    ]
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} tournament={@tournament} active="print">
      <div class="page-header">
        <div>
          <h1>{@tournament.name}</h1>
          <p class="subtitle" style="margin: 0">Print documents</p>
        </div>
      </div>

      <div class="card table-card">
        <table class="pe-table">
          <thead>
            <tr>
              <th>Document</th>
              <th>Description</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={doc <- documents(@tournament)}>
              <td><strong>{doc.name}</strong></td>
              <td class="hint">{doc.desc}</td>
              <td style="text-align: right">
                <a :if={doc.href} class="pe-btn primary" href={doc.href} target="_blank">Print…</a>
                <button
                  :if={!doc.href}
                  class="pe-btn"
                  disabled
                  title="Available once rounds are paired"
                >
                  Print…
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.app>
    """
  end
end
