defmodule PairingsEngineWeb.Components.ArbiterCombo do
  @moduledoc """
  One official's name + FIDE-ID combobox - the single shared rendering used
  by both `PairingsEngineWeb.NormsLive` (signed-in) and
  `PairingsEngineWeb.ToolsNormsLive` (public), so the two pages render and
  behave identically for this field instead of shipping two hand-rolled
  look-alikes. The mechanics (parsing which box changed, searching, what to
  show) live in `PairingsEngineWeb.Live.ArbiterCombo`; this module is pure
  markup.

  Both boxes - name and FIDE ID - are plain, always-typeable text inputs.
  Typing in EITHER searches (debounced) and shows a dropdown attached
  directly under THAT box, not a shared results area bolted on below a
  separate "Find in FIDE" button. Picking a result from either dropdown
  fills both boxes and is the only way a FIDE ID is ever committed: the
  visible ID box is a pure SEARCH field (its own `name`,
  `ArbiterCombo.id_search_name/1`, is never the one a save/sync reads), and
  the real, submitted id travels in its own hidden `@id_field` input that
  only `arbiter_pick` ever changes. Without that separation, whatever
  digits were sitting in the search box at submit time - never verified
  against FIDE, possibly mid-search, possibly just mistyped - would be
  what gets saved, which defeats the entire point of this combobox.

  The calling LiveView owns two `handle_event` clauses, verbatim on both
  pages:

      def handle_event("arbiter_search", params, socket) do
        case ArbiterCombo.target_role_and_field(params) do
          nil -> {:noreply, socket}
          {role, field} ->
            query = ArbiterCombo.target_value(params)
            {:noreply, assign(socket, arbiter_search: ArbiterCombo.search(role, field, query))}
        end
      end

      def handle_event("arbiter_pick", %{"role" => role, "fide-id" => fide_id}, socket) do
        case ArbiterCombo.picked_player(fide_id) do
          nil -> {:noreply, socket}
          fp -> {:noreply, socket |> apply_pick(role, fp) |> assign(arbiter_search: nil)}
        end
      end

  `apply_pick/3` is the one genuinely page-specific piece - where the name
  and id actually get stored differs (an `Ecto`-backed `%Tournament{}` vs. an
  in-memory overlay map), which is why it stays a small per-page function
  rather than something this shared code could own.
  """

  use Phoenix.Component
  use Gettext, backend: PairingsEngineWeb.Gettext

  alias PairingsEngine.Fide.FidePlayer
  alias PairingsEngineWeb.Live.ArbiterCombo

  attr :role, :string, required: true
  attr :label, :string, required: true
  attr :required, :boolean, default: false
  attr :name_field, :string, required: true
  attr :name_value, :string, required: true
  attr :id_field, :string, required: true
  attr :id_value, :string, required: true
  attr :search, :any, default: nil
  attr :hint, :string, default: nil

  def arbiter_combo(assigns) do
    ~H"""
    <div class="field arbiter-combo" id={"arbiter-combo-#{@role}"}>
      <span class="arbiter-combo-label">
        {@label}<span :if={@required} style="color: var(--danger)">*</span>
      </span>
      <div class="arbiter-combo-row">
        <div class="search-wrap arbiter-combo-name">
          <input
            type="text"
            id={"arbiter-combo-#{@role}-name"}
            name={@name_field}
            value={@name_value}
            phx-change="arbiter_search"
            phx-debounce="300"
            autocomplete="off"
            placeholder="Name"
          />
          <p
            :if={@name_value in ["", nil] and @hint not in ["", nil]}
            class="hint"
            style="margin: 2px 0 0; font-size: 0.85em"
          >
            {gettext(
              "Uploaded file says: %{hint} - no confident FIDE match, please search or type it in.",
              hint: @hint
            )}
          </p>
          <.results
            id={"arbiter-combo-#{@role}-name-results"}
            options={ArbiterCombo.results_for(@search, @role, :name)}
            role={@role}
          />
        </div>
        <div class="search-wrap arbiter-combo-id">
          <input
            type="hidden"
            id={"arbiter-combo-#{@role}-id-hidden"}
            name={@id_field}
            value={@id_value}
          />
          <input
            type="text"
            id={"arbiter-combo-#{@role}-id-search"}
            inputmode="numeric"
            name={ArbiterCombo.id_search_name(@role)}
            value={@id_value}
            phx-change="arbiter_search"
            phx-debounce="300"
            autocomplete="off"
            placeholder="FIDE ID"
          />
          <.results
            id={"arbiter-combo-#{@role}-id-results"}
            options={ArbiterCombo.results_for(@search, @role, :id)}
            role={@role}
          />
        </div>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :options, :list, required: true
  attr :role, :string, required: true

  defp results(assigns) do
    ~H"""
    <div :if={@options != []} id={@id} class="search-results">
      <button
        :for={fp <- @options}
        type="button"
        phx-click="arbiter_pick"
        phx-value-role={@role}
        phx-value-fide-id={fp.fide_id}
      >
        <span>{if fp.title != "", do: "#{fp.title} "}{fp.name}</span>
        <span class="meta">{option_meta(fp)}</span>
      </button>
    </div>
    """
  end

  # Federation alone can't separate namesakes (BEL has two "Van Dyck, Marc"),
  # so the row carries birth year, rating and id too.
  defp option_meta(%FidePlayer{} = fp) do
    [
      fp.federation,
      fp.birth_year && "b. #{fp.birth_year}",
      fp.standard_rating && fp.standard_rating > 0 && "#{fp.standard_rating}",
      "##{fp.fide_id}"
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" · ")
  end
end
