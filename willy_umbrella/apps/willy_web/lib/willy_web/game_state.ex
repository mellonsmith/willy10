defmodule WillyWeb.GameState do
  use GenServer

  @topic "word_game"
  @min_players 3
  @max_players 7  # Host + 6 players
  @timer_duration 60

  # Client API

  def start_link(_) do
    initial_state = %{
      main_word: "",
      guess_words: [],
      host_id: nil,
      players: %{}, # Map of player_id => %{name: ..., state: ..., points: 0, connected: true}
      game_status: :waiting, # :waiting, :in_progress, :finished
      current_round: 0,
      round_order: [],
      rounds_completed: [],
      current_phase: :choose, # :choose, :guessing, :revealing
      guessing_order: [],
      current_guessing_player: nil,
      guessing_completed: [],
      found_words: %{}, # Map of player_id => list of found word indices
      timer_state: :stopped, # :stopped, :running
      timer_start: nil,
      timer_duration: @timer_duration,
      revealed_words: MapSet.new(), # Set of revealed word indices
      word_guesses: %{}, # Map of word_index => list of player_ids who found it
      word_creators: %{}, # Map of word_index => player_id who created it
      rankings: [], # List of {player_id, points} tuples sorted by points
      round_points: %{} # Map of player_id => points awarded in current round (for reverting)
    }
    GenServer.start_link(__MODULE__, initial_state, name: __MODULE__)
  end

  def get_state do
    GenServer.call(__MODULE__, :get_state)
  end

  def join_game(player_id, name, role) do
    GenServer.call(__MODULE__, {:join_game, player_id, name, role})
  end

  def leave_game(player_id) do
    GenServer.cast(__MODULE__, {:leave_game, player_id})
  end

  def update_main_word(player_id, word) do
    GenServer.cast(__MODULE__, {:update_main_word, player_id, word})
  end

  def add_guess_word(player_id, word) do
    GenServer.cast(__MODULE__, {:add_guess_word, player_id, word})
  end

  def remove_guess_word(player_id, index) do
    GenServer.cast(__MODULE__, {:remove_guess_word, player_id, index})
  end

  def start_game do
    GenServer.cast(__MODULE__, :start_game)
  end

  def next_phase do
    GenServer.cast(__MODULE__, :next_phase)
  end

  def next_guessing_player do
    GenServer.cast(__MODULE__, :next_guessing_player)
  end

  def toggle_found_word(player_id, word_index) do
    GenServer.cast(__MODULE__, {:toggle_found_word, player_id, word_index})
  end

  def start_timer do
    GenServer.cast(__MODULE__, :start_timer)
  end

  def skip_timer do
    GenServer.cast(__MODULE__, :skip_timer)
  end

  def reset_timer do
    GenServer.cast(__MODULE__, :reset_timer)
  end

  def update_timer_duration(duration) do
    GenServer.cast(__MODULE__, {:update_timer_duration, duration})
  end

  def reveal_word(word_index) do
    GenServer.cast(__MODULE__, {:reveal_word, word_index})
  end

  def reveal_all_words do
    GenServer.cast(__MODULE__, :reveal_all_words)
  end

  def start_new_game do
    GenServer.cast(__MODULE__, :start_new_game)
  end

  def end_session do
    GenServer.cast(__MODULE__, :end_session)
  end

  def previous_phase do
    GenServer.cast(__MODULE__, :previous_phase)
  end

  def previous_guessing_player do
    GenServer.cast(__MODULE__, :previous_guessing_player)
  end

  def disconnect_player(player_id) do
    GenServer.cast(__MODULE__, {:disconnect_player, player_id})
  end

  def reconnect_player(player_id) do
    GenServer.cast(__MODULE__, {:reconnect_player, player_id})
  end

  def remove_player(player_id) do
    GenServer.cast(__MODULE__, {:remove_player, player_id})
  end

  # Server Callbacks

  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call({:join_game, player_id, name, role}, _from, state) do
    cond do
      # If role is host and no host exists, assign as host
      role == :host and is_nil(state.host_id) ->
        new_state = %{state |
          host_id: player_id,
          players: Map.put(state.players, player_id, %{name: name, state: :waiting, points: 0, connected: true})
        }
        broadcast_state(new_state)
        {:reply, {:ok, :host}, new_state}

      # If role is host but host exists, deny
      role == :host and not is_nil(state.host_id) ->
        {:reply, {:error, :host_exists}, state}

      # If game is full (counting only connected or all players)
      map_size(state.players) >= @max_players ->
        {:reply, {:error, :game_full}, state}

      # If player is already in game
      Map.has_key?(state.players, player_id) ->
        {:reply, {:ok, if(state.host_id == player_id, do: :host, else: :player)}, state}

      # Join as player
      true ->
        new_state = %{state | players: Map.put(state.players, player_id, %{name: name, state: :waiting, points: 0, connected: true})}
        broadcast_state(new_state)
        {:reply, {:ok, :player}, new_state}
    end
  end

  @impl true
  def handle_cast({:leave_game, player_id}, state) do
    if player_id == state.host_id do
      # If host leaves, disconnect all players and reset the game
      new_state = %{
        main_word: "",
        guess_words: [],
        host_id: nil,
        players: %{},
        game_status: :waiting,
        current_round: 0,
        round_order: [],
        rounds_completed: [],
        current_phase: :choose,
        guessing_order: [],
        current_guessing_player: nil,
        guessing_completed: [],
        found_words: %{},
        timer_state: :stopped,
        timer_start: nil,
        timer_duration: @timer_duration,
        revealed_words: MapSet.new(),
        word_guesses: %{},
        word_creators: %{},
        rankings: [],
        round_points: %{}
      }
      broadcast_state(new_state)
      # Broadcast a special message to disconnect all players
      Phoenix.PubSub.broadcast(Willy.PubSub, @topic, :host_disconnected)
      {:noreply, new_state}
    else
      # Mark player as disconnected instead of removing them
      if Map.has_key?(state.players, player_id) do
        player_info = state.players[player_id]
        updated_player = %{player_info | connected: false}
        new_state = %{state | players: Map.put(state.players, player_id, updated_player)}
        broadcast_state(new_state)
        {:noreply, new_state}
      else
        {:noreply, state}
      end
    end
  end

  @impl true
  def handle_cast({:disconnect_player, player_id}, state) do
    if Map.has_key?(state.players, player_id) do
      player_info = state.players[player_id]
      updated_player = %{player_info | connected: false}
      new_state = %{state | players: Map.put(state.players, player_id, updated_player)}
      broadcast_state(new_state)
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:reconnect_player, player_id}, state) do
    if Map.has_key?(state.players, player_id) do
      player_info = state.players[player_id]
      updated_player = %{player_info | connected: true}
      new_state = %{state | players: Map.put(state.players, player_id, updated_player)}
      broadcast_state(new_state)
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:remove_player, player_id}, state) do
    # Only host can remove players
    new_state = %{state | players: Map.delete(state.players, player_id)}
    broadcast_state(new_state)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:update_main_word, player_id, word}, state) do
    if player_id == state.host_id and state.current_phase == :choose do
      new_state = %{state | main_word: word}
      broadcast_state(new_state)
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:add_guess_word, player_id, word}, state) do
    if Map.has_key?(state.players, player_id) and
       length(state.guess_words) < 10 and
       word not in state.guess_words and
       (player_id == state.host_id or
        (state.game_status == :in_progress and
         state.current_phase == :choose and
         Map.get(state.players, player_id).state == :active_player)) do
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
    if Map.has_key?(state.players, player_id) and
       (player_id == state.host_id or
        (state.game_status == :in_progress and
         state.current_phase == :choose and
         Map.get(state.players, player_id).state == :active_player)) do
      new_state = %{state | guess_words: List.delete_at(state.guess_words, index)}
      broadcast_state(new_state)
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast(:start_game, state) do
    player_ids = Map.keys(state.players)
    if player_ids == [] do
      {:noreply, state}
    else
      # Filter out the host from potential active players
      potential_active_players = Enum.reject(player_ids, &(&1 == state.host_id))

      if potential_active_players == [] do
        {:noreply, state}
      else
        # Shuffle the order of players for rounds
        round_order = Enum.shuffle(potential_active_players)
        [first_active | _] = round_order

        # Set all players to passive
        new_players = Map.new(state.players, fn {id, info} ->
          {id, %{info | state: :passive_player}}
        end)

        # Set first player as active (preserve connected status)
        new_players = Map.put(new_players, first_active, %{new_players[first_active] | state: :active_player})

        new_state = %{state |
          players: new_players,
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
      end
    end
  end

  @impl true
  def handle_cast(:start_timer, state) do
    if state.current_phase == :guessing and state.timer_state == :stopped do
      new_state = %{state |
        timer_state: :running,
        timer_start: System.system_time(:second)
      }
      broadcast_state(new_state)
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast(:skip_timer, state) do
    if state.current_phase == :guessing and state.timer_state == :running do
      new_state = %{state | timer_state: :stopped}
      broadcast_state(new_state)
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast(:reset_timer, state) do
    if state.current_phase == :guessing do
      new_state = %{state |
        timer_state: :stopped,
        timer_start: nil
      }
      broadcast_state(new_state)
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:update_timer_duration, duration}, state) do
    new_state = %{state | timer_duration: duration}
    broadcast_state(new_state)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:next_phase, state) do
    if state.game_status != :in_progress do
      {:noreply, state}
    else
      case state.current_phase do
        :choose ->
          # Move to guessing phase
          # Get all players except host and active player
          guessing_players = state.round_order -- [state.host_id, hd(state.rounds_completed)]
          # Randomize the order of guessers
          randomized_guessing_players = Enum.shuffle(guessing_players)
          [first_guesser | _] = randomized_guessing_players

          new_state = %{state |
            current_phase: :guessing,
            guessing_order: randomized_guessing_players,
            current_guessing_player: first_guesser,
            guessing_completed: [],
            found_words: %{}, # Reset found words for new guessing phase
            timer_state: :stopped,
            timer_start: nil,
            revealed_words: MapSet.new(),
            word_guesses: %{},
            round_points: %{} # Reset round points tracking
          }
          broadcast_state(new_state)
          {:noreply, new_state}

        :guessing ->
          # Move to revealing phase
          new_state = %{state |
            current_phase: :revealing,
            revealed_words: MapSet.new()
          }
          broadcast_state(new_state)
          {:noreply, new_state}

        :revealing ->
          # Points are now awarded immediately when cards are revealed
          # Move to next round
          remaining_players = state.round_order -- state.rounds_completed
          new_players = state.players

          if remaining_players == [] do
            # Game is finished - calculate final rankings
            rankings = calculate_final_rankings(new_players)
            new_state = %{state |
              game_status: :finished,
              players: new_players,
              rankings: rankings
            }
            broadcast_state(new_state)
            {:noreply, new_state}
          else
            [next_active | _] = remaining_players

            # Set all players to passive
            new_players = Map.new(new_players, fn {id, info} ->
              {id, %{info | state: :passive_player}}
            end)

            # Set next player as active (preserve connected status)
            new_players = Map.put(new_players, next_active, %{new_players[next_active] | state: :active_player})

            new_state = %{state |
              players: new_players,
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

            broadcast_state(new_state)
            {:noreply, new_state}
          end
      end
    end
  end

  @impl true
  def handle_cast(:next_guessing_player, state) do
    if state.current_phase != :guessing do
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
        new_state = %{state |
          current_phase: :revealing,
          guessing_completed: guessing_completed
        }
        broadcast_state(new_state)
        {:noreply, new_state}
      else
        [next_guesser | _] = remaining_guessers

        new_state = %{state |
          current_guessing_player: next_guesser,
          guessing_completed: guessing_completed,
          timer_state: :stopped,
          timer_start: nil
        }

        broadcast_state(new_state)
        {:noreply, new_state}
      end
    end
  end

  @impl true
  def handle_cast({:toggle_found_word, player_id, word_index}, state) do
    if state.current_phase == :guessing and player_id == state.current_guessing_player do
      current_found = Map.get(state.found_words, player_id, [])
      new_found = if word_index in current_found do
        Enum.reject(current_found, &(&1 == word_index))
      else
        [word_index | current_found]
      end

      # Update word_guesses when a word is found
      word_guesses = if word_index in current_found do
        # Remove player from word_guesses if unmarking
        Map.update(state.word_guesses, word_index, [], fn players ->
          Enum.reject(players, &(&1 == player_id))
        end)
      else
        # Add player to word_guesses if marking
        Map.update(state.word_guesses, word_index, [player_id], fn players ->
          [player_id | players]
        end)
      end

      new_state = %{state |
        found_words: Map.put(state.found_words, player_id, new_found),
        word_guesses: word_guesses
      }
      broadcast_state(new_state)
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:reveal_word, word_index}, state) do
    if state.current_phase == :revealing and state.host_id do
      # Award points immediately for this revealed word
      finder_ids = Map.get(state.word_guesses, word_index, [])

      # Update points for players who found this word and track round points
      {updated_players, updated_round_points} = Enum.reduce(finder_ids, {state.players, state.round_points}, fn finder_id, {acc_players, acc_round_points} ->
        if finder_id != state.host_id and Map.has_key?(acc_players, finder_id) do
          player_info = acc_players[finder_id]
          new_players = Map.put(acc_players, finder_id, %{player_info | points: player_info.points + 1})
          new_round_points = Map.update(acc_round_points, finder_id, 1, &(&1 + 1))
          {new_players, new_round_points}
        else
          {acc_players, acc_round_points}
        end
      end)

      # Find active player and award them points if anyone found this word
      {active_player_id, _} = Enum.find(state.players, fn {_id, info} -> info.state == :active_player end) || {nil, nil}

      {updated_players, updated_round_points} = if active_player_id && !Enum.empty?(finder_ids) do
        player_info = updated_players[active_player_id]
        new_players = Map.put(updated_players, active_player_id, %{player_info | points: player_info.points + 1})
        new_round_points = Map.update(updated_round_points, active_player_id, 1, &(&1 + 1))
        {new_players, new_round_points}
      else
        {updated_players, updated_round_points}
      end

      new_state = %{state |
        revealed_words: MapSet.put(state.revealed_words, word_index),
        players: updated_players,
        round_points: updated_round_points
      }
      broadcast_state(new_state)
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast(:reveal_all_words, state) do
    if state.current_phase == :revealing and state.host_id do
      # Award points for all revealed words at once
      word_indices = 0..(length(state.guess_words) - 1)

      # Calculate points for all words and track round points
      {updated_players, updated_round_points} = Enum.reduce(word_indices, {state.players, state.round_points}, fn word_index, {acc_players, acc_round_points} ->
        finder_ids = Map.get(state.word_guesses, word_index, [])

        # Award points to each finder
        Enum.reduce(finder_ids, {acc_players, acc_round_points}, fn finder_id, {inner_players, inner_round_points} ->
          if finder_id != state.host_id and Map.has_key?(inner_players, finder_id) do
            player_info = inner_players[finder_id]
            new_players = Map.put(inner_players, finder_id, %{player_info | points: player_info.points + 1})
            new_round_points = Map.update(inner_round_points, finder_id, 1, &(&1 + 1))
            {new_players, new_round_points}
          else
            {inner_players, inner_round_points}
          end
        end)
      end)

      # Award points to active player for each word that was found by someone
      {active_player_id, _} = Enum.find(state.players, fn {_id, info} -> info.state == :active_player end) || {nil, nil}

      {updated_players, updated_round_points} = if active_player_id do
        active_points = Enum.count(word_indices, fn word_index ->
          finder_ids = Map.get(state.word_guesses, word_index, [])
          !Enum.empty?(finder_ids)
        end)

        if active_points > 0 do
          player_info = updated_players[active_player_id]
          new_players = Map.put(updated_players, active_player_id, %{player_info | points: player_info.points + active_points})
          new_round_points = Map.update(updated_round_points, active_player_id, active_points, &(&1 + active_points))
          {new_players, new_round_points}
        else
          {updated_players, updated_round_points}
        end
      else
        {updated_players, updated_round_points}
      end

      new_state = %{state |
        revealed_words: MapSet.new(word_indices),
        players: updated_players,
        round_points: updated_round_points
      }
      broadcast_state(new_state)
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast(:start_new_game, state) do
    # Reset the game state but keep the players, reset their points to 0
    reset_players = Map.new(state.players, fn {id, info} ->
      {id, %{info | points: 0, state: :waiting}}
    end)

    new_state = %{state |
      main_word: "",
      guess_words: [],
      players: reset_players,
      game_status: :waiting,
      current_round: 0,
      round_order: [],
      rounds_completed: [],
      current_phase: :choose,
      guessing_order: [],
      current_guessing_player: nil,
      guessing_completed: [],
      found_words: %{},
      timer_state: :stopped,
      timer_start: nil,
      revealed_words: MapSet.new(),
      word_guesses: %{},
      word_creators: %{},
      rankings: [],
      round_points: %{}
    }
    broadcast_state(new_state)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:end_session, _state) do
    initial_state = %{
      main_word: "",
      guess_words: [],
      host_id: nil,
      players: %{},
      game_status: :waiting,
      current_round: 0,
      round_order: [],
      rounds_completed: [],
      current_phase: :choose,
      guessing_order: [],
      current_guessing_player: nil,
      guessing_completed: [],
      found_words: %{},
      timer_state: :stopped,
      timer_start: nil,
      timer_duration: @timer_duration,
      revealed_words: MapSet.new(),
      word_guesses: %{},
      word_creators: %{},
      rankings: [],
      round_points: %{}
    }

    broadcast_state(initial_state)
    Phoenix.PubSub.broadcast(Willy.PubSub, @topic, :host_disconnected)
    {:noreply, initial_state}
  end

  def handle_cast(:previous_phase, state) do
    if state.game_status != :in_progress do
      {:noreply, state}
    else
      case state.current_phase do
        :guessing ->
          # Go back to choose phase
          new_state = %{state |
            current_phase: :choose,
            guessing_order: [],
            current_guessing_player: nil,
            guessing_completed: [],
            found_words: %{},
            timer_state: :stopped,
            timer_start: nil,
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

          # Reset to first guesser
          guessing_players = state.round_order -- [state.host_id, hd(state.rounds_completed)]
          randomized_guessing_players = Enum.shuffle(guessing_players)
          [first_guesser | _] = randomized_guessing_players

          new_state = %{state |
            current_phase: :guessing,
            guessing_order: randomized_guessing_players,
            current_guessing_player: first_guesser,
            guessing_completed: [],
            found_words: %{},
            timer_state: :stopped,
            timer_start: nil,
            revealed_words: MapSet.new(),
            word_guesses: %{},
            players: reverted_players,
            round_points: %{}
          }
          broadcast_state(new_state)
          {:noreply, new_state}

        _ ->
          {:noreply, state}
      end
    end
  end

  def handle_cast(:previous_guessing_player, state) do
    if state.current_phase != :guessing do
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

      new_state = %{state |
        current_guessing_player: previous_guesser,
        guessing_completed: guessing_completed,
        timer_state: :stopped,
        timer_start: nil
      }

      broadcast_state(new_state)
      {:noreply, new_state}
    end
  end

  # Helper functions
  # Helper function to broadcast state updates
  defp broadcast_state(state) do
    Phoenix.PubSub.broadcast(Willy.PubSub, @topic, {:state_updated, state})
  end

  # Helper to check if enough players to start
  # Need at least host + 3 players = 4 total
  def can_start?(state) do
    map_size(state.players) >= (@min_players + 1)
  end

  # Helper function to calculate final rankings
  defp calculate_final_rankings(players) do
    players
    |> Map.to_list()
    |> Enum.map(fn {id, info} -> {id, info.points} end)
    |> Enum.sort_by(fn {_id, points} -> points end, :desc)
  end
end
