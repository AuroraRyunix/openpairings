defmodule PairingsEngineWeb.HelpLive do
  @moduledoc """
  The in-app user manual: `/help` (the contents) and `/help/:chapter` (one
  chapter of `PairingsEngine.Manual`, i.e. `priv/manual/*.md`).

  Routed in the `:public_pages` live_session, beside `/changelog`, for the
  same reason: the manual describes the application, not anybody's
  tournament, and there is no data behind it to protect. The top bar's Help
  link renders for signed-out visitors too (the log-in page is where an
  arbiter new to the program most needs it), and the desktop build signs its
  one owner in without a log-in screen at all - so a signed-in-only route
  would have helped nobody and bounced the people who need it most.
  `mount_current_scope` still gives a signed-in arbiter their own top bar.

  The manual text is English only (FIDE's checklist asks for an English
  manual); the page chrome around it is translated.
  """
  use PairingsEngineWeb, :live_view

  alias PairingsEngine.Manual

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, chapters: Manual.chapters(), chapter: nil, page_title: gettext("Help"))}
  end

  @impl true
  def handle_params(%{"chapter" => slug}, _uri, socket) do
    case Manual.get(slug) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("That help chapter does not exist."))
         |> push_navigate(to: ~p"/help")}

      chapter ->
        {previous, next} = Manual.neighbours(slug)

        {:noreply,
         assign(socket,
           chapter: chapter,
           previous: previous,
           next: next,
           page_title: gettext("Help") <> " - " <> chapter.title
         )}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, chapter: nil, page_title: gettext("Help"))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      publish_status={assigns[:publish_status]}
      update_notice={assigns[:update_notice]}
      flash={@flash}
      current_path={assigns[:current_path]}
      current_scope={@current_scope}
      active="help"
    >
      <div class="page-header">
        <div>
          <h1>{gettext("Help")}</h1>
          <p class="subtitle" style="margin: 0">
            {gettext("The OpenPairings user manual, for arbiters")}
          </p>
        </div>
      </div>

      <div class="manual-layout">
        <nav id="manual-toc" class="card manual-toc" aria-label={gettext("Manual contents")}>
          <h2 class="manual-toc-title">{gettext("Contents")}</h2>
          <ol class="manual-toc-list">
            <li :for={c <- @chapters}>
              <.link
                id={"manual-toc-#{c.slug}"}
                navigate={~p"/help/#{c.slug}"}
                aria-current={@chapter && @chapter.slug == c.slug && "page"}
                class={[@chapter && @chapter.slug == c.slug && "current"]}
              >
                {c.title}
              </.link>
            </li>
          </ol>
        </nav>

        <%= if @chapter do %>
          <article id="manual-chapter" class="card manual-body" lang="en">
            <h2 class="manual-chapter-title">{@chapter.title}</h2>

            <nav
              :if={@chapter.toc != []}
              id="manual-chapter-toc"
              class="manual-chapter-toc"
              aria-label={gettext("On this page")}
            >
              <strong>{gettext("On this page")}</strong>
              <ul>
                <li :for={h <- @chapter.toc}>
                  <a href={"##{h.id}"}>{h.text}</a>
                </li>
              </ul>
            </nav>

            {raw(@chapter.html)}

            <div class="manual-pager">
              <.link :if={@previous} id="manual-previous" navigate={~p"/help/#{@previous.slug}"}>
                &larr; {@previous.title}
              </.link>
              <.link :if={@next} id="manual-next" navigate={~p"/help/#{@next.slug}"}>
                {@next.title} &rarr;
              </.link>
            </div>
          </article>
        <% else %>
          <section id="manual-index" class="card manual-body" lang="en">
            <h2 class="manual-chapter-title">OpenPairings user manual</h2>
            <p>
              This manual describes what the program does today, chapter by chapter. Start with
              <.link navigate={~p"/help/getting-started"}>Getting started</.link>
              if you have not used it before.
            </p>
            <ol class="manual-index-list">
              <li :for={c <- @chapters}>
                <.link id={"manual-index-#{c.slug}"} navigate={~p"/help/#{c.slug}"}>
                  {c.title}
                </.link>
              </li>
            </ol>
          </section>
        <% end %>
      </div>
    </Layouts.app>
    """
  end
end
