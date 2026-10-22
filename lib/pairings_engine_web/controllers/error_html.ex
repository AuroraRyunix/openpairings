defmodule PairingsEngineWeb.ErrorHTML do
  @moduledoc """
  This module is invoked by your endpoint in case of errors on HTML requests.

  See config/config.exs. The endpoint renders these without a layout and
  often without a session, so the pages here are self-contained: no
  LiveView, no `current_scope`, nothing that may be missing when the request
  died early. What they do carry is a sentence a person can read and a way
  back to the tournaments list, which a bare "Not Found" never offered.
  """
  use PairingsEngineWeb, :html

  def render("404.html", assigns), do: not_found(assigns)
  def render("400.html", assigns), do: not_found(assigns)
  def render("500.html", assigns), do: server_error(assigns)
  def render("403.html", assigns), do: forbidden(assigns)

  # Anything else (422, ...) keeps the plain text of its status.
  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end

  @doc "The 404 page, also used by controllers that answer \"not found\" themselves."
  def not_found(_assigns) do
    assigns = %{
      title: gettext("Page not found"),
      message:
        gettext(
          "This page or tournament does not exist, was deleted, or you no longer have access."
        )
    }

    ~H"""
    <.shell title={@title} message={@message} />
    """
  end

  def forbidden(_assigns) do
    assigns = %{
      title: gettext("No access"),
      message: gettext("Only an administrator can open this page or download this file.")
    }

    ~H"""
    <.shell title={@title} message={@message} />
    """
  end

  def server_error(_assigns) do
    assigns = %{
      title: gettext("Something went wrong"),
      message:
        gettext(
          "The server hit a problem it could not handle. Go back to the tournaments list and try again in a moment."
        )
    }

    ~H"""
    <.shell title={@title} message={@message} />
    """
  end

  attr :title, :string, required: true
  attr :message, :string, required: true

  defp shell(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang={Gettext.get_locale(PairingsEngineWeb.Gettext)}>
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>{@title} · OpenPairings</title>
        <link rel="stylesheet" href={~p"/assets/css/app.css"} />
      </head>

      <body>
        <main id="error-page" class="mx-auto max-w-xl px-6 py-24 text-center">
          <h1 class="text-2xl font-semibold">{@title}</h1>

          <p class="mt-4 text-base">{@message}</p>

          <p class="mt-8">
            <a id="error-back-link" href={~p"/"} class="btn btn-primary">
              {gettext("Back to Tournaments")}
            </a>
          </p>
        </main>
      </body>
    </html>
    """
  end
end
