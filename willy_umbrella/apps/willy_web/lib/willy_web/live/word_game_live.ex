defmodule WillyWeb.WordGameLive do
  use WillyWeb, :live_view

  alias Willy.GameServer
  alias Willy.Lobbies

  def mount(%{"code" => raw_code}, _session, socket) do
    code = Lobbies.normalize_code(raw_code)

    if Lobbies.exists?(code) do
      state = GameServer.get_state(code)

      socket =
        socket
        |> assign(
          code: code,
          join_url: url(~p"/g/#{code}"),
          player_id: nil,
          role: :spectator,
          nickname: nil,
          page_title: "Willy 10 · #{code}",
          min_players_total: GameServer.min_total_players(),
          max_guess_words: GameServer.max_guess_words()
        )
        |> assign_game_state(state)

      if connected?(socket) do
        Phoenix.PubSub.subscribe(Willy.PubSub, GameServer.topic(code))
        :timer.send_interval(1000, self(), :tick)
      end

      {:ok, socket}
    else
      socket =
        socket
        |> put_flash(:error, "Lobby #{code} not found. It may have been closed.")
        |> push_navigate(to: ~p"/")

      {:ok, socket}
    end
  end

  # Restore session from localStorage
  def handle_event("restore_session", %{"player_id" => player_id, "nickname" => nickname}, socket) do
    state = GameServer.get_state(socket.assigns.code)

    # Check if this player still exists in the game
    if Map.has_key?(state.players, player_id) do
      player_info = state.players[player_id]
      # Derive the role from server state instead of trusting the client
      role = if player_id == state.host_id, do: :host, else: :player

      # Mark player as reconnected
      GameServer.reconnect_player(socket.assigns.code, player_id)

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

  # Join as player or host. "as" comes from the submit button and is missing
  # when the form is submitted with the Enter key -> default to player.
  def handle_event("join_game", %{"nickname" => nickname} = params, socket) do
    nickname = String.trim(nickname)

    if nickname == "" do
      {:noreply, put_flash(socket, :error, "Please pick a nickname first.")}
    else
      player_id = GameServer.generate_player_id()
      role = parse_role(params["as"])

      case GameServer.join_game(socket.assigns.code, player_id, nickname, role) do
        {:ok, role} ->
          socket = assign(socket, player_id: player_id, role: role, nickname: nickname, player_state: :waiting, show_rejoin: false)
          socket = push_event(socket, "save_session", %{player_id: player_id, role: Atom.to_string(role), nickname: nickname})
          {:noreply, socket}
        {:error, :invalid_name} ->
          {:noreply, put_flash(socket, :error, "Please pick a nickname first.")}
        {:error, :host_exists} ->
          {:noreply, put_flash(socket, :error, "This lobby already has a host. Please join as a player.")}
        {:error, :game_full} ->
          {:noreply, put_flash(socket, :error, "This lobby is full!")}
      end
    end
  end

  def handle_event("join_game", _params, socket) do
    {:noreply, put_flash(socket, :error, "Please pick a nickname first.")}
  end

  # Rejoin an active game
  def handle_event("rejoin_game", %{"player_id" => player_id}, socket) do
    state = GameServer.get_state(socket.assigns.code)

    if Map.has_key?(state.players, player_id) do
      player_info = state.players[player_id]
      role = if player_id == state.host_id, do: :host, else: :player

      # Mark player as reconnected
      GameServer.reconnect_player(socket.assigns.code, player_id)

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
      if socket.assigns.role == :host do
        # The host explicitly leaving closes the whole lobby
        GameServer.leave_game(socket.assigns.code, socket.assigns.player_id)
      else
        GameServer.disconnect_player(socket.assigns.code, socket.assigns.player_id)
      end
    end

    socket = assign(socket, player_id: nil, role: :spectator, nickname: nil, player_state: nil)
    socket = push_event(socket, "clear_session", %{})
    {:noreply, socket}
  end

  # Kick a player from the lobby (host only)
  def handle_event("remove_player", %{"player_id" => player_id}, socket) do
    GameServer.remove_player(socket.assigns.code, socket.assigns.player_id, player_id)
    {:noreply, socket}
  end

  # Manually correct a player's score (host only)
  def handle_event("adjust_points", %{"player_id" => player_id, "delta" => delta}, socket) do
    GameServer.adjust_points(
      socket.assigns.code,
      socket.assigns.player_id,
      player_id,
      String.to_integer(delta)
    )

    {:noreply, socket}
  end

  def handle_event("set_rounds", %{"value" => rounds}, socket) do
    GameServer.set_rounds_per_player(
      socket.assigns.code,
      socket.assigns.player_id,
      String.to_integer(rounds)
    )

    {:noreply, socket}
  end

  def handle_event("update_main_word", %{"value" => word}, socket) do
    GameServer.update_main_word(socket.assigns.code, socket.assigns.player_id, word)
    {:noreply, socket}
  end

  def handle_event("add_guess_word", %{"key" => "Enter", "value" => word}, socket) when word != "" do
    GameServer.add_guess_word(socket.assigns.code, socket.assigns.player_id, word)
    {:noreply, push_event(socket, "reset", %{id: "new-guess-word"})}
  end

  def handle_event("add_guess_word", _, socket), do: {:noreply, socket}

  def handle_event("remove_guess_word", %{"index" => index}, socket) do
    GameServer.remove_guess_word(socket.assigns.code, socket.assigns.player_id, String.to_integer(index))
    {:noreply, socket}
  end

  def handle_event("start_game", _params, socket) do
    GameServer.start_game(socket.assigns.code, socket.assigns.player_id)
    {:noreply, socket}
  end

  def handle_event("next_phase", _params, socket) do
    GameServer.next_phase(socket.assigns.code, socket.assigns.player_id)
    {:noreply, socket}
  end

  def handle_event("next_guessing_player", _params, socket) do
    GameServer.next_guessing_player(socket.assigns.code, socket.assigns.player_id)
    {:noreply, socket}
  end

  def handle_event("toggle_found_word", %{"index" => index}, socket) do
    GameServer.toggle_found_word(socket.assigns.code, socket.assigns.player_id, String.to_integer(index))
    {:noreply, socket}
  end

  def handle_event("update_timer_setting", %{"value" => duration}, socket) do
    GameServer.update_timer_duration(socket.assigns.code, socket.assigns.player_id, String.to_integer(duration))
    {:noreply, socket}
  end

  def handle_event("start_timer", _params, socket) do
    GameServer.start_timer(socket.assigns.code, socket.assigns.player_id)
    {:noreply, socket}
  end

  def handle_event("pause_timer", _params, socket) do
    GameServer.pause_timer(socket.assigns.code, socket.assigns.player_id)
    {:noreply, socket}
  end

  def handle_event("reset_timer", _params, socket) do
    GameServer.reset_timer(socket.assigns.code, socket.assigns.player_id)
    {:noreply, socket}
  end

  def handle_event("reveal_word", %{"index" => index}, socket) do
    GameServer.reveal_word(socket.assigns.code, socket.assigns.player_id, String.to_integer(index))
    {:noreply, socket}
  end

  def handle_event("reveal_all_words", _params, socket) do
    GameServer.reveal_all_words(socket.assigns.code, socket.assigns.player_id)
    {:noreply, socket}
  end

  def handle_event("start_new_game", _params, socket) do
    GameServer.start_new_game(socket.assigns.code, socket.assigns.player_id)
    {:noreply, socket}
  end

  def handle_event("end_session", _params, socket) do
    GameServer.end_session(socket.assigns.code, socket.assigns.player_id)
    {:noreply, socket}
  end

  def handle_event("previous_phase", _params, socket) do
    GameServer.previous_phase(socket.assigns.code, socket.assigns.player_id)
    {:noreply, socket}
  end

  def handle_event("previous_guessing_player", _params, socket) do
    GameServer.previous_guessing_player(socket.assigns.code, socket.assigns.player_id)
    {:noreply, socket}
  end

  # Display-only tick; the server ends the timer authoritatively
  def handle_info(:tick, socket) do
    if socket.assigns.timer_state == :running do
      {:noreply, assign(socket, time_remaining: compute_time_remaining(socket.assigns))}
    else
      {:noreply, socket}
    end
  end

  # Handle state updates broadcast from PubSub
  def handle_info({:state_updated, new_state}, socket) do
    {:noreply, assign_game_state(socket, new_state)}
  end

  # The lobby process is terminating (host left/ended it, or idle timeout)
  def handle_info(:lobby_closed, socket) do
    socket =
      socket
      |> put_flash(:error, "The lobby was closed.")
      |> push_navigate(to: ~p"/")

    {:noreply, socket}
  end

  # A player was kicked by the host; evict them if it is us
  def handle_info({:player_kicked, player_id}, socket) do
    if player_id == socket.assigns.player_id do
      socket =
        socket
        |> push_event("clear_session", %{})
        |> put_flash(:error, "You were removed from the lobby by the host.")
        |> push_navigate(to: ~p"/")

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def terminate(_reason, socket) do
    if connected?(socket) and socket.assigns.player_id do
      GameServer.disconnect_player(socket.assigns.code, socket.assigns.player_id)
    end
  end

  # Helper functions

  defp assign_game_state(socket, state) do
    player_id = socket.assigns[:player_id]

    player_state =
      if player_id && Map.has_key?(state.players, player_id) do
        state.players[player_id].state
      else
        nil
      end

    assign(socket,
      main_word: state.main_word,
      guess_words: state.guess_words,
      players: state.players,
      game_status: state.game_status,
      host_id: state.host_id,
      player_state: player_state,
      current_round: state.current_round,
      total_rounds: length(state.round_order),
      rounds_setting: state.rounds_per_player,
      current_phase: state.current_phase,
      current_guessing_player: state.current_guessing_player,
      found_words: state.found_words,
      timer_state: state.timer_state,
      timer_started_at: state.timer_started_at,
      timer_remaining: state.timer_remaining,
      timer_duration: state.timer_duration,
      timer_setting: state.timer_duration,
      time_remaining: compute_time_remaining(state),
      revealed_words: state.revealed_words,
      word_guesses: state.word_guesses,
      rankings: state.rankings || [],
      show_rejoin: socket.assigns[:role] in [nil, :spectator] and has_disconnected_players?(state.players)
    )
  end

  defp compute_time_remaining(%{timer_state: :running, timer_started_at: started_at, timer_remaining: remaining})
       when is_integer(started_at) do
    max(0, remaining - (System.system_time(:second) - started_at))
  end

  defp compute_time_remaining(%{timer_remaining: remaining}), do: remaining

  defp has_disconnected_players?(players) do
    Enum.any?(players, fn {_id, info} -> not info.connected end)
  end

  defp parse_role("host"), do: :host
  defp parse_role(_), do: :player

  defp text_size_class(word) do
    length = String.length(word || "")
    cond do
      length > 20 -> "text-sm md:text-base"
      length > 15 -> "text-base md:text-lg"
      length > 12 -> "text-lg md:text-xl"
      length > 10 -> "text-xl md:text-2xl"
      true -> "text-2xl md:text-3xl"
    end
  end

  defp main_word_size_class(word) do
    length = String.length(word || "")
    cond do
      length > 20 -> "text-xl md:text-2xl"
      length > 15 -> "text-2xl md:text-3xl"
      length > 12 -> "text-3xl md:text-4xl"
      length > 8 -> "text-4xl md:text-5xl"
      true -> "text-5xl md:text-6xl"
    end
  end
end
