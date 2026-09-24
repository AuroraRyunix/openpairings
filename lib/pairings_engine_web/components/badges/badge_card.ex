defmodule PairingsEngineWeb.BadgeCard do
  @moduledoc """
  The front and back of an accreditation badge, each exactly A6
  (105 x 148.5 mm), with the photo box at 39 x 49 mm. Ported from the
  stand-alone badge maker with its sizes unchanged.

  Takes the flat map `PairingsEngine.Badges.card/3` builds. Colours are set
  inline with `!important` because the card is always printed black on
  white, whatever theme the page around it is in.
  """
  use Phoenix.Component
  import PairingsEngineWeb.BadgeGraphics

  @card_style "width: 105mm; height: 148.5mm; min-width: 105mm; min-height: 148.5mm; max-width: 105mm; max-height: 148.5mm; box-sizing: border-box; background-color: #ffffff !important; color: #111827 !important; border: 1px solid #d1d5db; page-break-inside: avoid; -webkit-print-color-adjust: exact; print-color-adjust: exact;"

  @doc "The front: header, photo, name, role banner, room numbers, logos and QR code."
  attr :badge, :map, required: true
  attr :qr_svg, :string, default: ""
  attr :id, :string, default: nil

  def badge_front(assigns) do
    assigns =
      assigns
      |> assign(:card_style, @card_style)
      |> assign(:details, details_line(assigns.badge))

    ~H"""
    <div
      id={@id}
      data-badge-card="front"
      class="badge-card relative flex flex-col justify-between overflow-hidden font-sans select-none"
      style={@card_style}
    >
      <.chess_watermark_front />

      <div class="relative z-10 flex flex-col items-center pt-2 px-3 shrink-0">
        <.event_header
          header_logo={@badge.header_logo}
          event_title={@badge.event_title}
          event_subtitle={@badge.event_subtitle}
          event_city={@badge.event_city}
          event_year={@badge.event_year}
        />

        <div
          class="mt-1 relative bg-neutral-100 overflow-hidden flex items-center justify-center shrink-0"
          style="width: 39mm; height: 49mm; min-width: 39mm; min-height: 49mm; max-width: 39mm; max-height: 49mm; border: 2.5px solid #000000 !important; box-sizing: border-box;"
        >
          <%= if @badge.photo_url do %>
            <img
              src={@badge.photo_url}
              alt=""
              class="w-full h-full block"
              style="width: 100%; height: 100%; object-fit: cover; object-position: center;"
            />
          <% else %>
            <div class="flex items-center justify-center w-full h-full bg-neutral-100">
              <svg
                class="w-10 h-10 text-neutral-300"
                fill="currentColor"
                viewBox="0 0 24 24"
                aria-hidden="true"
              >
                <path d="M12 12c2.21 0 4-1.79 4-4s-1.79-4-4-4-4 1.79-4 4 1.79 4 4 4zm0 2c-2.67 0-8 1.34-8 4v2h16v-2c0-2.66-5.33-4-8-4z" />
              </svg>
            </div>
          <% end %>
        </div>

        <div
          class="mt-1 text-center w-full px-2 shrink-0 overflow-hidden flex flex-col justify-center"
          style="min-height: 16mm;"
        >
          <div
            class="font-black uppercase tracking-tight font-sans"
            style="color: #000000 !important; font-size: 30px !important; line-height: 0.95 !important;"
          >
            <div :if={@badge.first_name not in [nil, ""]}>{@badge.first_name}</div>
            <div :if={@badge.last_name not in [nil, ""]}>{@badge.last_name}</div>
          </div>
          <div
            :if={@details != ""}
            class="font-bold uppercase tracking-wider"
            style="color: #374151 !important; font-size: 10px; line-height: 1.2; margin-top: 3px;"
          >
            {@details}
          </div>
        </div>
      </div>

      <div class="relative z-10 w-full shrink-0 my-0.5">
        <div
          class="w-full py-2.5 px-3 text-center"
          style={"background-color: #{@badge.role_color}; color: #ffffff !important;"}
        >
          <span
            class="text-[20px] font-extrabold uppercase tracking-widest leading-none"
            style="color: #ffffff !important;"
          >
            {@badge.role}
          </span>
        </div>
      </div>

      <div class="relative z-10 px-3 w-full shrink-0 mb-[13px] flex items-center justify-center">
        <div
          class="py-1 px-2.5 rounded-full inline-flex items-center justify-center gap-1.5 w-auto max-w-[96%]"
          style="background-color: #f3f4f6 !important; border: 1px solid #d1d5db;"
        >
          <div
            :for={num <- 1..@badge.room_count//1}
            class="rounded-full flex items-center justify-center font-bold text-[12px] shrink-0"
            style={room_dot_style(num in @badge.room_access)}
          >
            {num}
          </div>
        </div>
      </div>

      <div class="relative z-10 pb-3 px-3 shrink-0 mb-2">
        <div
          class="flex items-center justify-between px-1 w-full"
          style="height: 64px; max-height: 64px;"
        >
          <div class="flex items-center justify-start flex-1" style="height: 64px; max-height: 64px;">
            <.footer_logo
              src={@badge.custom_logo_left}
              height="38px"
              max_width="90px"
              fallback={:fide}
            />
          </div>

          <div class="flex items-center justify-center shrink-0 px-1" style="height: 64px;">
            <div
              class="p-1 bg-white border border-neutral-300 rounded"
              style="width: 72px; height: 72px; min-width: 72px; min-height: 72px; max-width: 72px; max-height: 72px; box-sizing: border-box; overflow: hidden; display: flex; align-items: center; justify-content: center;"
            >
              <div
                :if={@qr_svg != ""}
                class="badge-qr"
                style="width: 63px; height: 63px; max-width: 63px; max-height: 63px; overflow: hidden;"
              >
                {Phoenix.HTML.raw(@qr_svg)}
              </div>
            </div>
          </div>

          <div class="flex items-center justify-end flex-1" style="height: 64px; max-height: 64px;">
            <.footer_logo
              src={@badge.custom_logo_right}
              height="62px"
              max_width="136px"
              fallback={:kbsb}
            />
          </div>
        </div>
      </div>
    </div>
    """
  end

  @doc "The back: header, usage conditions, QR code with the room list, and logos."
  attr :badge, :map, required: true
  attr :qr_svg, :string, default: ""
  attr :id, :string, default: nil

  def badge_back(assigns) do
    room_count = assigns.badge.room_count
    half = ceil(room_count / 2)

    assigns =
      assigns
      |> assign(:card_style, @card_style)
      |> assign(:columns, [Enum.to_list(1..half//1), Enum.to_list((half + 1)..room_count//1)])
      |> assign(:condition_lines, condition_lines(assigns.badge.usage_conditions))

    ~H"""
    <div
      id={@id}
      data-badge-card="back"
      class="badge-card relative flex flex-col justify-between overflow-hidden font-sans select-none"
      style={@card_style}
    >
      <.chess_watermark_back />

      <div
        class="relative z-10 pt-3 px-3 flex flex-col items-center shrink-0"
        style="min-height: 28mm;"
      >
        <.event_header
          header_logo={@badge.header_logo}
          event_title={@badge.event_title}
          event_subtitle={@badge.event_subtitle}
          event_city={@badge.event_city}
          event_year={@badge.event_year}
          logo_height="58px"
        />
      </div>

      <div
        class="relative z-10 px-4 pt-1 pb-1 text-left flex flex-col justify-start overflow-hidden shrink-0"
        style="margin-top: 7.5mm;"
      >
        <h3
          class="font-black uppercase tracking-wider font-sans"
          style="color: #1e3a8a !important; font-size: 11.5px; line-height: 1.1; margin-bottom: 4px;"
        >
          {@badge.conditions_title}
        </h3>
        <div
          class="font-semibold text-left"
          style="color: #1e3a8a !important; font-size: 8.2px; line-height: 1.3;"
        >
          <p
            :for={{line, indent?} <- @condition_lines}
            style={"color: #1e3a8a !important; margin: 0; padding: 0;" <> if(indent?, do: " padding-left: 10px;", else: " margin-top: 3px;")}
          >
            {line}
          </p>
        </div>
      </div>

      <div
        class="relative z-10 mx-2 mt-auto p-2.5 rounded-sm shrink-0"
        style="background-color: #f1f5f9 !important; border: 1.5px solid #cbd5e1; color: #111827 !important;"
      >
        <div class="flex items-center gap-3">
          <div
            class="p-1 bg-white rounded-xs shrink-0 border border-neutral-300 flex items-center justify-center overflow-hidden"
            style="width: 50px; height: 50px; min-width: 50px; min-height: 50px; max-width: 50px; max-height: 50px; box-sizing: border-box;"
          >
            <div :if={@qr_svg != ""} class="badge-qr w-full h-full overflow-hidden">
              {Phoenix.HTML.raw(@qr_svg)}
            </div>
          </div>

          <div class="grid grid-cols-2 gap-x-3 gap-y-1 text-[7.5px] leading-tight flex-1">
            <div :for={column <- @columns} class="flex flex-col gap-1">
              <div :for={num <- column} class="flex items-center gap-1.5">
                <span
                  class="shrink-0 flex items-center justify-center font-bold"
                  style={room_chip_style(num in @badge.room_access)}
                >
                  {num}
                </span>
                <span
                  class="truncate uppercase tracking-tight flex-1"
                  style={room_label_style(num in @badge.room_access)}
                >
                  {Map.get(@badge.room_names, num, "ROOM #{num}")}
                </span>
              </div>
            </div>
          </div>
        </div>
      </div>

      <div
        class="relative z-10 px-4 flex items-center justify-between shrink-0"
        style="height: 60px; max-height: 60px;"
      >
        <.footer_logo src={@badge.custom_logo_left} height="31px" max_width="72px" fallback={:fide} />
        <.footer_logo src={@badge.custom_logo_right} height="36px" max_width="85px" fallback={:kbsb} />
      </div>
    </div>
    """
  end

  # Title, federation and FIDE ID under the name, e.g. "GM · BEL · FIDE 255424".
  defp details_line(badge) do
    fide = if badge.fide_id not in [nil, ""], do: "FIDE #{badge.fide_id}"

    [badge.title, badge.federation, fide]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  # A line starting with "if " continues the numbered point above it, so it is
  # indented instead of spaced - the layout of the default conditions.
  defp condition_lines(text) do
    for line <- String.split(text || "", "\n"),
        trimmed = String.trim(line),
        trimmed != "",
        do: {trimmed, String.starts_with?(trimmed, "if ")}
  end

  defp room_dot_style(true),
    do:
      "width: 26px; height: 26px; background-color: #000000 !important; color: #ffffff !important; border: 1.5px solid #000000; box-shadow: 0 1px 2px rgba(0,0,0,0.2);"

  defp room_dot_style(false),
    do:
      "width: 26px; height: 26px; background-color: #ffffff !important; color: #6b7280 !important; border: 1.5px solid #9ca3af;"

  defp room_chip_style(true),
    do:
      "width: 15px; height: 15px; border-radius: 9999px; background-color: #000000 !important; color: #ffffff !important; font-size: 7.5px;"

  defp room_chip_style(false),
    do:
      "width: 15px; height: 15px; border-radius: 9999px; background-color: #ffffff !important; color: #9ca3af !important; border: 1.2px solid #cbd5e1; font-size: 7.5px;"

  defp room_label_style(true),
    do: "color: #000000 !important; font-weight: 800; font-size: 7.8px;"

  defp room_label_style(false),
    do: "color: #9ca3af !important; font-weight: 500; font-size: 7.5px;"
end
