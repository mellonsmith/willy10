defmodule Willy.GameServer do
  @moduledoc """
  One game lobby. Started per lobby code by `Willy.Lobbies` under
  `Willy.GameSupervisor` and registered in `Willy.GameRegistry`, so every
  public function takes the lobby `code` as its first argument.

  All game state lives in memory in this process. State changes are broadcast
  as `{:state_updated, state}` on `topic(code)`; special messages are
  `:lobby_closed` (process is terminating) and `{:player_kicked, player_id}`.
  """

  use GenServer, restart: :temporary

  @min_players 3
  @max_players 7  # Host + 6 players
  @default_timer_duration 60
  @max_guess_words 10
  @max_rounds_per_player 3

  # A lobby shuts itself down after this many minutes without any connected player
  @idle_check_interval :timer.minutes(1)
  @max_empty_checks 10

  # Shared constants

  def topic(code), do: "word_game:" <> code
  def max_guess_words, do: @max_guess_words
  def max_rounds_per_player, do: @max_rounds_per_player

  # Need at least host + @min_players players
  def min_total_players, do: @min_players + 1

  def generate_player_id do
    "player_" <> Base.encode16(:crypto.strong_rand_bytes(8))
  end

  # Client API

  def start_link(code) do
    GenServer.start_link(__MODULE__, code, name: via(code))
  end

  defp via(code), do: {:via, Registry, {Willy.GameRegistry, code}}

  def get_state(code) do
    GenServer.call(via(code), :get_state)
  end

  def join_game(code, player_id, name, role) do
    GenServer.call(via(code), {:join_game, player_id, name, role})
  end

  def leave_game(code, player_id) do
    GenServer.cast(via(code), {:leave_game, player_id})
  end

  def update_main_word(code, player_id, word) do
    GenServer.cast(via(code), {:update_main_word, player_id, word})
  end

  def add_guess_word(code, player_id, word) do
    GenServer.cast(via(code), {:add_guess_word, player_id, word})
  end

  def remove_guess_word(code, player_id, index) do
    GenServer.cast(via(code), {:remove_guess_word, player_id, index})
  end

  def start_game(code, caller_id) do
    GenServer.cast(via(code), {:start_game, caller_id})
  end

  def next_phase(code, caller_id) do
    GenServer.cast(via(code), {:next_phase, caller_id})
  end

  def next_guessing_player(code, caller_id) do
    GenServer.cast(via(code), {:next_guessing_player, caller_id})
  end

  def toggle_found_word(code, caller_id, word_index) do
    GenServer.cast(via(code), {:toggle_found_word, caller_id, word_index})
  end

  def start_timer(code, caller_id) do
    GenServer.cast(via(code), {:start_timer, caller_id})
  end

  def pause_timer(code, caller_id) do
    GenServer.cast(via(code), {:pause_timer, caller_id})
  end

  def reset_timer(code, caller_id) do
    GenServer.cast(via(code), {:reset_timer, caller_id})
  end

  def update_timer_duration(code, caller_id, duration) do
    GenServer.cast(via(code), {:update_timer_duration, caller_id, duration})
  end

  def set_rounds_per_player(code, caller_id, rounds) do
    GenServer.cast(via(code), {:set_rounds_per_player, caller_id, rounds})
  end

  def adjust_points(code, caller_id, player_id, delta) do
    GenServer.cast(via(code), {:adjust_points, caller_id, player_id, delta})
  end

  def reveal_word(code, caller_id, word_index) do
    GenServer.cast(via(code), {:reveal_word, caller_id, word_index})
  end

  def reveal_all_words(code, caller_id) do
    GenServer.cast(via(code), {:reveal_all_words, caller_id})
  end

  def start_new_game(code, caller_id) do
    GenServer.cast(via(code), {:start_new_game, caller_id})
  end

  def end_session(code, caller_id) do
    GenServer.cast(via(code), {:end_session, caller_id})
  end

  def previous_phase(code, caller_id) do
    GenServer.cast(via(code), {:previous_phase, caller_id})
  end

  def previous_guessing_player(code, caller_id) do
    GenServer.cast(via(code), {:previous_guessing_player, caller_id})
  end

  def disconnect_player(code, player_id) do
    GenServer.cast(via(code), {:disconnect_player, player_id})
  end

  def reconnect_player(code, player_id) do
    GenServer.cast(via(code), {:reconnect_player, player_id})
  end

  def remove_player(code, caller_id, player_id) do
    GenServer.cast(via(code), {:remove_player, caller_id, player_id})
  end

  # Server Callbacks

  @impl true
  def init(code) do
    Process.send_after(self(), :idle_check, @idle_check_interval)
    {:ok, initial_state(code)}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call({:join_game, player_id, name, role}, _from, state) do
    name = name |> to_string() |> String.trim()

    cond do
      # Every player needs a real name (rejoining with a known id is exempt)
      name == "" and not Map.has_key?(state.players, player_id) ->
        {:reply, {:error, :invalid_name}, state}

      # If role is host and no host exists, assign as host
      role == :host and is_nil(state.host_id) ->
        new_state = %{state |
          host_id: player_id,
          players: Map.put(state.players, player_id, new_player(name))
        }
        broadcast_state(new_state)
        {:reply, {:ok, :host}, new_state}

      # If role is host but host exists, deny
      role == :host and not is_nil(state.host_id) ->
        {:reply, {:error, :host_exists}, state}

      # If player is already in game
      Map.has_key?(state.players, player_id) ->
        {:reply, {:ok, if(state.host_id == player_id, do: :host, else: :player)}, state}

      # If game is full
      map_size(state.players) >= @max_players ->
        {:reply, {:error, :game_full}, state}

      # Join as player
      true ->
        new_state = %{state | players: Map.put(state.players, player_id, new_player(name))}
        broadcast_state(new_state)
        {:reply, {:ok, :player}, new_state}
    end
  end

  @impl true
  def handle_cast({:leave_game, player_id}, state) do
    if player_id == state.host_id do
      # The host explicitly left: the lobby is over
      close_lobby(state)
    else
      # Mark player as disconnected instead of removing them
      {:noreply, set_connected(state, player_id, false)}
    end
  end

  @impl true
  def handle_cast({:disconnect_player, player_id}, state) do
    {:noreply, set_connected(state, player_id, false)}
  end

  @impl true
  def handle_cast({:reconnect_player, player_id}, state) do
    {:noreply, set_connected(state, player_id, true)}
  end

  @impl true
  def handle_cast({:remove_player, caller_id, player_id}, state) do
    if host?(state, caller_id) and player_id != state.host_id and
       Map.has_key?(state.players, player_id) do
      new_state = kick_player(state, player_id)
      Phoenix.PubSub.broadcast(Willy.PubSub, topic(state.code), {:player_kicked, player_id})
      broadcast_state(new_state)
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:adjust_points, caller_id, player_id, delta}, state) do
    if host?(state, caller_id) and is_integer(delta) and Map.has_key?(state.players, player_id) do
      # Manual corrections deliberately bypass round_points so that stepping
      # back through phases never reverts them
      new_players =
        Map.update!(state.players, player_id, &%{&1 | points: max(0, &1.points + delta)})

      new_state = %{state | players: new_players}

      new_state =
        if new_state.game_status == :finished do
          %{new_state | rankings: calculate_final_rankings(new_players)}
        else
          new_state
        end

      broadcast_state(new_state)
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:set_rounds_per_player, caller_id, rounds}, state) do
    if host?(state, caller_id) and state.game_status == :waiting and
       is_integer(rounds) and rounds in 1..@max_rounds_per_player do
      new_state = %{state | rounds_per_player: rounds}
      broadcast_state(new_state)
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:update_main_word, player_id, word}, state) do
    if host?(state, player_id) and state.current_phase == :choose do
      new_state = %{state | main_word: word}
      broadcast_state(new_state)
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:add_guess_word, player_id, word}, state) do
    if can_edit_guess_words?(state, player_id) and
       length(state.guess_words) < @max_guess_words and
       word not in state.guess_words do
      new_word_index = length(state.guess_words)
      new_state = %{state |
        guess_words: state.guess_words ++ [word],
        word_creators: Map.put(state.word_creators, new_word_index, player_id)
      }
      broadcast_state(new_state)
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:remove_guess_word, player_id, index}, state) do
    if can_edit_guess_words?(state, player_id) do
      new_state = %{state | guess_words: List.delete_at(state.guess_words, index)}
      broadcast_state(new_state)
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:start_game, caller_id}, state) do
    potential_active_players =
      state.players |> Map.keys() |> Enum.reject(&(&1 == state.host_id))

    if host?(state, caller_id) and potential_active_players != [] do
      # One shuffled cycle per configured round; every player is the active
      # player rounds_per_player times
      round_order = build_round_order(potential_active_players, state.rounds_per_player)
      [first_active | _] = round_order

      new_state = %{state |
        players: set_active_player(state.players, first_active),
        game_status: :in_progress,
        current_round: 1,
        round_order: round_order,
        rounds_completed: [first_active],
        current_phase: :choose,
        guessing_order: [],
        current_guessing_player: nil,
        guessing_completed: [],
        found_words: %{},
        revealed_words: MapSet.new(),
        word_guesses: %{},
        word_creators: %{},
        round_points: %{}
      }

      broadcast_state(new_state)
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:start_timer, caller_id}, state) do
    # Starts a stopped timer or resumes a paused one
    if host?(state, caller_id) and state.current_phase == :guessing and
       state.timer_state in [:stopped, :paused] do
      remaining =
        case state.timer_state do
          :paused -> state.timer_remaining
          :stopped -> state.timer_duration
        end

      if remaining > 0 do
        ref = make_ref()
        Process.send_after(self(), {:timer_expired, ref}, remaining * 1000)

        new_state = %{state |
          timer_state: :running,
          timer_started_at: System.system_time(:second),
          timer_remaining: remaining,
          timer_ref: ref
        }
        broadcast_state(new_state)
        {:noreply, new_state}
      else
        {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:pause_timer, caller_id}, state) do
    if host?(state, caller_id) and state.current_phase == :guessing and
       state.timer_state == :running do
      elapsed = System.system_time(:second) - state.timer_started_at
      new_state = %{state |
        timer_state: :paused,
        timer_started_at: nil,
        timer_remaining: max(0, state.timer_remaining - elapsed),
        timer_ref: nil
      }
      broadcast_state(new_state)
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:reset_timer, caller_id}, state) do
    if host?(state, caller_id) and state.current_phase == :guessing do
      new_state = stop_timer(state)
      broadcast_state(new_state)
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:update_timer_duration, caller_id, duration}, state) do
    if host?(state, caller_id) and is_integer(duration) and duration > 0 do
      new_state = %{state | timer_duration: duration}
      new_state = if new_state.timer_state == :stopped, do: %{new_state | timer_remaining: duration}, else: new_state
      broadcast_state(new_state)
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:next_phase, caller_id}, state) do
    if not host?(state, caller_id) or state.game_status != :in_progress do
      {:noreply, state}
    else
      case state.current_phase do
        :choose ->
          # Move to guessing phase
          new_state = enter_guessing_phase(state)
          broadcast_state(new_state)
          {:noreply, new_state}

        :guessing ->
          # Move to revealing phase
          new_state = %{stop_timer(state) |
            current_phase: :revealing,
            revealed_words: MapSet.new()
          }
          broadcast_state(new_state)
          {:noreply, new_state}

        :revealing ->
          # Points are awarded while cards are revealed; move to next round
          new_state = advance_to_next_round(state)
          broadcast_state(new_state)
          {:noreply, new_state}
      end
    end
  end

  @impl true
  def handle_cast({:next_guessing_player, caller_id}, state) do
    if not host?(state, caller_id) or state.current_phase != :guessing do
      {:noreply, state}
    else
      # If we're on the first player, add them to guessing_completed
      guessing_completed = if state.current_guessing_player && state.current_guessing_player not in state.guessing_completed do
        [state.current_guessing_player | state.guessing_completed]
      else
        state.guessing_completed
      end

      remaining_guessers = state.guessing_order -- guessing_completed

      if remaining_guessers == [] do
        # All players have guessed, move to next phase
        new_state = %{stop_timer(state) |
          current_phase: :revealing,
          guessing_completed: guessing_completed
        }
        broadcast_state(new_state)
        {:noreply, new_state}
      else
        [next_guesser | _] = remaining_guessers

        new_state = %{stop_timer(state) |
          current_guessing_player: next_guesser,
          guessing_completed: guessing_completed
        }

        broadcast_state(new_state)
        {:noreply, new_state}
      end
    end
  end

  @impl true
  def handle_cast({:toggle_found_word, caller_id, word_index}, state) do
    # Host or active player mark words for whoever is currently guessing
    guesser = state.current_guessing_player

    if state.current_phase == :guessing and guesser != nil and
       (host?(state, caller_id) or active_player?(state, caller_id)) do
      current_found = Map.get(state.found_words, guesser, [])
      new_found = if word_index in current_found do
        Enum.reject(current_found, &(&1 == word_index))
      else
        [word_index | current_found]
      end

      # Update word_guesses when a word is found
      word_guesses = if word_index in current_found do
        # Remove player from word_guesses if unmarking
        Map.update(state.word_guesses, word_index, [], fn players ->
          Enum.reject(players, &(&1 == guesser))
        end)
      else
        # Add player to word_guesses if marking
        Map.update(state.word_guesses, word_index, [guesser], fn players ->
          [guesser | players]
        end)
      end

      new_state = %{state |
        found_words: Map.put(state.found_words, guesser, new_found),
        word_guesses: word_guesses
      }
      broadcast_state(new_state)
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:reveal_word, caller_id, word_index}, state) do
    if host?(state, caller_id) and state.current_phase == :revealing do
      new_state =
        state
        |> award_finder_points(word_index)
        |> maybe_sync_active_player_points()

      broadcast_state(new_state)
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:reveal_all_words, caller_id}, state) do
    if host?(state, caller_id) and state.current_phase == :revealing do
      new_state =
        state.guess_words
        |> Enum.with_index()
        |> Enum.reduce(state, fn {_word, index}, acc -> award_finder_points(acc, index) end)
        |> maybe_sync_active_player_points()

      broadcast_state(new_state)
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:start_new_game, caller_id}, state) do
    if host?(state, caller_id) do
      # Reset the game state but keep the players, reset their points to 0
      reset_players = Map.new(state.players, fn {id, info} ->
        {id, %{info | points: 0, state: :waiting}}
      end)

      new_state = Map.merge(initial_state(state.code), %{
        players: reset_players,
        host_id: state.host_id,
        timer_duration: state.timer_duration,
        timer_remaining: state.timer_duration,
        rounds_per_player: state.rounds_per_player
      })
      broadcast_state(new_state)
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:end_session, caller_id}, state) do
    if host?(state, caller_id) do
      close_lobby(state)
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:previous_phase, caller_id}, state) do
    if not host?(state, caller_id) or state.game_status != :in_progress do
      {:noreply, state}
    else
      case state.current_phase do
        :guessing ->
          # Go back to choose phase
          new_state = %{stop_timer(state) |
            current_phase: :choose,
            guessing_order: [],
            current_guessing_player: nil,
            guessing_completed: [],
            found_words: %{},
            revealed_words: MapSet.new(),
            word_guesses: %{}
          }
          broadcast_state(new_state)
          {:noreply, new_state}

        :revealing ->
          # Go back to guessing phase - revert points awarded in this round
          reverted_players = Enum.reduce(state.round_points, state.players, fn {player_id, points_awarded}, acc_players ->
            if Map.has_key?(acc_players, player_id) do
              player_info = acc_players[player_id]
              Map.put(acc_players, player_id, %{player_info | points: max(0, player_info.points - points_awarded)})
            else
              acc_players
            end
          end)

          new_state = enter_guessing_phase(%{state | players: reverted_players})
          broadcast_state(new_state)
          {:noreply, new_state}

        _ ->
          {:noreply, state}
      end
    end
  end

  @impl true
  def handle_cast({:previous_guessing_player, caller_id}, state) do
    if not host?(state, caller_id) or state.current_phase != :guessing do
      {:noreply, state}
    else
      # Find the previous player in the guessing order
      current_index = Enum.find_index(state.guessing_order, &(&1 == state.current_guessing_player))

      previous_guesser = if current_index && current_index > 0 do
        Enum.at(state.guessing_order, current_index - 1)
      else
        state.current_guessing_player
      end

      # Remove the current player from guessing_completed if they're in it
      guessing_completed = List.delete(state.guessing_completed, state.current_guessing_player)
      # Also remove the previous player
      guessing_completed = List.delete(guessing_completed, previous_guesser)

      new_state = %{stop_timer(state) |
        current_guessing_player: previous_guesser,
        guessing_completed: guessing_completed
      }

      broadcast_state(new_state)
      {:noreply, new_state}
    end
  end

  @impl true
  def handle_info({:timer_expired, ref}, state) do
    # Ignore stale timers from before a pause/reset/phase change
    if state.timer_state == :running and state.timer_ref == ref do
      new_state = %{state |
        timer_state: :stopped,
        timer_started_at: nil,
        timer_remaining: 0,
        timer_ref: nil
      }
      broadcast_state(new_state)
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:idle_check, state) do
    anyone_connected? = Enum.any?(state.players, fn {_id, info} -> info.connected end)
    empty_checks = if anyone_connected?, do: 0, else: state.empty_checks + 1

    if empty_checks >= @max_empty_checks do
      close_lobby(state)
    else
      Process.send_after(self(), :idle_check, @idle_check_interval)
      {:noreply, %{state | empty_checks: empty_checks}}
    end
  end

  # Helper functions

  defp initial_state(code) do
    %{
      code: code,
      main_word: "",
      guess_words: [],
      host_id: nil,
      players: %{}, # Map of player_id => %{name: ..., state: ..., points: 0, connected: true}
      game_status: :waiting, # :waiting, :in_progress, :finished
      rounds_per_player: 1, # how often every player becomes the active player
      current_round: 0,
      round_order: [],
      rounds_completed: [],
      current_phase: :choose, # :choose, :guessing, :revealing
      guessing_order: [],
      current_guessing_player: nil,
      guessing_completed: [],
      found_words: %{}, # Map of player_id => list of found word indices
      timer_state: :stopped, # :stopped, :running, :paused
      timer_started_at: nil, # when the current running stretch began
      timer_remaining: @default_timer_duration, # seconds left as of timer_started_at (or now, if not running)
      timer_duration: @default_timer_duration,
      timer_ref: nil,
      revealed_words: MapSet.new(), # Set of revealed word indices
      word_guesses: %{}, # Map of word_index => list of player_ids who found it
      word_creators: %{}, # Map of word_index => player_id who created it
      rankings: [], # List of {player_id, points} tuples sorted by points
      round_points: %{}, # Map of player_id => points awarded in current round (for reverting)
      empty_checks: 0 # consecutive idle checks without a connected player
    }
  end

  defp new_player(name) do
    %{name: name, state: :waiting, points: 0, connected: true}
  end

  defp host?(state, player_id) do
    player_id != nil and player_id == state.host_id
  end

  defp active_player?(state, player_id) do
    case Map.get(state.players, player_id) do
      %{state: :active_player} -> true
      _ -> false
    end
  end

  # The active player of the current round (head of rounds_completed)
  defp active_id(%{rounds_completed: [active | _]}), do: active
  defp active_id(_state), do: nil

  defp can_edit_guess_words?(state, player_id) do
    Map.has_key?(state.players, player_id) and
      (host?(state, player_id) or
         (state.game_status == :in_progress and
            state.current_phase == :choose and
            active_player?(state, player_id)))
  end

  defp set_connected(state, player_id, connected) do
    if Map.has_key?(state.players, player_id) do
      new_state = %{state | players: Map.update!(state.players, player_id, &%{&1 | connected: connected})}
      broadcast_state(new_state)
      new_state
    else
      state
    end
  end

  # Set everyone to passive and the given player to active (preserves connected status)
  defp set_active_player(players, active_id) do
    Map.new(players, fn {id, info} ->
      {id, %{info | state: if(id == active_id, do: :active_player, else: :passive_player)}}
    end)
  end

  # One shuffled cycle of all players per round; avoid the same player being
  # active twice in a row across cycle boundaries
  defp build_round_order(player_ids, cycles) do
    Enum.reduce(1..cycles, [], fn _cycle, acc ->
      cycle = Enum.shuffle(player_ids)

      cycle =
        if acc != [] and List.last(acc) == hd(cycle) and length(cycle) > 1 do
          tl(cycle) ++ [hd(cycle)]
        else
          cycle
        end

      acc ++ cycle
    end)
  end

  defp enter_guessing_phase(state) do
    # Everyone in the round rotation except the current active player guesses.
    # round_order may contain each player multiple times (rounds_per_player)
    guessing_players =
      state.round_order |> Enum.uniq() |> Enum.reject(&(&1 == active_id(state))) |> Enum.shuffle()

    base = %{stop_timer(state) |
      guessing_completed: [],
      found_words: %{},
      revealed_words: MapSet.new(),
      word_guesses: %{},
      round_points: %{}
    }

    case guessing_players do
      [] ->
        # Nobody left to guess (e.g. after kicks): skip straight to revealing
        %{base | current_phase: :revealing, guessing_order: [], current_guessing_player: nil}

      [first_guesser | _] ->
        %{base |
          current_phase: :guessing,
          guessing_order: guessing_players,
          current_guessing_player: first_guesser
        }
    end
  end

  defp advance_to_next_round(state) do
    remaining_players = state.round_order -- state.rounds_completed

    if remaining_players == [] do
      # Game is finished - calculate final rankings
      %{state |
        game_status: :finished,
        rankings: calculate_final_rankings(state.players)
      }
    else
      [next_active | _] = remaining_players

      %{stop_timer(state) |
        players: set_active_player(state.players, next_active),
        current_round: state.current_round + 1,
        rounds_completed: [next_active | state.rounds_completed],
        main_word: "",
        guess_words: [],
        current_phase: :choose,
        guessing_order: [],
        current_guessing_player: nil,
        guessing_completed: [],
        found_words: %{},
        revealed_words: MapSet.new(),
        word_guesses: %{},
        word_creators: %{},
        round_points: %{}
      }
    end
  end

  # Remove a player entirely and repair any in-progress round that involved them
  defp kick_player(state, player_id) do
    was_active = state.game_status == :in_progress and active_id(state) == player_id
    was_guessing = state.current_phase == :guessing and state.current_guessing_player == player_id

    state = %{state |
      players: Map.delete(state.players, player_id),
      round_order: Enum.reject(state.round_order, &(&1 == player_id)),
      rounds_completed: Enum.reject(state.rounds_completed, &(&1 == player_id)),
      guessing_order: List.delete(state.guessing_order, player_id),
      guessing_completed: List.delete(state.guessing_completed, player_id),
      found_words: Map.delete(state.found_words, player_id),
      word_guesses: Map.new(state.word_guesses, fn {index, ids} ->
        {index, Enum.reject(ids, &(&1 == player_id))}
      end),
      round_points: Map.delete(state.round_points, player_id)
    }

    cond do
      state.game_status != :in_progress -> state
      was_active -> advance_to_next_round(state)
      was_guessing -> advance_after_guesser_kicked(state)
      true -> state
    end
  end

  defp advance_after_guesser_kicked(state) do
    case state.guessing_order -- state.guessing_completed do
      [] ->
        %{stop_timer(state) | current_phase: :revealing, current_guessing_player: nil}

      [next_guesser | _] ->
        %{stop_timer(state) | current_guessing_player: next_guesser}
    end
  end

  defp stop_timer(state) do
    %{state |
      timer_state: :stopped,
      timer_started_at: nil,
      timer_remaining: state.timer_duration,
      timer_ref: nil
    }
  end

  # Reveal a word and give +1 to every guesser who found it.
  # Idempotent: an already revealed word never awards points again.
  defp award_finder_points(state, word_index) do
    if MapSet.member?(state.revealed_words, word_index) do
      state
    else
      finder_ids = Map.get(state.word_guesses, word_index, [])

      finder_ids
      |> Enum.reduce(state, fn finder_id, acc ->
        if finder_id != acc.host_id and Map.has_key?(acc.players, finder_id) do
          add_points(acc, finder_id, 1)
        else
          acc
        end
      end)
      |> Map.update!(:revealed_words, &MapSet.put(&1, word_index))
    end
  end

  # The active player only scores once every card has been revealed; the
  # guessers get their points per revealed card (in award_finder_points)
  defp maybe_sync_active_player_points(state) do
    if MapSet.size(state.revealed_words) >= length(state.guess_words) do
      sync_active_player_points(state)
    else
      state
    end
  end

  # The active player scores as many points as the best guesser this round
  defp sync_active_player_points(state) do
    case Enum.find(state.players, fn {_id, info} -> info.state == :active_player end) do
      nil ->
        state

      {active_id, _info} ->
        best_guesser_points =
          state.round_points
          |> Enum.reject(fn {id, _points} -> id == active_id end)
          |> Enum.map(fn {_id, points} -> points end)
          |> Enum.max(fn -> 0 end)

        delta = best_guesser_points - Map.get(state.round_points, active_id, 0)
        if delta == 0, do: state, else: add_points(state, active_id, delta)
    end
  end

  defp add_points(state, player_id, points) do
    %{state |
      players: Map.update!(state.players, player_id, &%{&1 | points: &1.points + points}),
      round_points: Map.update(state.round_points, player_id, points, &(&1 + points))
    }
  end

  # Tell every client the lobby is gone, then terminate (Registry entry is
  # removed automatically). restart: :temporary keeps the supervisor from
  # resurrecting an empty lobby under the same code.
  defp close_lobby(state) do
    Phoenix.PubSub.broadcast(Willy.PubSub, topic(state.code), :lobby_closed)
    {:stop, :normal, state}
  end

  # Helper function to broadcast state updates
  defp broadcast_state(state) do
    Phoenix.PubSub.broadcast(Willy.PubSub, topic(state.code), {:state_updated, state})
  end

  # Helper function to calculate final rankings
  defp calculate_final_rankings(players) do
    players
    |> Map.to_list()
    |> Enum.map(fn {id, info} -> {id, info.points} end)
    |> Enum.sort_by(fn {_id, points} -> points end, :desc)
  end
end
