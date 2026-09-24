defmodule PairingsEngineWeb.BadgeGraphics do
  @moduledoc """
  The fixed artwork on an accreditation badge: the event header, the FIDE
  logo and the two watermark backgrounds. Ported from the stand-alone badge
  maker; every size is set inline in millimetres or pixels so nothing the
  surrounding page does can make a card overflow.
  """
  use Phoenix.Component

  @doc "The header: the event emblem (when set), the title, the subtitle, and city and year."
  attr :header_logo, :string, default: nil
  attr :event_title, :string, default: ""
  attr :event_subtitle, :string, default: ""
  attr :event_city, :string, default: ""
  attr :event_year, :string, default: ""
  attr :logo_height, :string, default: "46px"

  def event_header(assigns) do
    assigns =
      assign(
        assigns,
        :city_year,
        [assigns.event_city, assigns.event_year]
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.join(" • ")
      )

    ~H"""
    <div class="flex flex-col items-center justify-center text-center select-none w-full">
      <div
        class="flex items-center justify-center mb-1 shrink-0"
        style={"height: #{@logo_height}; max-height: #{@logo_height};"}
      >
        <img
          :if={@header_logo}
          src={@header_logo}
          alt=""
          style={"height: #{@logo_height}; max-height: #{@logo_height}; width: auto; max-width: 150px; object-fit: contain; display: block;"}
        />
      </div>
      <span class="text-[14px] font-black tracking-tight text-neutral-900 leading-none uppercase font-serif max-w-[95%] truncate">
        {@event_title}
      </span>
      <span
        :if={@event_subtitle not in [nil, ""]}
        class="text-[8px] font-bold tracking-wider font-serif uppercase max-w-[95%] truncate"
        style="color: #374151; margin-top: 1px;"
      >
        {@event_subtitle}
      </span>
      <span
        class="text-[9px] font-bold tracking-widest font-serif mt-0.5 uppercase"
        style={"color: #{if @city_year != "", do: "#4b5563", else: "transparent"};"}
      >
        {if @city_year != "", do: @city_year, else: Phoenix.HTML.raw("&nbsp;")}
      </span>
    </div>
    """
  end

  @doc "The FIDE logo, the default for the left footer slot."
  attr :height, :string, default: "30px"
  attr :max_width, :string, default: "70px"

  def fide_logo(assigns) do
    ~H"""
    <div class="flex items-center justify-center shrink-0" style={"height: #{@height};"}>
      <img
        src="/images/badges/fide_logo.png"
        alt="FIDE"
        style={"height: #{@height}; max-height: #{@height}; width: auto; max-width: #{@max_width}; object-fit: contain; display: block;"}
      />
    </div>
    """
  end

  @doc "A footer logo: the uploaded one when there is one, nothing otherwise."
  attr :src, :string, default: nil
  attr :height, :string, required: true
  attr :max_width, :string, required: true
  attr :fallback, :atom, default: nil, values: [nil, :fide]

  def footer_logo(assigns) do
    ~H"""
    <%= cond do %>
      <% @src -> %>
        <img
          src={@src}
          alt=""
          style={"height: #{@height}; max-height: #{@height}; width: auto; max-width: #{@max_width}; object-fit: contain; display: block;"}
        />
      <% @fallback == :fide -> %>
        <.fide_logo height={@height} max_width={@max_width} />
      <% true -> %>
        <span style={"display: block; height: #{@height};"}></span>
    <% end %>
    """
  end

  @doc "The front watermark (a transparent PNG covering the whole card)."
  def chess_watermark_front(assigns) do
    ~H"""
    <div
      class="pointer-events-none absolute inset-0 z-0 overflow-hidden select-none"
      aria-hidden="true"
      style="width: 105mm; height: 148.5mm;"
    >
      <img
        src="/images/badges/badge_bg_front.png"
        alt=""
        style="width: 100%; height: 100%; object-fit: cover; display: block;"
      />
    </div>
    """
  end

  @doc "The back watermark."
  def chess_watermark_back(assigns) do
    ~H"""
    <div
      class="pointer-events-none absolute inset-0 z-0 overflow-hidden select-none"
      aria-hidden="true"
      style="width: 105mm; height: 148.5mm;"
    >
      <img
        src="/images/badges/badge_bg_back.png"
        alt=""
        style="width: 100%; height: 100%; object-fit: cover; display: block;"
      />
    </div>
    """
  end
end
