defmodule WillyWeb.WordGameLive do
  use WillyWeb, :live_view

  @topic "word_game"
  @host_id "host"

  def mount(_params, _session, socket) do
    # Everyone starts as a spectator
    socket = assign(socket,
      player_id: nil,
      role: :spectator,
      nickname: nil,
      main_word: "",
      guess_words: [],
      players: %{},
      player_state: nil,
      game_status: :waiting,
      host_id: nil,
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
        {:noreply, assign(socket, player_id: player_id, role: :host, nickname: nickname, player_state: :waiting)}
      {:ok, :player} ->
        {:noreply, assign(socket, player_id: player_id, role: :player, nickname: nickname, player_state: :waiting)}
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
    {:noreply, assign(socket, player_id: nil, role: :spectator, nickname: nil, player_state: nil)}
  end

  def handle_event("update_main_word", %{"value" => word}, socket) do
    if socket.assigns.role == :host do
      WillyWeb.GameState.update_main_word(socket.assigns.player_id, word)
    end
    {:noreply, socket}
  end

  def handle_event("add_guess_word", %{"key" => "Enter", "value" => word}, socket) when word != "" do
    if socket.assigns.player_state == :active_player or socket.assigns.role == :host do
      WillyWeb.GameState.add_guess_word(socket.assigns.player_id, word)
    end
    {:noreply, push_event(socket, "reset", %{id: "new-guess-word"})}
  end

  def handle_event("add_guess_word", _, socket), do: {:noreply, socket}

  def handle_event("remove_guess_word", %{"index" => index}, socket) do
    if socket.assigns.player_state == :active_player or socket.assigns.role == :host do
      WillyWeb.GameState.remove_guess_word(socket.assigns.player_id, String.to_integer(index))
    end
    {:noreply, socket}
  end

  def handle_event("start_game", _params, socket) do
    if socket.assigns.role == :host do
      WillyWeb.GameState.start_game()
    end
    {:noreply, socket}
  end

  # Handle state updates broadcast from PubSub
  def handle_info({:state_updated, new_state}, socket) do
    player_state =
      if socket.assigns.player_id && Map.has_key?(new_state.players, socket.assigns.player_id) do
        new_state.players[socket.assigns.player_id].state
      else
        nil
      end
    {:noreply,
     assign(socket,
       main_word: new_state.main_word,
       guess_words: new_state.guess_words,
       players: new_state.players,
       game_status: new_state.game_status,
       host_id: new_state.host_id,
       player_state: player_state
     )}
  end

  # Handle host disconnection
  def handle_info(:host_disconnected, socket) do
    {:noreply, assign(socket,
      player_id: nil,
      role: :spectator,
      nickname: nil,
      player_state: nil,
      main_word: "",
      guess_words: [],
      players: %{},
      game_status: :waiting,
      host_id: nil
     )}
  end

  def terminate(_reason, socket) do
    if connected?(socket) and socket.assigns.player_id do
      WillyWeb.GameState.leave_game(socket.assigns.player_id)
    end
  end

  defp host_exists?(players) do
    Enum.any?(players, fn {id, _info} -> id == @host_id end)
  end
end
