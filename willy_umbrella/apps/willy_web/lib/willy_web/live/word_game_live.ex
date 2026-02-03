defmodule WillyWeb.WordGameLive do
  use WillyWeb, :live_view

  @topic "word_game"

  def mount(_params, _session, socket) do
    # Get game state first to use correct timer duration
    state = WillyWeb.GameState.get_state()
    timer_duration = state.timer_duration

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
      current_round: 0,
      current_phase: :choose,
      current_guessing_player: nil,
      found_words: %{},
      timer_state: :stopped,
      timer_start: nil,
      timer_duration: timer_duration,
      time_remaining: timer_duration,
      timer_setting: timer_duration,
      revealed_words: MapSet.new(),
      word_guesses: %{},
      rankings: [],
      page_title: "Willy 10",
      show_rejoin: false
    )

    socket = if connected?(socket) do
      Phoenix.PubSub.subscribe(Willy.PubSub, @topic)
      :timer.send_interval(1000, self(), :tick)

      # Check if there are any players to rejoin
      show_rejoin = map_size(state.players) > 0
      assign(socket, show_rejoin: show_rejoin)
    else
      socket
    end

    {:ok, socket}
  end

  # Restore session from localStorage
  def handle_event("restore_session", %{"player_id" => player_id, "role" => role_str, "nickname" => nickname}, socket) do
    state = WillyWeb.GameState.get_state()

    # Check if this player still exists in the game
    if Map.has_key?(state.players, player_id) do
      player_info = state.players[player_id]
      role = String.to_atom(role_str)

      # Mark player as reconnected
      WillyWeb.GameState.reconnect_player(player_id)

      socket = assign(socket,
        player_id: player_id,
        role: role,
        nickname: nickname,
        player_state: player_info.state,
        show_rejoin: false
      )

      {:noreply, socket}
    else
      # Player no longer exists, clear their session
      {:noreply, push_event(socket, "clear_session", %{})}
    end
  end

  # Join as player or host
  def handle_event("join_game", %{"nickname" => nickname, "as" => as}, socket) do
    player_id = "player_" <> :crypto.strong_rand_bytes(8) |> Base.encode16()
    role = String.to_atom(as)

    case WillyWeb.GameState.join_game(player_id, nickname, role) do
      {:ok, :host} ->
        socket = assign(socket, player_id: player_id, role: :host, nickname: nickname, player_state: :waiting, show_rejoin: false)
        socket = push_event(socket, "save_session", %{player_id: player_id, role: "host", nickname: nickname})
        {:noreply, socket}
      {:ok, :player} ->
        socket = assign(socket, player_id: player_id, role: :player, nickname: nickname, player_state: :waiting, show_rejoin: false)
        socket = push_event(socket, "save_session", %{player_id: player_id, role: "player", nickname: nickname})
        {:noreply, socket}
      {:error, :host_exists} ->
        {:noreply, put_flash(socket, :error, "A host already exists. Please join as a player.")}
      {:error, :game_full} ->
        {:noreply, put_flash(socket, :error, "Game is full!")}
    end
  end

  # Rejoin an active game
  def handle_event("rejoin_game", %{"player_id" => player_id}, socket) do
    state = WillyWeb.GameState.get_state()

    if Map.has_key?(state.players, player_id) do
      player_info = state.players[player_id]
      role = if player_id == state.host_id, do: :host, else: :player

      # Mark player as reconnected
      WillyWeb.GameState.reconnect_player(player_id)

      socket = assign(socket,
        player_id: player_id,
        role: role,
        nickname: player_info.name,
        player_state: player_info.state,
        show_rejoin: false
      )

      socket = push_event(socket, "save_session", %{player_id: player_id, role: Atom.to_string(role), nickname: player_info.name})

      {:noreply, socket}
    else
      {:noreply, put_flash(socket, :error, "Could not rejoin game. Player not found.")}
    end
  end

  # Leave game, become spectator (disconnect)
  def handle_event("leave_game", _params, socket) do
    if socket.assigns.player_id do
      WillyWeb.GameState.disconnect_player(socket.assigns.player_id)
    end
    socket = assign(socket, player_id: nil, role: :spectator, nickname: nil, player_state: nil, show_rejoin: true)
    socket = push_event(socket, "clear_session", %{})
    {:noreply, socket}
  end

  # Remove a player completely (host only)
  def handle_event("remove_player", %{"player_id" => player_id}, socket) do
    socket = if socket.assigns.role == :host do
      WillyWeb.GameState.remove_player(player_id)
      # If removing self, clear session
      if player_id == socket.assigns.player_id do
        push_event(socket, "clear_session", %{})
      else
        socket
      end
    else
      socket
    end
    {:noreply, socket}
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

  def handle_event("next_phase", _params, socket) do
    if socket.assigns.role == :host do
      WillyWeb.GameState.next_phase()
    end
    {:noreply, socket}
  end

  def handle_event("next_guessing_player", _params, socket) do
    if socket.assigns.role == :host do
      WillyWeb.GameState.next_guessing_player()
    end
    {:noreply, socket}
  end

  def handle_event("toggle_found_word", %{"index" => index}, socket) do
    if (socket.assigns.role == :host or socket.assigns.player_state == :active_player) and socket.assigns.current_phase == :guessing do
      WillyWeb.GameState.toggle_found_word(socket.assigns.current_guessing_player, String.to_integer(index))
    end
    {:noreply, socket}
  end

  def handle_event("update_timer_setting", %{"value" => duration}, socket) do
    if socket.assigns.role == :host do
      duration_int = String.to_integer(duration)
      WillyWeb.GameState.update_timer_duration(duration_int)
      {:noreply, assign(socket, timer_setting: duration_int, timer_duration: duration_int, time_remaining: duration_int)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("start_timer", _params, socket) do
    if socket.assigns.role == :host do
      WillyWeb.GameState.start_timer()
    end
    {:noreply, socket}
  end

  def handle_event("skip_timer", _params, socket) do
    if socket.assigns.role == :host do
      WillyWeb.GameState.skip_timer()
    end
    {:noreply, socket}
  end

  def handle_event("reset_timer", _params, socket) do
    if socket.assigns.role == :host do
      WillyWeb.GameState.reset_timer()
    end
    {:noreply, socket}
  end

  def handle_event("reveal_word", %{"index" => index}, socket) do
    if socket.assigns.role == :host do
      WillyWeb.GameState.reveal_word(String.to_integer(index))
    end
    {:noreply, socket}
  end

  def handle_event("reveal_all_words", _params, socket) do
    if socket.assigns.role == :host do
      WillyWeb.GameState.reveal_all_words()
    end
    {:noreply, socket}
  end

  def handle_event("start_new_game", _params, socket) do
    if socket.assigns.role == :host do
      WillyWeb.GameState.start_new_game()
    end
    {:noreply, socket}
  end

  def handle_event("end_session", _params, socket) do
    if socket.assigns.role == :host do
      WillyWeb.GameState.end_session()
    end
    {:noreply, socket}
  end

  def handle_event("previous_phase", _params, socket) do
    if socket.assigns.role == :host do
      WillyWeb.GameState.previous_phase()
    end
    {:noreply, socket}
  end

  def handle_event("previous_guessing_player", _params, socket) do
    if socket.assigns.role == :host do
      WillyWeb.GameState.previous_guessing_player()
    end
    {:noreply, socket}
  end

  def handle_info(:tick, socket) do
    if socket.assigns.timer_state == :running and socket.assigns.timer_start do
      elapsed = System.system_time(:second) - socket.assigns.timer_start
      time_remaining = max(0, socket.assigns.timer_duration - elapsed)

      if time_remaining == 0 do
        WillyWeb.GameState.skip_timer()
      end

      {:noreply, assign(socket, time_remaining: time_remaining)}
    else
      {:noreply, socket}
    end
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
       player_state: player_state,
       current_round: new_state.current_round,
       current_phase: new_state.current_phase,
       current_guessing_player: new_state.current_guessing_player,
       found_words: new_state.found_words,
       timer_state: new_state.timer_state,
       timer_start: new_state.timer_start,
       timer_duration: new_state.timer_duration,
       timer_setting: new_state.timer_duration,
       time_remaining: if(new_state.timer_state == :running and new_state.timer_start,
         do: max(0, new_state.timer_duration - (System.system_time(:second) - new_state.timer_start)),
         else: new_state.timer_duration),
       revealed_words: new_state.revealed_words,
       word_guesses: new_state.word_guesses,
       rankings: new_state.rankings || [],
       show_rejoin: socket.assigns.role == :spectator and map_size(new_state.players) > 0
     )}
  end

  # Handle host disconnection
  def handle_info(:host_disconnected, socket) do
    socket = push_event(socket, "clear_session", %{})
    {:noreply, assign(socket,
      player_id: nil,
      role: :spectator,
      nickname: nil,
      player_state: nil,
      main_word: "",
      guess_words: [],
      players: %{},
      game_status: :waiting,
      host_id: nil,
      current_round: 0,
      current_phase: :choose,
      current_guessing_player: nil,
      show_rejoin: false
     )}
  end

  def terminate(_reason, socket) do
    if connected?(socket) and socket.assigns.player_id do
      WillyWeb.GameState.disconnect_player(socket.assigns.player_id)
    end
  end

end
