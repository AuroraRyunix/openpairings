defmodule PairingsEngineWeb.BadgeController do
  @moduledoc """
  The plain-HTTP half of the badge maker (see docs/badges.md). All of it sits
  behind `:require_authenticated_user` and looks everything up through
  `PairingsEngine.Badges` with the signed-in user's scope, so another user's
  event, badge or image is a 404.

    * `GET /badges/:id/print` - the A4 print sheets for the whole event, or
      for one badge with `?badge=ID`. A standalone page that opens the
      browser's print dialog on load, like every document behind
      `PairingsEngineWeb.PrintController`.
    * `GET /badges/:id/photo/:badge_id` and `GET /badges/:id/logo/:slot` -
      the stored images. Served as files rather than inlined as `data:` URIs
      so a 400-badge list or print run does not push every photo through the
      LiveView socket, and so the browser can cache them. The `?v=` the
      pages add changes whenever the image does.
    * `GET /t/:id/badges` - the tournament menu's "Badges" entry: the user's
      badge event for that tournament, or a new one linked to it.
  """
  use PairingsEngineWeb, :controller

  alias PairingsEngine.Badges
  alias PairingsEngine.Badges.Event
  alias PairingsEngine.Tournaments

  def print(conn, %{"id" => id} = params) do
    scope = conn.assigns.current_scope
    event = Badges.get_event!(scope, id)
    badges = Badges.list_badges(scope, event)

    badges =
      case params["badge"] do
        nil -> badges
        badge_id -> Enum.filter(badges, &(to_string(&1.id) == badge_id))
      end

    if badges == [] and params["badge"] do
      conn |> put_status(:not_found) |> text(gettext("No such badge."))
    else
      cards = Enum.map(badges, &Badges.card(event, &1, image_urls(event)))

      conn
      |> put_root_layout(false)
      |> put_layout(false)
      |> put_view(html: PairingsEngineWeb.BadgePrintHTML)
      |> render(:document,
        event: event,
        pages: Enum.chunk_every(cards, 2),
        count: length(cards),
        qr_svg: Badges.qr_svg(event),
        show_guides: params["guides"] != "0",
        nonce: conn.assigns[:csp_nonce]
      )
    end
  end

  def photo(conn, %{"id" => id, "badge_id" => badge_id}) do
    scope = conn.assigns.current_scope
    event = Badges.get_event!(scope, id)
    badge = Badges.get_badge!(scope, event, badge_id)

    case Badges.photo(badge) do
      {data, type} -> send_image(conn, data, type)
      nil -> send_image(conn, nil, nil)
    end
  end

  def logo(conn, %{"id" => id, "slot" => slot})
      when slot in ["emblem", "logo_left", "logo_right"] do
    event = Badges.get_event!(conn.assigns.current_scope, id)

    case Badges.logo(event, String.to_existing_atom(slot)) do
      {data, type} -> send_image(conn, data, type)
      nil -> send_image(conn, nil, nil)
    end
  end

  def logo(conn, _params), do: send_image(conn, nil, nil)

  def for_tournament(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope
    tournament = Tournaments.get_authorized_tournament!(scope, id)

    case Badges.event_for_tournament(scope, tournament.id) do
      %Event{id: event_id} -> redirect(conn, to: ~p"/badges/#{event_id}")
      nil -> redirect(conn, to: ~p"/badges?new=1&tournament_id=#{tournament.id}")
    end
  end

  @doc """
  The image URLs a card uses, for `PairingsEngine.Badges.card/3`. Versioned
  by `updated_at`, so a changed photo is fetched again and an unchanged one
  comes from the browser's cache.
  """
  def image_urls(%Event{} = event) do
    fn
      :photo, badge -> ~p"/badges/#{event.id}/photo/#{badge.id}?v=#{version(badge.updated_at)}"
      :logo, slot -> ~p"/badges/#{event.id}/logo/#{slot}?v=#{version(event.updated_at)}"
    end
  end

  defp version(nil), do: "0"
  defp version(%DateTime{} = at), do: Integer.to_string(DateTime.to_unix(at))

  defp send_image(conn, data, type) when is_binary(data) and is_binary(type) do
    conn
    |> put_resp_content_type(type, nil)
    |> put_resp_header("cache-control", "private, max-age=86400")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> send_resp(200, data)
  end

  defp send_image(conn, _data, _type) do
    conn |> put_status(:not_found) |> text("")
  end
end
