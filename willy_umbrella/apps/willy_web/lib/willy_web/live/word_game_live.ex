defmodule WillyWeb.WordGameLive do
  use WillyWeb, :live_view

  @topic "word_game"

  def mount(_params, _session, socket) do
    # Everyone starts as a spectator
    socket = assign(socket,
      player_id: nil,
      role: :spectator,
      nickname: nil,
      main_word: "",
      guess_words: [],
      players: %{},
      game_status: :waiting,
      page_title: "10 gegen Willy"
    )

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Willy.PubSub, @topic)
    end

    {:ok, socket}
  end

  # Join as player or host
  def handle_event("join_game", %{"nickname" => nickname, "as" => as}, socket) do
    player_id = "player_" <> :crypto.strong_rand_bytes(8) |> Base.encode16()
    role = String.to_atom(as)

    case WillyWeb.GameState.join_game(player_id, nickname, role) do
      {:ok, :host} ->
        {:noreply, assign(socket, player_id: player_id, role: :host, nickname: nickname)}
      {:ok, :player} ->
        {:noreply, assign(socket, player_id: player_id, role: :player, nickname: nickname)}
      {:error, :host_exists} ->
        {:noreply, put_flash(socket, :error, "A host already exists. Please join as a player.")}
      {:error, :game_full} ->
        {:noreply, put_flash(socket, :error, "Game is full!")}
    end
  end

  # Leave game, become spectator
  def handle_event("leave_game", _params, socket) do
    if socket.assigns.player_id do
      WillyWeb.GameState.leave_game(socket.assigns.player_id)
    end
    {:noreply, assign(socket, player_id: nil, role: :spectator, nickname: nil)}
  end

  def handle_event("update_main_word", %{"value" => word}, socket) do
    if socket.assigns.role == :host do
      WillyWeb.GameState.update_main_word(socket.assigns.player_id, word)
    end
    {:noreply, socket}
  end

  def handle_event("add_guess_word", %{"key" => "Enter", "value" => word}, socket) when word != "" do
    if socket.assigns.role in [:host, :player] do
      WillyWeb.GameState.add_guess_word(socket.assigns.player_id, word)
    end
    {:noreply, socket}
  end

  def handle_event("add_guess_word", _, socket), do: {:noreply, socket}

  def handle_event("remove_guess_word", %{"index" => index}, socket) do
    if socket.assigns.role in [:host, :player] do
      WillyWeb.GameState.remove_guess_word(socket.assigns.player_id, String.to_integer(index))
    end
    {:noreply, socket}
  end

  # Handle state updates broadcast from PubSub
  def handle_info({:state_updated, new_state}, socket) do
    {:noreply,
     assign(socket,
       main_word: new_state.main_word,
       guess_words: new_state.guess_words,
       players: new_state.players,
       game_status: new_state.game_status,
       host_id: new_state.host_id
     )}
  end

  def terminate(_reason, socket) do
    if connected?(socket) and socket.assigns.player_id do
      WillyWeb.GameState.leave_game(socket.assigns.player_id)
    end
  end

  defp host_exists?(players) do
    # Host is always the first player in the map (by join order)
    Map.keys(players) != []
  end

  def render(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto p-6">
      <h1 class="text-2xl font-bold mb-6">10 gegen Willy</h1>

      <%= if assigns.role == :spectator do %>
        <div class="mb-6 p-4 bg-yellow-50 border border-yellow-200 rounded">
          <h2 class="font-semibold mb-2">Join the game</h2>
          <.form :let={f} for={%{}} phx-submit="join_game">
            <input name="nickname" type="text" placeholder="Your nickname" required class="mb-2 block w-full rounded border px-2 py-1" />
            <div class="flex gap-2">
              <button name="as" value="player" class="bg-blue-500 text-white px-4 py-1 rounded">Join as Player</button>
              <%= if !host_exists?(@players) do %>
                <button name="as" value="host" class="bg-green-600 text-white px-4 py-1 rounded">Join as Host</button>
              <% end %>
            </div>
          </.form>
        </div>
      <% else %>
        <div class="mb-4 flex justify-between items-center">
          <div>
            <h2 class="text-lg font-semibold mb-2">Players</h2>
            <div class="flex flex-wrap gap-2">
              <%= for {id, name} <- @players do %>
                <div class="bg-blue-100 px-3 py-1 rounded-full text-sm">
                  <%= name %>
                  <%= if id == @host_id, do: " (Host)" %>
                  <%= if id == @player_id, do: " (You)" %>
                </div>
              <% end %>
            </div>
          </div>
          <form phx-submit="leave_game">
            <button class="text-red-600 underline ml-4" type="submit">Leave game</button>
          </form>
        </div>

        <div class="space-y-6">
          <div>
            <label class="block text-sm font-medium text-gray-700 mb-2">
              Main Word <%= if @role == :host, do: "(You can edit this)" %>
            </label>
            <%= if @role == :host do %>
              <input
                type="text"
                value={@main_word}
                phx-keyup="update_main_word"
                class="block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500"
                placeholder="Enter the main word"
              />
            <% else %>
              <div class="block w-full rounded-md border border-gray-300 bg-gray-50 px-3 py-2">
                <%= if @main_word == "", do: "Waiting for host to enter a word...", else: @main_word %>
              </div>
            <% end %>
          </div>

          <div>
            <label class="block text-sm font-medium text-gray-700 mb-2">
              Guess Words (<%= length(@guess_words) %>/10)
            </label>
            <input
              type="text"
              id="new-guess-word"
              phx-keydown="add_guess_word"
              class="block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500"
              placeholder="Type and press Enter to add"
              disabled={@role == :spectator or length(@guess_words) >= 10}
            />
          </div>

          <div class="flex flex-wrap gap-2">
            <%= for {word, index} <- Enum.with_index(@guess_words) do %>
              <div class="flex items-center bg-gray-100 rounded-full px-3 py-1">
                <span class="text-sm"><%= word %></span>
                <button
                  type="button"
                  phx-click="remove_guess_word"
                  phx-value-index={index}
                  class="ml-2 text-gray-500 hover:text-gray-700"
                  disabled={@role == :spectator}
                >
                  ×
                </button>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end
