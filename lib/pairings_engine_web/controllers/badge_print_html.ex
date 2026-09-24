defmodule PairingsEngineWeb.BadgePrintHTML do
  @moduledoc """
  The standalone page `PairingsEngineWeb.BadgeController.print/2` sends: the
  app's stylesheet (the cards are drawn with its Tailwind utilities), the
  sheet layout below, and the same nonce-carrying `window.print()` trigger the
  other print documents use (see `PairingsEngineWeb.CSP`).

  The page CSS is here rather than in app.css because `@page` is global: set
  in app.css it would take the margins away from every page of the app that
  anybody prints with Ctrl+P.
  """
  use PairingsEngineWeb, :html

  import PairingsEngineWeb.BadgePrintSheet

  @sheet_css """
  @page { size: A4 portrait; margin: 0; }
  html, body { margin: 0 !important; padding: 0 !important; }
  body.badge-print-body { background: #e5e7eb !important; color: #111827 !important;
    font-family: ui-sans-serif, system-ui, sans-serif; }
  .badge-print-toolbar { display: flex; flex-wrap: wrap; align-items: center; gap: 12px;
    justify-content: space-between; max-width: 210mm; margin: 16px auto 0; padding: 12px 16px;
    background: #fff; border: 1px solid #d1d5db; border-radius: 10px; font-size: 13px; }
  .badge-print-toolbar button, .badge-print-toolbar a { font: inherit; font-weight: 600;
    padding: 6px 14px; border-radius: 8px; border: 1px solid #d1d5db; background: #fff;
    color: #111827; text-decoration: none; cursor: pointer; }
  .badge-print-toolbar button.primary { background: #111827; color: #fff; border-color: #111827; }
  .badge-print-page { position: relative; width: 210mm; height: 297mm; margin: 16px auto;
    overflow: hidden; background: #fff; box-shadow: 0 10px 30px rgba(0,0,0,0.15);
    break-after: page; page-break-after: always;
    -webkit-print-color-adjust: exact; print-color-adjust: exact; }
  .badge-print-page:last-child { break-after: auto; page-break-after: auto; }
  .badge-print-pair { position: relative; display: flex; width: 210mm; height: 148.5mm; }
  .badge-print-face { width: 105mm; height: 148.5mm; flex-shrink: 0; }
  .badge-fold-guide { position: absolute; left: 105mm; top: 0; bottom: 0; width: 0;
    border-left: 1px dashed #9ca3af; z-index: 30; display: flex; align-items: center;
    justify-content: center; pointer-events: none; }
  .badge-fold-guide span { transform: rotate(90deg); white-space: nowrap; font: 7px ui-monospace, monospace;
    letter-spacing: 0.2em; text-transform: uppercase; color: #6b7280; background: rgba(255,255,255,0.8); padding: 0 4px; }
  .badge-cut-guide { position: relative; height: 0; border-top: 1px dashed #9ca3af; z-index: 30;
    display: flex; justify-content: center; pointer-events: none; }
  .badge-cut-guide span { transform: translateY(-50%); background: #fff; padding: 0 8px;
    font: 8px ui-monospace, monospace; letter-spacing: 0.2em; text-transform: uppercase; color: #6b7280; }
  .badge-qr svg { width: 100%; height: 100%; display: block; }
  @media print {
    body.badge-print-body { background: #fff !important; }
    .badge-print-toolbar { display: none !important; }
    .badge-print-page { margin: 0; box-shadow: none; }
    * { -webkit-print-color-adjust: exact !important; print-color-adjust: exact !important; }
  }
  """

  defp sheet_css, do: @sheet_css

  def document(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang={Gettext.get_locale(PairingsEngineWeb.Gettext)} data-theme="light">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>{gettext("Badges")} · {@event.name}</title>
        <link rel="stylesheet" href={~p"/assets/css/app.css"} />
        <style>
          <%= Phoenix.HTML.raw(sheet_css()) %>
        </style>
      </head>
      <body class="badge-print-body">
        <div class="badge-print-toolbar">
          <span>
            <strong>{@event.name}</strong>
            · {ngettext("1 badge", "%{count} badges", @count)} · {ngettext(
              "1 A4 sheet",
              "%{count} A4 sheets",
              length(@pages)
            )}
          </span>
          <span>{gettext("Print at 100% (no scaling, no margins), then cut and fold.")}</span>
          <button type="button" id="badge-print-now" class="primary">{gettext("Print")}</button>
        </div>
        <p :if={@pages == []} id="badge-print-empty" class="badge-print-toolbar">
          {gettext("This event has no badges yet.")}
        </p>
        <.print_sheets pages={@pages} qr_svg={@qr_svg} show_guides={@show_guides} />
        <script nonce={@nonce}>
          document.getElementById("badge-print-now").addEventListener("click", () => window.print());
          window.addEventListener("load", () => { if (document.querySelector(".badge-print-page")) window.print(); });
        </script>
      </body>
    </html>
    """
  end
end
