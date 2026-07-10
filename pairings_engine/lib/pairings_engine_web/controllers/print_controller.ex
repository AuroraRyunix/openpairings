defmodule PairingsEngineWeb.PrintController do
  use PairingsEngineWeb, :controller

  alias PairingsEngine.Tournaments

  import Phoenix.HTML, only: [html_escape: 1, safe_to_string: 1]

  @print_css """
  * { box-sizing: border-box; }
  body { font-family: 'Segoe UI', system-ui, sans-serif; color: #111; margin: 24px; }
  h1 { font-size: 20px; margin: 0 0 2px; }
  .sub { color: #555; margin: 0 0 18px; font-size: 13px; }
  table { width: 100%; border-collapse: collapse; font-size: 13px; }
  th { text-align: left; border-bottom: 2px solid #000; padding: 5px 8px; font-size: 11px;
       text-transform: uppercase; letter-spacing: 0.04em; }
  td { padding: 5px 8px; border-bottom: 1px solid #ccc; }
  .num { text-align: right; }
  .player-card { border: 1.5px solid #000; padding: 14px 16px; margin-bottom: 16px;
                 page-break-inside: avoid; }
  .player-card h2 { font-size: 16px; margin: 0; }
  .player-card .meta { color: #444; font-size: 12.5px; margin: 2px 0 10px; }
  .player-card table td, .player-card table th { padding: 4px 8px; }
  @media print { .player-card { break-inside: avoid; } }
  """

  def player_list(conn, %{"id" => id}) do
    tournament = Tournaments.get_user_tournament!(conn.assigns.current_scope, id)
    players = Tournaments.list_players(tournament.id)

    rows =
      players
      |> Enum.with_index(1)
      |> Enum.map_join("", fn {p, i} ->
        "<tr><td class=\"num\">#{i}</td><td>#{esc(p.title)}</td><td><strong>#{esc(p.name)}</strong></td>" <>
          "<td class=\"num\">#{blank_zero(p.fide_rating)}</td><td class=\"num\">#{blank_zero(p.national_rating)}</td>" <>
          "<td>#{esc(p.federation)}</td><td>#{esc(p.club)}</td></tr>"
      end)

    body =
      "<table><thead><tr><th class=\"num\">#</th><th>Title</th><th>Name</th><th class=\"num\">FIDE</th>" <>
        "<th class=\"num\">Nat.</th><th>Fed</th><th>Club</th></tr></thead><tbody>#{rows}</tbody></table>"

    print_page(conn, tournament.name, "Registered players (#{length(players)})", body)
  end

  def player_cards(conn, %{"id" => id}) do
    tournament = Tournaments.get_user_tournament!(conn.assigns.current_scope, id)
    players = Tournaments.list_players(tournament.id)

    round_rows =
      Enum.map_join(1..tournament.rounds_count, "", fn n ->
        "<tr><td class=\"num\">#{n}</td><td></td><td></td><td></td><td></td></tr>"
      end)

    cards =
      players
      |> Enum.with_index(1)
      |> Enum.map_join("", fn {p, i} ->
        meta =
          [
            if(p.fide_rating > 0, do: "FIDE #{p.fide_rating}"),
            if(p.national_rating > 0, do: "Nat. #{p.national_rating}"),
            if(p.federation != "", do: esc(p.federation)),
            if(p.club != "", do: esc(p.club))
          ]
          |> Enum.reject(&is_nil/1)
          |> Enum.join(" · ")

        "<div class=\"player-card\"><h2>#{i}. #{esc(p.title)} #{esc(p.name)}</h2>" <>
          "<p class=\"meta\">#{meta}</p>" <>
          "<table><thead><tr><th class=\"num\">Rd</th><th>Opponent</th><th>Colour</th>" <>
          "<th>Result</th><th>Score</th></tr></thead><tbody>#{round_rows}</tbody></table></div>"
      end)

    print_page(conn, tournament.name, "Player cards", cards)
  end

  def pairing_list(conn, %{"id" => id} = params) do
    tournament = Tournaments.get_user_tournament!(conn.assigns.current_scope, id)
    number = String.to_integer(params["round"] || "1")
    round = Tournaments.get_round(tournament.id, number)

    if round == nil do
      send_resp(conn, 404, "Round #{number} has not been paired yet")
    else
      rows =
        Enum.map_join(round.pairings, "", fn p ->
          "<tr><td class=\"num\">#{p.board}</td>" <>
            "<td><strong>#{esc(p.white_player && p.white_player.name)}</strong></td>" <>
            "<td class=\"num\">#{p.white_player && blank_zero(player_rating(p.white_player))}</td>" <>
            "<td style=\"text-align:center\">#{esc(display_result(p.result))}</td>" <>
            "<td><strong>#{esc((p.black_player && p.black_player.name) || "— bye —")}</strong></td>" <>
            "<td class=\"num\">#{p.black_player && blank_zero(player_rating(p.black_player))}</td></tr>"
        end)

      body =
        "<table><thead><tr><th class=\"num\">Board</th><th>White</th><th class=\"num\">Elo</th>" <>
          "<th style=\"text-align:center\">Result</th><th>Black</th><th class=\"num\">Elo</th></tr></thead>" <>
          "<tbody>#{rows}</tbody></table>"

      print_page(conn, tournament.name, "Pairings — round #{number}", body)
    end
  end

  def standings(conn, %{"id" => id}) do
    tournament = Tournaments.get_user_tournament!(conn.assigns.current_scope, id)
    entries = PairingsEngine.Standings.standings(tournament)
    rounds = PairingsEngine.Standings.rounds_paired(tournament.id)

    tb_headers =
      Enum.map_join(tournament.tiebreaks, "", &"<th class=\"num\">#{esc(&1)}</th>")

    rows =
      Enum.map_join(entries, "", fn e ->
        tb_cells =
          Enum.map_join(tournament.tiebreaks, "", fn code ->
            "<td class=\"num\">#{Map.get(e.tiebreaks, code, 0.0)}</td>"
          end)

        "<tr><td class=\"num\">#{e.rank}</td><td><strong>#{esc(e.player.name)}</strong></td>" <>
          "<td class=\"num\">#{blank_zero(player_rating(e.player))}</td>" <>
          "<td class=\"num\"><strong>#{e.points}</strong></td>#{tb_cells}</tr>"
      end)

    body =
      "<table><thead><tr><th class=\"num\">Rank</th><th>Name</th><th class=\"num\">Elo</th>" <>
        "<th class=\"num\">Pts</th>#{tb_headers}</tr></thead><tbody>#{rows}</tbody></table>"

    print_page(conn, tournament.name, "Standings after round #{rounds}", body)
  end

  defp player_rating(player), do: PairingsEngine.Tournaments.Player.rating(player)

  defp display_result(""), do: ""
  defp display_result("1/2-1/2"), do: "½-½"
  defp display_result("bye"), do: "bye"
  defp display_result(result), do: result

  defp print_page(conn, title, subtitle, body) do
    html = """
    <!doctype html><html><head><meta charset="utf-8"><title>#{esc(title)}</title>
    <style>#{@print_css}</style></head><body>
    <h1>#{esc(title)}</h1><p class="sub">#{esc(subtitle)}</p>#{body}
    <script>window.onload = () => window.print();</script></body></html>
    """

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, html)
  end

  defp esc(nil), do: ""
  defp esc(text), do: text |> html_escape() |> safe_to_string()

  defp blank_zero(0), do: ""
  defp blank_zero(n), do: to_string(n)
end
