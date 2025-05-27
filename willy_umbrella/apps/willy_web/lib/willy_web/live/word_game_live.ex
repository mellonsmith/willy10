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
      current_round: 0,
      current_phase: :choose,
      current_guessing_player: nil,
      found_words: %{},
      timer_state: :stopped,
      timer_start: nil,
      timer_duration: 60,
      time_remaining: 60,
      revealed_words: MapSet.new(),
      word_guesses: %{},
      rankings: [],
      page_title: "10 gegen Willy"
    )

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Willy.PubSub, @topic)
      :timer.send_interval(1000, self(), :tick)
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
    if socket.assigns.role == :host and socket.assigns.current_phase == :guessing do
      WillyWeb.GameState.toggle_found_word(socket.assigns.current_guessing_player, String.to_integer(index))
    end
    {:noreply, socket}
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
       time_remaining: if(new_state.timer_state == :running and new_state.timer_start,
         do: max(0, new_state.timer_duration - (System.system_time(:second) - new_state.timer_start)),
         else: new_state.timer_duration),
       revealed_words: new_state.revealed_words,
       word_guesses: new_state.word_guesses,
       rankings: new_state.rankings || []
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
      host_id: nil,
      current_round: 0,
      current_phase: :choose,
      current_guessing_player: nil
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
