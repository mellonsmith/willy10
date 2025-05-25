defmodule WillyWeb.WordGameLive do
  use WillyWeb, :live_view

  @topic "word_game"

  def mount(_params, _session, socket) do
    # Subscribe to the shared game state topic
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Willy.PubSub, @topic)
    end

    # Get initial state from process
    initial_state = WillyWeb.GameState.get_state()

    {:ok,
     assign(socket,
       main_word: initial_state.main_word,
       guess_words: initial_state.guess_words,
       page_title: "10 gegen Willy"
     )}
  end

  def handle_event("update_main_word", %{"value" => word}, socket) do
    WillyWeb.GameState.update_main_word(word)
    {:noreply, socket}
  end

  def handle_event("add_guess_word", %{"key" => "Enter", "value" => word}, socket) when word != "" do
    WillyWeb.GameState.add_guess_word(word)
    {:noreply, socket}
  end

  def handle_event("add_guess_word", _, socket), do: {:noreply, socket}

  def handle_event("remove_guess_word", %{"index" => index}, socket) do
    WillyWeb.GameState.remove_guess_word(String.to_integer(index))
    {:noreply, socket}
  end

  # Handle state updates broadcast from PubSub
  def handle_info({:state_updated, new_state}, socket) do
    {:noreply,
     assign(socket,
       main_word: new_state.main_word,
       guess_words: new_state.guess_words
     )}
  end

  def render(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto p-6">
      <h1 class="text-2xl font-bold mb-6">Word Game</h1>

      <div class="space-y-6">
        <div>
          <label class="block text-sm font-medium text-gray-700 mb-2">
            10 gegen Willy
          </label>
          <input
            type="text"
            value={@main_word}
            phx-keyup="update_main_word"
            class="block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500"
            placeholder="Enter the main word"
          />
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
            disabled={length(@guess_words) >= 10}
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
              >
                ×
              </button>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end
