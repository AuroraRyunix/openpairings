defmodule PairingsEngineWeb.HelpLive do
  @moduledoc """
  The in-app user manual: `/help` (the contents), `/help/:chapter` (one
  chapter of `PairingsEngine.Manual`, i.e. `priv/manual/*.md`) and
  `/help?q=...` (a search across every chapter).

  Routed in the `:public_pages` live_session, beside `/changelog`, for the
  same reason: the manual describes the application, not anybody's
  tournament, and there is no data behind it to protect. The top bar's Help
  link renders for signed-out visitors too (the log-in page is where an
  arbiter new to the program most needs it), and the desktop build signs its
  one owner in without a log-in screen at all - so a signed-in-only route
  would have helped nobody and bounced the people who need it most.
  `mount_current_scope` still gives a signed-in arbiter their own top bar.

  The manual exists in English and Dutch (`PairingsEngine.Manual`, one
  chapter file per language; a chapter not translated yet shows in English),
  and the page chrome around it is translated too.

  ## The page

  Three columns on a wide screen: the chapters (grouped in parts, `@parts`), the
  chapter in a reading column, and its outline. The outline folds above the
  chapter on a narrower screen, and the chapter list folds behind a button on
  a phone. The colocated `.Manual` hook does what the server cannot: the
  outline's scroll-spy, the `/` and Ctrl+K search shortcut, copying a
  heading's link, and the enlarged view of a screenshot. All of it is
  progressive: without JavaScript every link, the search (a GET form) and
  every heading still work.

  The callout icons are classes in the compiled chapter HTML
  (`PairingsEngine.Manual.Markup`), which Tailwind finds through the
  `@source` on `lib/pairings_engine/manual` in app.css.
  """
  use PairingsEngineWeb, :live_view

  alias PairingsEngine.Manual
  alias PairingsEngine.Manual.Family

  @impl true
  def mount(_params, _session, socket) do
    # The manual in the reader's language where it has been translated
    # (`PairingsEngine.Manual`), English for the rest.
    locale = Gettext.get_locale(PairingsEngineWeb.Gettext)

    {:ok,
     assign(socket,
       manual_locale: locale,
       chapters: Manual.chapters(locale),
       family: Family.programs(locale),
       program: nil,
       chapter: nil,
       previous: nil,
       next: nil,
       query: "",
       results: [],
       search_form: to_form(%{"q" => ""}, as: :search),
       page_title: gettext("Help")
     )}
  end

  @impl true
  def handle_params(%{"program" => program} = params, _uri, socket) do
    locale = socket.assigns.manual_locale

    case Family.get(program, params["page"], locale) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("That help chapter does not exist."))
         |> push_navigate(to: ~p"/help")}

      {program, page} ->
        {previous, next} = Family.neighbours(page, locale)

        {:noreply,
         socket
         |> assign(
           program: program,
           chapter: page,
           previous: previous,
           next: next,
           page_title: gettext("Help") <> " - " <> program.name <> ": " <> page.title
         )
         |> assign_search("")}
    end
  end

  def handle_params(%{"chapter" => slug}, _uri, socket) do
    case Manual.get(slug, socket.assigns.manual_locale) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("That help chapter does not exist."))
         |> push_navigate(to: ~p"/help")}

      chapter ->
        {previous, next} = Manual.neighbours(slug, socket.assigns.manual_locale)

        {:noreply,
         socket
         |> assign(
           program: nil,
           chapter: chapter,
           previous: previous,
           next: next,
           page_title: gettext("Help") <> " - " <> chapter.title
         )
         |> assign_search("")}
    end
  end

  def handle_params(params, _uri, socket) do
    query = params |> Map.get("q", "") |> to_string() |> String.slice(0, 100)

    {:noreply,
     socket
     |> assign(program: nil, chapter: nil, previous: nil, next: nil, page_title: gettext("Help"))
     |> assign_search(query)}
  end

  @impl true
  def handle_event("search", %{"search" => %{"q" => q}}, socket) do
    q = q |> to_string() |> String.slice(0, 100)

    cond do
      String.trim(q) == "" and socket.assigns.chapter != nil ->
        {:noreply, assign_search(socket, q)}

      String.trim(q) == "" ->
        {:noreply, push_patch(socket, to: ~p"/help", replace: true)}

      true ->
        {:noreply, push_patch(socket, to: ~p"/help?#{[q: q]}", replace: true)}
    end
  end

  defp assign_search(socket, query) do
    assign(socket,
      query: query,
      results: Manual.search(query, 30, socket.assigns.manual_locale),
      search_form: to_form(%{"q" => query}, as: :search)
    )
  end

  # The parts of the manual: what an arbiter goes looking for, by chapter
  # slug, so a renumbered file stays where it belongs. The files are
  # numbered so that each part reads in order, but the number decides
  # nothing here. A chapter nobody filed lands in the last part rather
  # than vanishing from the contents (the HelpLive test complains first).
  @parts [
    {"part-preparing",
     ~w(getting-started fide-mode tournament-setup players-and-ratings byes-and-absences)},
    {"part-rounds", ~w(pairing results standings-and-tiebreaks)},
    {"part-reports", ~w(printing fide-report categories-and-norms import-export)},
    {"part-teams", ~w(teams)},
    {"part-publishing", ~w(publishing openresults accounts-and-handoff)},
    {"part-live-boards", ~w(live-boards setting-up-boards)},
    {"part-manubrium", ~w(manubrium-app manubrium-privacy)}
  ]

  defp part_title("part-preparing"), do: gettext("Preparing the tournament")
  defp part_title("part-rounds"), do: gettext("Round by round")
  defp part_title("part-reports"), do: gettext("Reports and exports")
  defp part_title("part-teams"), do: gettext("Team tournaments")
  defp part_title("part-publishing"), do: gettext("Publishing and sharing")
  defp part_title("part-live-boards"), do: gettext("Live boards")
  defp part_title("part-manubrium"), do: gettext("Manubrium, the phone app")

  defp parts(chapters) do
    filed = @parts |> Enum.flat_map(&elem(&1, 1)) |> MapSet.new()
    stray = Enum.reject(chapters, &MapSet.member?(filed, &1.slug))
    last = @parts |> List.last() |> elem(0)

    @parts
    |> Enum.map(fn {id, slugs} ->
      list = Enum.filter(chapters, &(&1.slug in slugs))
      {id, part_title(id), if(id == last, do: list ++ stray, else: list)}
    end)
    |> Enum.reject(fn {_, _, list} -> list == [] end)
  end

  defp part_name(chapters, chapter) do
    Enum.find_value(parts(chapters), fn {_, name, list} ->
      if Enum.any?(list, &(&1.slug == chapter.slug)), do: name
    end)
  end

  defp reading_minutes(chapter) do
    words =
      chapter.sections
      |> Enum.map(&(&1.text |> String.split() |> length()))
      |> Enum.sum()

    max(1, round(words / 200))
  end

  defp result_path(%{chapter: chapter, section_id: nil}), do: page_path(chapter)
  defp result_path(%{chapter: chapter, section_id: id}), do: page_path(chapter) <> "#" <> id

  # A chapter of this manual, or a page of another program's.
  defp page_path(%{family?: true} = page), do: Family.path(page)
  defp page_path(chapter), do: ~p"/help/#{chapter.slug}"

  defp family?(%{family?: true}), do: true
  defp family?(_), do: false

  # "6. Pairing" or "Nunki: Overview".
  defp where_label(%{family?: true} = page),
    do: page.program_name <> ": " <> page_label(page)

  defp where_label(chapter), do: "#{chapter.number}. #{chapter.title}"

  # The README of a program is its overview; the page title there is just
  # the program's name.
  defp page_label(%{family?: true, program_name: name, title: name}), do: gettext("Overview")
  defp page_label(%{title: title}), do: title

  defp pager_label(%{family?: true} = page), do: page_label(page)
  defp pager_label(chapter), do: "#{chapter.number}. #{chapter.title}"

  defp not_translated?(socket_locale, chapter),
    do: socket_locale != "en" and family?(chapter) and not chapter.translated?

  attr :program, :map, required: true
  attr :class, :string, default: nil

  # A program's nine-squares mark, drawn from its rectangles in the theme's
  # ink and accent (`PairingsEngine.Manual.Family`); OpenResults has no mark
  # and gets a globe, which is roughly where its readers are.
  defp program_mark(assigns) do
    ~H"""
    <span class={["manual-mark", @class]} aria-hidden="true">
      <svg
        :if={@program.mark}
        viewBox="0 0 24 24"
        class="manual-mark-svg"
        aria-hidden="true"
        focusable="false"
      >
        <rect
          :for={r <- @program.mark}
          x={r.x}
          y={r.y}
          width={r.width}
          height={r.height}
          class={"manual-mark-#{r.kind}"}
        />
      </svg>
      <.icon :if={!@program.mark} name="hero-globe-alt" class="manual-mark-icon" />
    </span>
    """
  end

  attr :parts, :list, required: true

  defp marked(assigns) do
    ~H"""
    <%= for {text, matched?} <- @parts do %>
      <mark :if={matched?}>{text}</mark><span :if={!matched?}>{text}</span>
    <% end %>
    """
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
      active="help"
    >
      <div
        id="manual"
        class={["manual-shell", @chapter && "has-outline"]}
        phx-hook=".Manual"
        data-copied={gettext("Link copied")}
      >
        <aside id="manual-sidebar" class="manual-sidebar" aria-label={gettext("User manual")}>
          <div class="manual-sidebar-inner">
            <.link navigate={~p"/help"} class="manual-brand" id="manual-home">
              <span class="manual-brand-mark" aria-hidden="true">
                <.icon name="hero-book-open" class="size-5" />
              </span>

              <span>
                <span class="manual-brand-title">{gettext("User manual")}</span>
                <span class="manual-brand-sub">OpenPairings</span>
              </span>
            </.link>

            <.form
              for={@search_form}
              id="manual-search"
              class="manual-search"
              role="search"
              action={~p"/help"}
              method="get"
              phx-change="search"
              phx-submit="search"
            >
              <.icon name="hero-magnifying-glass" class="manual-search-icon size-4" />
              <.input
                field={@search_form[:q]}
                type="search"
                id="manual-search-input"
                class="manual-search-input"
                placeholder={gettext("Search the manual")}
                aria-label={gettext("Search the manual")}
                autocomplete="off"
                phx-debounce="200"
              /> <span class="manual-search-key" aria-hidden="true"><kbd>/</kbd></span>
            </.form>

            <button
              type="button"
              id="manual-nav-toggle"
              class="manual-nav-toggle"
              aria-controls="manual-toc"
              aria-expanded="false"
              phx-click={
                JS.toggle_class("is-open", to: "#manual-sidebar")
                |> JS.toggle_attribute({"aria-expanded", "true", "false"})
              }
            >
              <.icon name="hero-bars-3" class="size-5" />
              <span class="manual-nav-toggle-label">
                {cond do
                  @program ->
                    @program.name <> ": " <> page_label(@chapter)

                  @chapter ->
                    gettext("Chapter %{n}: %{title}", n: @chapter.number, title: @chapter.title)

                  true ->
                    gettext("Chapters")
                end}
              </span>
              <.icon name="hero-chevron-down" class="manual-nav-toggle-chevron size-4" />
            </button>

            <nav id="manual-toc" class="manual-toc" aria-label={gettext("Manual contents")}>
              <div :for={{id, name, list} <- parts(@chapters)} class="manual-part" id={id}>
                <h2 class="manual-part-title">{name}</h2>

                <ol class="manual-toc-list">
                  <li :for={c <- list}>
                    <.link
                      id={"manual-toc-#{c.slug}"}
                      navigate={~p"/help/#{c.slug}"}
                      aria-current={@chapter && @chapter.slug == c.slug && "page"}
                      class={["manual-toc-link", @chapter && @chapter.slug == c.slug && "current"]}
                    >
                      <span class="manual-toc-number" aria-hidden="true">{c.number}</span>
                      <span class="manual-toc-text">{c.title}</span>
                    </.link>
                  </li>
                </ol>
              </div>

              <div :if={@family != []} class="manual-part" id="part-other">
                <h2 class="manual-part-title">{gettext("Other programs")}</h2>

                <ul class="manual-toc-list">
                  <li :for={p <- @family}>
                    <.link
                      id={"manual-toc-other-#{p.slug}"}
                      navigate={~p"/help/other/#{p.slug}"}
                      aria-current={
                        @program && @program.slug == p.slug && @chapter.slug == nil && "page"
                      }
                      class={[
                        "manual-toc-link",
                        @program && @program.slug == p.slug && @chapter.slug == nil && "current"
                      ]}
                    >
                      <.program_mark program={p} class="manual-toc-number" />
                      <span class="manual-toc-text">{p.name}</span>
                    </.link>

                    <ul
                      :if={@program && @program.slug == p.slug && length(p.pages) > 1}
                      id={"manual-toc-other-#{p.slug}-pages"}
                      class="manual-toc-list manual-toc-sub"
                    >
                      <li :for={page <- p.pages}>
                        <.link
                          id={"manual-toc-other-#{p.slug}-#{page.slug || "overview"}"}
                          navigate={Family.path(page)}
                          aria-current={@chapter.slug == page.slug && "page"}
                          class={["manual-toc-link", @chapter.slug == page.slug && "current"]}
                        >
                          <span class="manual-toc-text">{page_label(page)}</span>
                        </.link>
                      </li>
                    </ul>
                  </li>
                </ul>
              </div>
            </nav>
          </div>
        </aside>

        <%= cond do %>
          <% String.trim(@query) != "" -> %>
            <section
              id="manual-results"
              class="manual-main manual-results"
              aria-labelledby="manual-results-title"
            >
              <nav class="manual-breadcrumb" aria-label={gettext("Breadcrumb")}>
                <ol>
                  <li><.link navigate={~p"/help"}>{gettext("Help")}</.link></li>

                  <li aria-current="page">{gettext("Search")}</li>
                </ol>
              </nav>

              <h1 id="manual-results-title" class="manual-title">
                {gettext("Search results")}
              </h1>

              <p class="manual-results-count" role="status" aria-live="polite">
                {ngettext(
                  "One section matches \"%{query}\".",
                  "%{count} sections match \"%{query}\".",
                  length(@results),
                  query: @query
                )}
              </p>

              <ol :if={@results != []} class="manual-results-list" lang="en">
                <li :for={{r, i} <- Enum.with_index(@results)}>
                  <.link
                    navigate={result_path(r)}
                    id={"manual-result-#{i}"}
                    class="manual-result"
                  >
                    <span class="manual-result-where">
                      <span class="manual-result-chapter">
                        {where_label(r.chapter)}
                      </span>
                    </span>
                    <span class="manual-result-heading"><.marked parts={r.heading_parts} /></span>
                    <span class="manual-result-snippet"><.marked parts={r.snippet_parts} /></span>
                  </.link>
                </li>
              </ol>

              <div :if={@results == []} id="manual-no-results" class="manual-empty">
                <.icon name="hero-magnifying-glass" class="size-6" />
                <p>
                  {gettext(
                    "Nothing in the manual matches every word. Try fewer or shorter words, or browse the chapters."
                  )}
                </p>
              </div>
            </section>
          <% @chapter -> %>
            <article
              id="manual-chapter"
              class="manual-main manual-chapter"
              aria-labelledby="manual-chapter-title"
            >
              <nav class="manual-breadcrumb" aria-label={gettext("Breadcrumb")}>
                <ol>
                  <li><.link navigate={~p"/help"}>{gettext("Help")}</.link></li>

                  <%= if @program do %>
                    <li>
                      <.link href={~p"/help" <> "#manual-index-other"}>
                        {gettext("Other programs")}
                      </.link>
                    </li>

                    <li :if={@chapter.slug == nil} aria-current="page">{@program.name}</li>
                    <li :if={@chapter.slug != nil}>
                      <.link navigate={~p"/help/other/#{@program.slug}"}>{@program.name}</.link>
                    </li>

                    <li :if={@chapter.slug != nil} aria-current="page">{@chapter.title}</li>
                  <% else %>
                    <li>{part_name(@chapters, @chapter)}</li>

                    <li aria-current="page">{@chapter.title}</li>
                  <% end %>
                </ol>
              </nav>

              <header :if={!@program} class="manual-chapter-head">
                <p class="manual-eyebrow">
                  <span class="manual-chapter-number">
                    {gettext("Chapter %{n}", n: @chapter.number)}
                  </span>

                  <span class="manual-reading-time">
                    {ngettext("1 minute read", "%{count} minutes read", reading_minutes(@chapter))}
                  </span>
                </p>

                <h1 id="manual-chapter-title" class="manual-title manual-chapter-title" lang="en">
                  {@chapter.title}
                </h1>
              </header>

              <header
                :if={@program}
                id="manual-program-head"
                class="manual-chapter-head manual-program-head"
              >
                <div class="manual-program-id">
                  <.program_mark program={@program} class="manual-program-mark" />

                  <div class="manual-program-heading">
                    <p class="manual-eyebrow">
                      <span class="manual-chapter-number">
                        {if @chapter.slug == nil, do: gettext("Other programs"), else: @program.name}
                      </span>

                      <span class="manual-reading-time">
                        {ngettext(
                          "1 minute read",
                          "%{count} minutes read",
                          reading_minutes(@chapter)
                        )}
                      </span>
                    </p>

                    <h1 id="manual-chapter-title" class="manual-title manual-chapter-title">
                      {if @chapter.slug == nil, do: @program.name, else: @chapter.title}
                    </h1>

                    <p :if={@program.tagline != ""} class="manual-program-tagline">
                      {@program.tagline}
                    </p>
                  </div>
                </div>

                <div
                  :if={@chapter.slug == nil && @program.intro}
                  id="manual-program-intro"
                  class="manual-program-intro manual-prose"
                  lang={@manual_locale}
                >
                  {raw(@program.intro.html)}
                </div>

                <div class="manual-program-actions">
                  <a
                    :if={@program.releases_url}
                    id="manual-program-releases"
                    href={@program.releases_url}
                    class="pe-btn primary"
                    rel="noopener noreferrer"
                    target="_blank"
                  >
                    <.icon name="hero-arrow-down-tray" class="size-4" /> {gettext("Latest release")}
                  </a>
                  <a
                    id="manual-program-source"
                    href={@program.github_url}
                    class="pe-btn"
                    rel="noopener noreferrer"
                    target="_blank"
                  >
                    <.icon name="hero-code-bracket" class="size-4" /> {gettext("Source on GitHub")}
                  </a>
                </div>

                <nav
                  :if={length(@program.pages) > 1}
                  id="manual-program-pages"
                  class="manual-program-pages"
                  aria-label={gettext("Pages about %{name}", name: @program.name)}
                >
                  <.link
                    :for={{page, i} <- Enum.with_index(@program.pages, 1)}
                    id={"manual-program-page-#{page.slug || "overview"}"}
                    navigate={Family.path(page)}
                    aria-current={@chapter.slug == page.slug && "page"}
                    class={["manual-program-page", @chapter.slug == page.slug && "current"]}
                  >
                    <span class="manual-program-page-number" aria-hidden="true">{i}</span>
                    <span>{page_label(page)}</span>
                  </.link>
                </nav>

                <p
                  :if={not_translated?(@manual_locale, @chapter)}
                  id="manual-english-only"
                  class="manual-note-line"
                >
                  <.icon name="hero-language" class="size-4" />
                  {if @chapter.slug == nil && @program.intro,
                    do: gettext("The rest of this page is only available in English."),
                    else: gettext("This page is only available in English.")}
                </p>
              </header>

              <nav
                :if={@chapter.toc != []}
                id="manual-chapter-toc"
                class="manual-outline"
                aria-label={gettext("On this page")}
              >
                <button
                  type="button"
                  id="manual-outline-toggle"
                  class="manual-outline-toggle"
                  aria-expanded="false"
                  aria-controls="manual-outline-list"
                  phx-click={
                    JS.toggle_class("is-open", to: "#manual-chapter-toc")
                    |> JS.toggle_attribute({"aria-expanded", "true", "false"})
                  }
                >
                  {gettext("On this page")} <.icon name="hero-chevron-down" class="size-4" />
                </button>

                <p class="manual-outline-title" aria-hidden="true">{gettext("On this page")}</p>

                <ul id="manual-outline-list" class="manual-outline-list" lang="en">
                  <li :for={h <- @chapter.toc} class={"level-#{h.level}"}>
                    <a href={"##{h.id}"} data-outline={h.id}>{h.text}</a>
                  </li>
                </ul>

                <a href="#main-content" class="manual-outline-top">
                  <.icon name="hero-arrow-up" class="size-3.5" /> {gettext("Back to top")}
                </a>
              </nav>

              <div id="manual-chapter-body" class="manual-prose" lang="en">
                {raw(@chapter.html)}
              </div>

              <nav class="manual-pager" aria-label={gettext("Previous and next chapter")}>
                <.link
                  :if={@previous}
                  id="manual-previous"
                  navigate={page_path(@previous)}
                  class="manual-pager-link prev"
                  rel="prev"
                >
                  <span class="manual-pager-dir">
                    <.icon name="hero-arrow-left" class="size-4" /> {gettext("Previous")}
                  </span>
                  <span class="manual-pager-title">{pager_label(@previous)}</span>
                </.link>

                <.link
                  :if={@next}
                  id="manual-next"
                  navigate={page_path(@next)}
                  class="manual-pager-link next"
                  rel="next"
                >
                  <span class="manual-pager-dir">
                    {gettext("Next")} <.icon name="hero-arrow-right" class="size-4" />
                  </span>
                  <span class="manual-pager-title">{pager_label(@next)}</span>
                </.link>
              </nav>
            </article>
          <% true -> %>
            <section
              id="manual-index"
              class="manual-main manual-index"
              aria-labelledby="manual-index-title"
            >
              <header class="manual-hero">
                <p class="manual-eyebrow">{gettext("Help")}</p>

                <h1 id="manual-index-title" class="manual-title">
                  {gettext("The OpenPairings user manual")}
                </h1>

                <p class="manual-lede">
                  {gettext(
                    "Everything the program does, from the first player to the FIDE report, written for the arbiter at the board. New here? Start with Getting started."
                  )}
                </p>

                <p class="manual-hero-actions">
                  <.link navigate={~p"/help/getting-started"} class="pe-btn primary" id="manual-start">
                    {gettext("Getting started")} <.icon name="hero-arrow-right" class="size-4" />
                  </.link>

                  <span class="manual-hint">
                    {gettext("Press")} <kbd>/</kbd> {gettext("to search")}
                  </span>
                </p>
              </header>

              <section
                :for={{id, name, list} <- parts(@chapters)}
                id={"#{id}-contents"}
                class="manual-index-part"
                aria-labelledby={"#{id}-index"}
              >
                <h2 id={"#{id}-index"} class="manual-index-part-title">{name}</h2>

                <ol class="manual-index-list" lang="en">
                  <li :for={c <- list}>
                    <.link
                      id={"manual-index-#{c.slug}"}
                      navigate={~p"/help/#{c.slug}"}
                      class="manual-card"
                    >
                      <span class="manual-card-number" aria-hidden="true">{c.number}</span>
                      <span class="manual-card-body">
                        <span class="manual-card-title">{c.title}</span>
                        <span class="manual-card-summary">{c.summary}</span>
                      </span>
                    </.link>
                  </li>
                </ol>
              </section>

              <section
                :if={@family != []}
                id="manual-index-other"
                class="manual-index-part"
                aria-labelledby="part-other-index"
              >
                <h2 id="part-other-index" class="manual-index-part-title">
                  {gettext("Other programs")}
                </h2>

                <p class="manual-index-part-lede">
                  {gettext(
                    "The programs that work beside OpenPairings, from the engine inside it to the printer in the hall. Each page starts with what the program is and when you need it."
                  )}
                </p>

                <ul class="manual-index-list">
                  <li :for={p <- @family}>
                    <.link
                      id={"manual-index-other-#{p.slug}"}
                      navigate={~p"/help/other/#{p.slug}"}
                      class="manual-card manual-program-card"
                    >
                      <.program_mark program={p} class="manual-card-number" />
                      <span class="manual-card-body">
                        <span class="manual-card-title">{p.name}</span>
                        <span :if={p.tagline != ""} class="manual-card-kicker">{p.tagline}</span>
                        <span class="manual-card-summary">{p.summary}</span>
                      </span>
                    </.link>
                  </li>
                </ul>
              </section>
            </section>
        <% end %>

        <div
          id="manual-copied"
          class="manual-toast"
          role="status"
          aria-live="polite"
          phx-update="ignore"
        >
        </div>

        <dialog
          id="manual-lightbox"
          class="manual-lightbox"
          aria-label={gettext("Screenshot")}
          phx-update="ignore"
        >
          <button
            type="button"
            class="manual-lightbox-close"
            data-close
            aria-label={gettext("Close")}
          >
            <.icon name="hero-x-mark" class="size-6" />
          </button>
          <img alt="" />
          <p class="manual-lightbox-caption"></p>
        </dialog>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".Manual">
        export default {
          mounted() {
            this.reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches
            this.onKey = (e) => this.key(e)
            this.onScroll = () => {
              if (this.ticking) return
              this.ticking = true
              requestAnimationFrame(() => { this.ticking = false; this.spy() })
            }
            this.onClick = (e) => this.click(e)
            window.addEventListener("keydown", this.onKey)
            window.addEventListener("scroll", this.onScroll, {passive: true})
            this.el.addEventListener("click", this.onClick)
            this.scrollToHash()
            this.spy()
          },
          updated() { this.spy() },
          destroyed() {
            window.removeEventListener("keydown", this.onKey)
            window.removeEventListener("scroll", this.onScroll)
          },
          behavior() { return this.reduced ? "auto" : "smooth" },
          scrollToHash() {
            const id = decodeURIComponent(window.location.hash.slice(1))
            if (!id) return
            const target = document.getElementById(id)
            if (target) requestAnimationFrame(() => target.scrollIntoView({block: "start"}))
          },
          // The outline entry of the last heading above the top fifth of
          // the window is the one being read.
          spy() {
            const links = this.el.querySelectorAll("[data-outline]")
            if (!links.length) return
            const line = window.innerHeight * 0.2
            let current = null
            this.el.querySelectorAll("#manual-chapter-body h2[id], #manual-chapter-body h3[id]").forEach(h => {
              if (h.getBoundingClientRect().top <= line) current = h.id
            })
            // At the very bottom the last headings can never reach the line:
            // the last one on screen is the one being read.
            if (window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - 2) {
              this.el.querySelectorAll("#manual-chapter-body h2[id], #manual-chapter-body h3[id]").forEach(h => {
                if (h.getBoundingClientRect().top < window.innerHeight) current = h.id
              })
            }
            if (!current && links[0]) current = links[0].dataset.outline
            links.forEach(a => {
              const on = a.dataset.outline === current
              a.classList.toggle("is-active", on)
              if (on) a.setAttribute("aria-current", "location")
              else a.removeAttribute("aria-current")
            })
          },
          key(e) {
            const input = document.getElementById("manual-search-input")
            if (!input) return
            const t = e.target
            const typing = t && (t.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName))
            if ((e.key === "k" || e.key === "K") && (e.ctrlKey || e.metaKey)) {
              e.preventDefault(); input.focus(); input.select(); return
            }
            if (e.key === "/" && !typing && !e.altKey && !e.ctrlKey && !e.metaKey) {
              e.preventDefault(); input.focus(); input.select(); return
            }
            if (e.key === "Escape" && t === input) input.blur()
          },
          click(e) {
            const anchor = e.target.closest("a.manual-anchor")
            if (anchor) return this.copyLink(e, anchor)
            const frame = e.target.closest("[data-enlarge]")
            if (frame) return this.enlarge(frame)
            const box = document.getElementById("manual-lightbox")
            if (box && box.open && (e.target === box || e.target.closest("[data-close]"))) box.close()
          },
          copyLink(e, anchor) {
            e.preventDefault()
            const id = anchor.getAttribute("href").slice(1)
            const url = window.location.origin + window.location.pathname + "#" + id
            history.replaceState(history.state, "", "#" + id)
            const heading = document.getElementById(id)
            if (heading) heading.scrollIntoView({behavior: this.behavior(), block: "start"})
            const toast = document.getElementById("manual-copied")
            const done = () => {
              if (!toast) return
              toast.textContent = this.el.dataset.copied
              toast.classList.add("is-shown")
              clearTimeout(this.toastTimer)
              this.toastTimer = setTimeout(() => toast.classList.remove("is-shown"), 1800)
            }
            if (navigator.clipboard && window.isSecureContext) {
              navigator.clipboard.writeText(url).then(done, () => {})
            }
          },
          enlarge(frame) {
            const img = frame.querySelector("img")
            const box = document.getElementById("manual-lightbox")
            if (!img || !box || !box.showModal) return
            box.querySelector("img").src = img.currentSrc || img.src
            box.querySelector("img").alt = img.alt
            const caption = frame.closest("figure")?.querySelector("figcaption")
            box.querySelector(".manual-lightbox-caption").textContent = caption ? caption.textContent : ""
            box.showModal()
          }
        }
      </script>
    </Layouts.app>
    """
  end
end
