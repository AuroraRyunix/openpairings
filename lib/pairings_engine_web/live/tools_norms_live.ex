defmodule PairingsEngineWeb.ToolsNormsLive do
  @moduledoc """
  The public, no-login arbiter tools page — `/tools/norms` (see
  docs/tools.md). Lets an arbiter with no OpenPairings account drop one or
  more `.swar`/`.trf` files and download the IT3/FA1/IA1 FIDE report forms
  straight from them, without ever creating a tournament here.

  Parsing goes through `PairingsEngine.Tools.Parser` (dispatches on filename
  extension to `PairingsEngine.SwarImport.build_structs/1` /
  `PairingsEngine.TrfImport.build_structs/1` — both pure, no `Repo` calls).
  Two or more successfully parsed files can be combined into one "Festival"
  report via `PairingsEngine.Norms.Combine`, same as the authenticated Norms
  page would need a real multi-tournament event for.

  Nothing here is ever written to the database. This LiveView's own assigns
  (`:files`, `:master_index`, `:overlay`, `:candidate`) are mirrored into
  `PairingsEngine.Tools.Session` — a plain in-memory ETS store, keyed by a
  random `:token` generated at `mount/3` — on every change, so that
  `PairingsEngineWeb.ToolsController`'s plain `GET` download routes (a
  different process from this LiveView) can look the parsed data back up by
  token. Uploaded file bytes themselves are read via
  `consume_uploaded_entries/3` straight into memory and never touch this
  LiveView's assigns or the session store — only the parsed
  `%Tournament{}`/`%Player{}` structs do.
  """

  use PairingsEngineWeb, :live_view

  import PairingsEngineWeb.Components.ArbiterCombo
  import PairingsEngineWeb.Components.It3CountsExplain

  alias PairingsEngine.Fide
  alias PairingsEngine.Norms.{Combine, Forms}
  alias PairingsEngine.Tools.{Parser, Session}
  alias PairingsEngine.SwarImport
  alias PairingsEngineWeb.Live.ArbiterCombo

  @max_entries 10
  @max_file_size 5_000_000

  # FIDE's own printed Certificaat only ranks 2 deputies by name; anyone
  # after that prints as a plain, unranked "Arbiter" row, so this page only
  # offers 2 ranked deputy slots — see the equivalent note on
  # `PairingsEngineWeb.NormsLive`'s `@deputy_fields`. Arbiters beyond these
  # 2 go through "+ Add arbiter" (arbiter_range/1 below).
  @max_deputies 2

  @overlay_fields ~w(chief_arbiter_name chief_arbiter_fide_id chief_arbiter_email
                      organizer_name organizer_fide_id organizer_email event_code
                      fide_tournament_id) ++
                    Enum.flat_map(1..@max_deputies, &["deputy#{&1}_name", "deputy#{&1}_fide_id"])
  @candidate_fields ~w(last_name first_name fide_id federation)

  @impl true
  def mount(_params, _session, socket) do
    overlay = empty_fields(@overlay_fields)
    candidate = empty_fields(@candidate_fields)

    # Only the connected mount claims a session entry — the static render
    # never shows a download link (no files can have been parsed yet), so a
    # disconnected-mount token would just be an orphan ETS entry.
    token =
      if connected?(socket) do
        Session.put(session_payload(%{files: [], master_index: 0}, overlay, candidate))
      end

    {:ok,
     socket
     |> assign(
       page_title: "Arbiter tools — Norms",
       token: token,
       files: [],
       master_index: 0,
       overlay: overlay,
       candidate: candidate,
       # Results of the current arbiter-combobox search, keyed by which
       # official/box asked for it (see `PairingsEngineWeb.Live.ArbiterCombo`).
       arbiter_search: nil
     )
     |> allow_upload(:files,
       accept: :any,
       max_entries: @max_entries,
       max_file_size: @max_file_size
     )}
  end

  ## ---------- events ----------

  # The file input's phx-change target; nothing to do until submit — same
  # no-op pattern TournamentsLive's own SWAR/TRF/backup inputs use.
  @impl true
  def handle_event("validate_files", _params, socket), do: {:noreply, socket}

  def handle_event("parse_files", _params, socket) do
    new_rows =
      consume_uploaded_entries(socket, :files, fn %{path: path}, entry ->
        content = File.read!(path)
        {:ok, parse_row(entry.client_name, content)}
      end)

    files = socket.assigns.files ++ new_rows

    {:noreply,
     socket
     |> assign(files: files)
     |> prefill_from_master()
     |> sync_session()}
  end

  def handle_event("remove_file", %{"id" => id}, socket) do
    files = Enum.reject(socket.assigns.files, &(&1.id == id))
    master_index = clamp_master_index(socket.assigns.master_index, successful(files))

    {:noreply,
     socket
     |> assign(files: files, master_index: master_index)
     |> prefill_from_master()
     |> sync_session()}
  end

  def handle_event("set_master", %{"index" => index}, socket) do
    {:noreply,
     socket
     |> assign(master_index: String.to_integer(index))
     |> prefill_from_master()
     |> sync_session()}
  end

  def handle_event("update_fields", params, socket) do
    overlay = Map.merge(socket.assigns.overlay, Map.get(params, "overlay", %{}))
    candidate = Map.merge(socket.assigns.candidate, Map.get(params, "candidate", %{}))

    {:noreply, socket |> assign(overlay: overlay, candidate: candidate) |> sync_session()}
  end

  ## ---------- FIDE lookup for officials (shared with the signed-in Norms page) ----------

  # Both boxes of any official's combobox (name, FIDE ID) route through here —
  # see `PairingsEngineWeb.Live.ArbiterCombo` for why one shared parser/search
  # covers both, identically on this page and the signed-in Norms page.
  def handle_event("arbiter_search", params, socket) do
    case ArbiterCombo.target_role_and_field(params) do
      nil ->
        {:noreply, socket}

      {role, field} ->
        query = ArbiterCombo.target_value(params)
        {:noreply, assign(socket, arbiter_search: ArbiterCombo.search(role, field, query))}
    end
  end

  # Picking a result writes BOTH the name and the FIDE ID, which is the whole
  # point — a hand-typed id is where the wrong person ends up on a report.
  def handle_event("arbiter_pick", %{"role" => role, "fide-id" => fide_id}, socket) do
    case ArbiterCombo.picked_player(fide_id) do
      nil ->
        {:noreply, assign(socket, arbiter_search: nil)}

      fp ->
        overlay =
          socket.assigns.overlay
          |> Map.put(arbiter_name_key(role), fp.name)
          |> Map.put("#{role}_fide_id", to_string(fp.fide_id))
          |> Map.delete(arbiter_name_key(role) <> "_hint")

        {:noreply, socket |> assign(overlay: overlay, arbiter_search: nil) |> sync_session()}
    end
  end

  # Arbiters beyond the IT3 template's 4 built-in deputy slots — see the
  # identical mechanism (and why it's a plain count, not a list) on
  # `PairingsEngineWeb.NormsLive`. `sync_session/1` because the count lives
  # in `overlay`, same as any other officials field on this page.
  def handle_event("add_arbiter", _params, socket) do
    overlay = bump_extra_arbiters(socket.assigns.overlay, 1)
    {:noreply, socket |> assign(overlay: overlay) |> sync_session()}
  end

  def handle_event("remove_last_arbiter", _params, socket) do
    overlay = bump_extra_arbiters(socket.assigns.overlay, -1)
    {:noreply, socket |> assign(overlay: overlay) |> sync_session()}
  end

  def handle_event("pick_candidate", %{"pick" => ""}, socket) do
    {:noreply, assign(socket, candidate: empty_fields(@candidate_fields)) |> sync_session()}
  end

  def handle_event("pick_candidate", %{"pick" => role}, socket) do
    {:noreply,
     socket
     |> assign(candidate: candidate_from_official(socket.assigns.overlay, role))
     |> sync_session()}
  end

  def handle_event("pick_candidate", _params, socket), do: {:noreply, socket}

  ## ---------- parsing ----------

  defp parse_row(filename, content) do
    case Parser.parse(filename, content) do
      {:ok, {tournament, players}} ->
        %{id: row_id(), filename: filename, tournament: tournament, players: players, error: nil}

      {:error, message} ->
        %{id: row_id(), filename: filename, tournament: nil, players: nil, error: message}
    end
  end

  defp row_id, do: System.unique_integer([:positive, :monotonic]) |> Integer.to_string()

  defp successful(files), do: Enum.filter(files, &is_nil(&1.error))

  defp failed(files), do: Enum.reject(files, &is_nil(&1.error))

  defp clamp_master_index(_index, []), do: 0
  defp clamp_master_index(index, files), do: index |> max(0) |> min(length(files) - 1)

  ## ---------- officials prefill (from the master file) ----------

  # Fills the officials overlay fields from the master file's own parsed
  # tournament — but only fields the arbiter's overlay currently has blank,
  # so a value they already typed (or already changed back to something
  # else) is never clobbered. Safe to call after every files/master_index
  # change; re-running it is a no-op for any field that's already filled.
  defp prefill_from_master(socket) do
    case successful(socket.assigns.files) |> Enum.at(socket.assigns.master_index) do
      nil ->
        socket

      %{tournament: tournament} ->
        event_code = collapse_event_codes(event_codes(socket.assigns.files))
        officials = tournament.officials || %{}

        # Deliberately NOT prefilled: `tournament.organizer` (SWAR's
        # dedicated "organizer" binary field, separate from arbiter1/
        # arbiter2) is an organizing body/venue string ("VPTD
        # Geraardsbergen"), not a person's name — running it through the
        # same FIDE person-matcher as chief_arbiter/deputies would either
        # find nothing (an unhelpful hint next to a "search for a person"
        # box) or, worse, a false-positive match to an unrelated namesake.
        # The organizer combobox is left for the arbiter to fill in by hand.
        overlay =
          socket.assigns.overlay
          |> maybe_prefill_official(
            "chief_arbiter_name",
            "chief_arbiter_fide_id",
            tournament.chief_arbiter
          )
          |> maybe_prefill("event_code", event_code)

        # `tournament.deputy_arbiter` is SWAR's raw, un-split field (multiple
        # people in one comma-joined string, e.g. "IA Sylvin De Vet, NA Marc
        # Van Dyck") — using it here dumped the whole string into deputy1
        # alone. `tournament.officials` is the already-split, per-person map
        # both SWAR (`SwarImport.split_officials/1`) and TRF (one deputy per
        # line) produce, and what the signed-in Norms page's officials card
        # already reads — so prefilling from it here keeps both pages
        # consistent instead of one silently doing worse than the other.
        overlay =
          Enum.reduce(1..4, overlay, fn n, acc ->
            maybe_prefill_official(
              acc,
              "deputy#{n}_name",
              "deputy#{n}_fide_id",
              Map.get(officials, "deputy#{n}_name", "")
            )
          end)

        assign(socket, overlay: overlay)
    end
  end

  defp maybe_prefill(overlay, key, value) do
    value = value |> to_string() |> String.trim()
    current = Map.get(overlay, key, "") |> to_string() |> String.trim()

    if current == "" and value != "" do
      Map.put(overlay, key, value)
    else
      overlay
    end
  end

  # Officials prefill used to dump whatever raw text a SWAR/TRF file carried
  # straight into the name box, unverified — the same info a hand-typed FIDE
  # ID would carry, which is exactly what the arbiter combobox's split
  # name/id boxes exist to prevent everywhere else on this page. A file's
  # spelling can also disagree with FIDE's own ("Sylvin De Vet" vs. FIDE's
  # "De Vet, Sylvin"), so this reuses the exact same order-independent
  # matcher the persisting SWAR import path already trusts
  # (`SwarImport.match_official_fide_player/1`) rather than a second
  # heuristic that could drift from it.
  #
  # A confident (exactly one) match fills both the name (FIDE's own "Last,
  # First" spelling) and the FIDE ID, same as picking that result by hand
  # would. No match — or an already-filled name, so a value the arbiter
  # already typed or picked is never clobbered — leaves the name/ID boxes
  # untouched; the raw text is kept under `"#{name_key}_hint"` instead, so
  # `ArbiterCombo` can show "what you DO know" next to the empty box rather
  # than silently discarding what the file did provide.
  defp maybe_prefill_official(overlay, name_key, id_key, raw_name) do
    raw_name = raw_name |> to_string() |> String.trim()
    current_name = overlay |> Map.get(name_key, "") |> to_string() |> String.trim()
    hint_key = "#{name_key}_hint"

    cond do
      raw_name == "" ->
        overlay

      current_name != "" ->
        overlay

      true ->
        case SwarImport.match_official_fide_player(raw_name) do
          nil ->
            Map.put(overlay, hint_key, raw_name)

          fp ->
            overlay
            |> Map.put(name_key, fp.name)
            |> Map.put(id_key, to_string(fp.fide_id))
            |> Map.delete(hint_key)
        end
    end
  end

  ## ---------- FIDE event code collection ----------

  @doc false
  # Every successful file's own event code(s) — checked on both
  # `tournament.event_code` and a same-named `"event_code"` key under
  # `tournament.officials`, in case a future import path only populates one
  # of the two. Blank/missing values are dropped, order/duplicates aside.
  def event_codes(files) do
    files
    |> successful()
    |> Enum.flat_map(fn %{tournament: tournament} ->
      [tournament.event_code, Map.get(tournament.officials || %{}, "event_code")]
    end)
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  @doc """
  Collapses a list of FIDE event-code strings into one editable string:
  consecutive integer runs become `"start-end"` ranges, everything else is
  comma-joined as-is. `[10001, 10002, 10003] -> "10001-10003"`,
  `[10001, 10003, 10004] -> "10001, 10003-10004"`.
  """
  def collapse_event_codes(codes) when is_list(codes) do
    codes = codes |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()
    {int_strings, other_codes} = Enum.split_with(codes, &integer_string?/1)

    ranges =
      int_strings
      |> Enum.map(&String.to_integer/1)
      |> Enum.sort()
      |> collapse_consecutive_ints()

    (ranges ++ other_codes) |> Enum.join(", ")
  end

  defp integer_string?(s), do: Regex.match?(~r/^\d+$/, s)

  defp collapse_consecutive_ints(sorted_ints) do
    sorted_ints
    |> Enum.chunk_while(
      [],
      fn n, run ->
        case run do
          [last | _] when n == last + 1 -> {:cont, [n | run]}
          [] -> {:cont, [n]}
          _ -> {:cont, Enum.reverse(run), [n]}
        end
      end,
      fn
        [] -> {:cont, []}
        run -> {:cont, Enum.reverse(run), []}
      end
    )
    |> Enum.map(&format_run/1)
  end

  defp format_run([n]), do: Integer.to_string(n)
  defp format_run(run), do: "#{List.first(run)}-#{List.last(run)}"

  ## ---------- uploaded-files totals ----------

  defp present?(v), do: v not in [nil, ""]

  # Deliberately delegates rather than re-implementing: this table sits next to
  # a download whose own titled count comes from `Forms.titled?/1`, and the two
  # disagreeing (CM counted here, excluded there) is worse than either answer.
  defp titled_players(players), do: Enum.count(players, &Forms.titled?/1)

  defp federations(players) do
    players |> Enum.map(& &1.federation) |> Enum.filter(&present?/1) |> Enum.uniq()
  end

  @doc false
  def total_players(files),
    do: files |> successful() |> Enum.map(&length(&1.players)) |> Enum.sum()

  @doc false
  def total_titled_players(files) do
    files |> successful() |> Enum.map(&titled_players(&1.players)) |> Enum.sum()
  end

  @doc false
  def total_federations(files) do
    files |> successful() |> Enum.flat_map(&federations(&1.players)) |> Enum.uniq() |> length()
  end

  # The same pooled player list Combine.combine/2 would hand
  # PairingsEngineWeb.ToolsController for an actual IT3 download — reused
  # here (not a naive flat-map across files) so the counts explainer never
  # disagrees with the report it's explaining, e.g. by double-counting a
  # player Combine itself dedupes across files. `nil` when there's nothing
  # to combine yet or the files conflict (same failure modes the download
  # button already guards against via report_blockers/1).
  defp combined_for_explain(files, master_index) do
    pairs = files |> successful() |> Enum.map(&{&1.tournament, &1.players})

    with [_ | _] <- pairs,
         {:ok, {tournament, players}} <- Combine.combine(pairs, master_index) do
      {players, tournament.federation}
    else
      _ -> nil
    end
  end

  @doc """
  Federations that appear in two or more of the uploaded (successful)
  files — the "duplicate feds" signal an arbiter watches for before
  combining files into a Festival. Sorted for stable display.
  """
  def shared_federations(files) do
    files
    |> successful()
    |> Enum.map(&(federations(&1.players) |> MapSet.new()))
    |> Enum.reduce(%{}, fn feds, counts ->
      Enum.reduce(feds, counts, fn fed, acc -> Map.update(acc, fed, 1, &(&1 + 1)) end)
    end)
    |> Enum.filter(fn {_fed, count} -> count >= 2 end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  ## ---------- session sync ----------

  defp sync_session(socket) do
    Session.put(
      socket.assigns.token,
      session_payload(
        %{files: socket.assigns.files, master_index: socket.assigns.master_index},
        socket.assigns.overlay,
        socket.assigns.candidate
      )
    )

    socket
  end

  defp session_payload(%{files: files, master_index: master_index}, overlay, candidate) do
    %{files: files, master_index: master_index, overlay: overlay, candidate: candidate}
  end

  defp empty_fields(keys), do: Map.new(keys, &{&1, ""})

  ## ---------- view helpers ----------

  defp rounds_label(%{rounds_count: n}), do: n

  defp upload_error_label(:too_large), do: "File is larger than 5 MB"
  defp upload_error_label(:too_many_files), do: "Too many files — 10 at a time, max"
  defp upload_error_label(:not_accepted), do: "That file type isn't accepted"
  defp upload_error_label(other), do: inspect(other)

  # The overlay stores the chief arbiter's name under a different key from the
  # deputies', so roles ("chief_arbiter" / "deputyN") map to a name key here
  # rather than being string-built at each call site.
  # Same rule the signed-in Norms page enforces: FIDE identifies every official
  # by FIDE ID and bounces a report missing one, and there is no such thing as
  # an arbiter without an id — so a named official with no id blocks the
  # download rather than producing a file that gets rejected.
  #
  # An official left entirely blank is fine: not every event has two deputies,
  # and this page has no chief arbiter until the arbiter fills one in.
  #
  # Chief arbiter's and organizer's e-mail are ALSO required — FIDE's own
  # template prints "PRIVACY NOTICE: Chief Organizer's and Chief Arbiter's
  # e-mail address is required only for institutional purposes and will be
  # displayed on FIDE website" right on the Certificaat sheet, same rule the
  # signed-in Norms page enforces.
  defp report_blockers(overlay) do
    fide_id =
      if blank_overlay?(overlay, "fide_tournament_id"), do: ["FIDE tournament ID"], else: []

    ids =
      for {role, label} <- arbiter_roles(overlay),
          name = Map.get(overlay, arbiter_name_key(role), ""),
          String.trim(to_string(name)) != "",
          String.trim(to_string(Map.get(overlay, "#{role}_fide_id", ""))) == "",
          do: label

    emails =
      [
        blank_overlay?(overlay, "chief_arbiter_email") && "Chief arbiter e-mail",
        blank_overlay?(overlay, "organizer_email") && "Organizer e-mail"
      ]
      |> Enum.filter(& &1)

    fide_id ++ ids ++ emails
  end

  defp blank_overlay?(overlay, key),
    do: overlay |> Map.get(key, "") |> to_string() |> String.trim() == ""

  defp arbiter_name_key("chief_arbiter"), do: "chief_arbiter_name"
  # Every other role (deputies and extra arbiters) follows "<role>_name".
  defp arbiter_name_key(role), do: "#{role}_name"

  defp arbiter_roles(overlay),
    do: [{"chief_arbiter", "Chief arbiter"} | deputy_roles()] ++ extra_arbiter_roles(overlay)

  defp deputy_range, do: 1..@max_deputies
  defp deputy_roles, do: for(n <- deputy_range(), do: {"deputy#{n}", "Deputy #{n}"})

  defp extra_arbiter_roles(overlay) do
    for n <- extra_arbiter_range(Map.get(overlay, "extra_arbiters_count")),
        do: {"arbiter#{n}", "Arbiter #{n}"}
  end

  # 1..count is a *descending* range (iterating count..1) when count is 0 —
  # so 0 (the common case: no extra arbiters) has to short-circuit to an
  # empty range explicitly.
  defp extra_arbiter_range(count) do
    case parse_extra_count(count) do
      n when n > 0 -> 1..n
      _ -> 1..0//1
    end
  end

  defp parse_extra_count(nil), do: 0
  defp parse_extra_count(n) when is_integer(n), do: n

  defp parse_extra_count(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp bump_extra_arbiters(overlay, delta) do
    current = parse_extra_count(Map.get(overlay, "extra_arbiters_count"))
    new_count = max(current + delta, 0)

    overlay = Map.put(overlay, "extra_arbiters_count", new_count)

    if delta < 0 do
      overlay |> Map.delete("arbiter#{current}_name") |> Map.delete("arbiter#{current}_fide_id")
    else
      overlay
    end
  end

  # Officials with a name filled in, offered as FA1/IA1 norm candidates.
  defp candidate_options(overlay) do
    for {role, label} <- arbiter_roles(overlay),
        name = Map.get(overlay, arbiter_name_key(role), ""),
        String.trim(to_string(name)) != "",
        do: {"#{label} - #{name}", role}
  end

  # Prefer the FIDE record when the official has an id: it settles the
  # first/last split ("De Vet, Sylvin") and supplies the federation, neither of
  # which can be guessed from word position on a multi-word surname.
  defp candidate_from_official(overlay, role) do
    name = Map.get(overlay, arbiter_name_key(role), "")
    fide_id = Map.get(overlay, "#{role}_fide_id", "")

    case Fide.get_player(fide_id) do
      nil ->
        {last, first} = split_plain_name(name)
        %{"last_name" => last, "first_name" => first, "fide_id" => "", "federation" => ""}

      fp ->
        {last, first} = split_fide_name(fp.name)

        %{
          "last_name" => last,
          "first_name" => first,
          "fide_id" => to_string(fp.fide_id),
          "federation" => fp.federation || ""
        }
    end
  end

  defp split_fide_name(name) do
    case String.split(to_string(name), ",", parts: 2) do
      [last, first] -> {String.trim(last), String.trim(first)}
      [only] -> {String.trim(only), ""}
    end
  end

  defp split_plain_name(name) do
    case String.split(to_string(name), ~r/\s+/, trim: true) do
      [] -> {"", ""}
      [only] -> {only, ""}
      [first | rest] -> {Enum.join(rest, " "), first}
    end
  end

  attr :field, :string, required: true
  attr :label, :string, required: true
  attr :values, :map, required: true
  attr :prefix, :string, required: true
  attr :hint, :string, default: nil

  defp overlay_input(assigns) do
    ~H"""
    <label class="field">
      <span>{@label}</span>
      <input name={"#{@prefix}[#{@field}]"} value={Map.get(@values, @field, "")} />
      <p :if={@hint} class="hint" style="margin: 2px 0 0; font-size: 0.85em">{@hint}</p>
    </label>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active="tools">
      <div class="page-header">
        <div>
          <h1>Arbiter tools</h1>
          <p class="subtitle" style="margin: 0">
            Upload a SWAR or TRF file, no account needed - download the IT3/FA1/IA1 FIDE report forms.
          </p>
        </div>
      </div>

      <p class="hint">
        Nothing here is saved: uploaded files are parsed in memory only, never written to a
        database, and this whole session (files, officials, arbiter candidate) is discarded after
        60 minutes of inactivity or as soon as you close the tab and come back later. See
        <.link navigate={~p"/"}>OpenPairings</.link>
        if you'd rather manage a tournament with an account.
      </p>

      <form
        id="tools-upload-form"
        class="card"
        phx-submit="parse_files"
        phx-change="validate_files"
      >
        <h2>Upload files</h2>
        <p class="hint" style="margin-top: 0">
          Up to 10 files, 5 MB each - <code>.swar</code> or <code>.trf</code>. Two or more files
          combine into one "Festival" report (see below).
        </p>

        <div
          class={["dropzone", @uploads.files.entries != [] && "has-file"]}
          phx-drop-target={@uploads.files.ref}
        >
          <.live_file_input upload={@uploads.files} class="dropzone-input" />
          <div class="dropzone-label">
            <%= if @uploads.files.entries == [] do %>
              <strong>Choose SWAR/TRF files</strong>
              <span class="hint">or drag and drop them here</span>
            <% else %>
              <span :for={entry <- @uploads.files.entries} class="dropzone-file">
                {entry.client_name}
              </span>
            <% end %>
          </div>
        </div>

        <p :for={err <- upload_errors(@uploads.files)} class="error-note">
          {upload_error_label(err)}
        </p>
        <div :for={entry <- @uploads.files.entries}>
          <p :for={err <- upload_errors(@uploads.files, entry)} class="error-note">
            {entry.client_name}: {upload_error_label(err)}
          </p>
        </div>

        <div class="actions">
          <button type="submit" class="pe-btn primary" disabled={@uploads.files.entries == []}>
            Parse files
          </button>
        </div>
      </form>

      <div :if={@files != []} class="card table-card">
        <h2 style="padding: 16px 16px 0">Uploaded files</h2>
        <table class="pe-table">
          <thead>
            <tr>
              <th :if={successful(@files) |> length() >= 2}>Master</th>
              <th>File</th>
              <th>Tournament</th>
              <th class="num" style="text-align: right">Players</th>
              <th class="num" style="text-align: right">Rounds</th>
              <th class="num" style="text-align: right">Titled</th>
              <th class="num" style="text-align: right">Feds</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={{row, idx} <- Enum.with_index(successful(@files))}>
              <td :if={successful(@files) |> length() >= 2}>
                <input
                  type="radio"
                  name="master_index"
                  checked={@master_index == idx}
                  phx-click="set_master"
                  phx-value-index={idx}
                />
              </td>
              <td>{row.filename}</td>
              <td>{row.tournament.name}</td>
              <td class="num">{length(row.players)}</td>
              <td class="num">{rounds_label(row.tournament)}</td>
              <td class="num">{titled_players(row.players)}</td>
              <td class="num">{length(federations(row.players))}</td>
              <td style="text-align: right">
                <button class="pe-btn danger-link" phx-click="remove_file" phx-value-id={row.id}>
                  Remove
                </button>
              </td>
            </tr>
            <tr :for={row <- failed(@files)}>
              <td :if={successful(@files) |> length() >= 2}></td>
              <td>{row.filename}</td>
              <td colspan="5" class="error-note">{row.error}</td>
              <td style="text-align: right">
                <button class="pe-btn danger-link" phx-click="remove_file" phx-value-id={row.id}>
                  Remove
                </button>
              </td>
            </tr>
          </tbody>
        </table>

        <p class="hint" style="padding: 12px 16px 0; margin: 0">
          Totals across {length(successful(@files))} uploaded file(s): {total_players(@files)} player(s), {total_titled_players(
            @files
          )} titled, {total_federations(@files)} distinct federation(s).
        </p>
        <p
          :if={shared_federations(@files) != []}
          class="hint"
          style="padding: 4px 16px 16px; margin: 0"
        >
          Federations shared across files: {Enum.join(shared_federations(@files), ", ")}.
        </p>
        <p
          :if={shared_federations(@files) == []}
          class="hint"
          style="padding: 4px 16px 16px; margin: 0"
        >
          No federation appears in more than one uploaded file.
        </p>

        <p :if={successful(@files) |> length() >= 2} class="hint" style="padding: 0 16px 16px">
          These {successful(@files) |> length()} files combine into one "Festival" report - the
          master file supplies the name/dates/venue/officials, players from every file are pooled,
          and the same player can't appear in more than one of them.
        </p>
      </div>

      <div :if={successful(@files) != []} class="card">
        <h2>Officials &amp; arbiter candidate</h2>
        <p class="hint" style="margin-top: 0">
          Fill in anything the uploaded file(s) don't already carry - nothing here is saved either.
        </p>

        <form id="tools-fields-form" phx-change="update_fields">
          <div class="form-grid">
            <.arbiter_combo
              role="chief_arbiter"
              label="Chief arbiter"
              required
              name_field="overlay[chief_arbiter_name]"
              name_value={Map.get(@overlay, "chief_arbiter_name", "")}
              id_field="overlay[chief_arbiter_fide_id]"
              id_value={Map.get(@overlay, "chief_arbiter_fide_id", "")}
              search={@arbiter_search}
              hint={Map.get(@overlay, "chief_arbiter_name_hint")}
            />
            <.overlay_input
              prefix="overlay"
              field="chief_arbiter_email"
              label="Chief arbiter e-mail"
              values={@overlay}
            />
            <.arbiter_combo
              role="organizer"
              label="Organizer"
              name_field="overlay[organizer_name]"
              name_value={Map.get(@overlay, "organizer_name", "")}
              id_field="overlay[organizer_fide_id]"
              id_value={Map.get(@overlay, "organizer_fide_id", "")}
              search={@arbiter_search}
              hint={Map.get(@overlay, "organizer_name_hint")}
            />
            <.overlay_input
              prefix="overlay"
              field="organizer_email"
              label="Organizer e-mail"
              values={@overlay}
            />
            <.overlay_input
              prefix="overlay"
              field="event_code"
              label="FIDE event code"
              hint="Your federation's rating-homologation code, e.g. BEL2026001."
              values={@overlay}
            />
            <.overlay_input
              prefix="overlay"
              field="fide_tournament_id"
              label="FIDE tournament ID"
              hint="This report's own numeric ID at FIDE — a different thing from the event code above."
              values={@overlay}
            />
          </div>

          <h3 style="margin-bottom: 4px">Deputy arbiters</h3>
          <div :for={n <- deputy_range()} class="form-grid">
            <.arbiter_combo
              role={"deputy#{n}"}
              label={"Deputy #{n}"}
              name_field={"overlay[deputy#{n}_name]"}
              name_value={Map.get(@overlay, "deputy#{n}_name", "")}
              id_field={"overlay[deputy#{n}_fide_id]"}
              id_value={Map.get(@overlay, "deputy#{n}_fide_id", "")}
              search={@arbiter_search}
              hint={Map.get(@overlay, "deputy#{n}_name_hint")}
            />
          </div>

          <h3 style="margin-bottom: 4px">
            Additional arbiters
            <span class="hint" style="font-weight: normal">
              (beyond chief + 2 deputies — FIDE doesn't rank these, so IT3 prints each as a
              plain "Arbiter" row)
            </span>
          </h3>
          <div
            :for={n <- extra_arbiter_range(Map.get(@overlay, "extra_arbiters_count"))}
            class="form-grid"
          >
            <.arbiter_combo
              role={"arbiter#{n}"}
              label={"Arbiter #{n}"}
              name_field={"overlay[arbiter#{n}_name]"}
              name_value={Map.get(@overlay, "arbiter#{n}_name", "")}
              id_field={"overlay[arbiter#{n}_fide_id]"}
              id_value={Map.get(@overlay, "arbiter#{n}_fide_id", "")}
              search={@arbiter_search}
            />
          </div>
          <div class="actions" style="margin: 4px 0 12px">
            <button type="button" class="pe-btn" phx-click="add_arbiter">+ Add arbiter</button>
            <button
              :if={parse_extra_count(Map.get(@overlay, "extra_arbiters_count")) > 0}
              type="button"
              class="pe-btn danger-link"
              phx-click="remove_last_arbiter"
            >
              Remove last arbiter
            </button>
          </div>

          <h3 style="margin-bottom: 4px">FA1 / IA1 arbiter norm candidate</h3>
          <label :if={candidate_options(@overlay) != []} class="field">
            <span>Pick an arbiter</span>
            <select name="pick" phx-change="pick_candidate">
              <option value="">- type the details by hand -</option>
              <option :for={{label, role} <- candidate_options(@overlay)} value={role}>
                {label}
              </option>
            </select>
          </label>
          <div class="form-grid">
            <.overlay_input
              prefix="candidate"
              field="last_name"
              label="Last name"
              values={@candidate}
            />
            <.overlay_input
              prefix="candidate"
              field="first_name"
              label="First name"
              values={@candidate}
            />
            <.overlay_input prefix="candidate" field="fide_id" label="FIDE ID" values={@candidate} />
            <.overlay_input
              prefix="candidate"
              field="federation"
              label="Federation"
              values={@candidate}
            />
          </div>
        </form>
      </div>

      <div :if={successful(@files) != []} class="card">
        <h2>Download</h2>
        <div :if={report_blockers(@overlay) != []} class="report-blocked">
          <strong>Not ready to submit to FIDE.</strong>
          FIDE identifies every official by FIDE ID and bounces a report missing one. Type their
          name or FIDE ID above and pick the matching result — missing for: {Enum.join(
            report_blockers(@overlay),
            ", "
          )}.
        </div>
        <div class="actions">
          <a
            :if={report_blockers(@overlay) == []}
            class="pe-btn primary"
            href={~p"/tools/download/#{@token}/it3"}
          >
            Download IT3
          </a>
          <a
            :if={report_blockers(@overlay) == []}
            class="pe-btn primary"
            href={~p"/tools/download/#{@token}/fa1"}
          >
            Download FA1 (FIDE Arbiter)
          </a>
          <a
            :if={report_blockers(@overlay) == []}
            class="pe-btn primary"
            href={~p"/tools/download/#{@token}/ia1"}
          >
            Download IA1 (International Arbiter)
          </a>
          <button :if={report_blockers(@overlay) != []} class="pe-btn" disabled>
            Download IT3 / FA1 / IA1
          </button>
        </div>
        <% combined = combined_for_explain(@files, @master_index) %>
        <.it3_counts_explain
          :if={combined}
          players={elem(combined, 0)}
          host_federation={elem(combined, 1)}
        />
      </div>
    </Layouts.app>
    """
  end
end
