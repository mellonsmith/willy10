defmodule WillyWeb.GameState do
  use GenServer

  @topic "word_game"
  @min_players 3
  @max_players 5

  # Client API

  def start_link(_) do
    initial_state = %{
      main_word: "",
      guess_words: [],
      host_id: nil,
      players: %{}, # Map of player_id to player name
      game_status: :waiting # :waiting, :in_progress, :finished
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
          players: Map.put(state.players, player_id, name)
        }
        broadcast_state(new_state)
        {:reply, {:ok, :host}, new_state}

      # If role is host but host exists, deny
      role == :host and not is_nil(state.host_id) ->
        {:reply, {:error, :host_exists}, state}

      # If game is full
      map_size(state.players) >= @max_players ->
        {:reply, {:error, :game_full}, state}

      # If player is already in game
      Map.has_key?(state.players, player_id) ->
        {:reply, {:ok, if(state.host_id == player_id, do: :host, else: :player)}, state}

      # Join as player
      true ->
        new_state = %{state | players: Map.put(state.players, player_id, name)}
        broadcast_state(new_state)
        {:reply, {:ok, :player}, new_state}
    end
  end

  @impl true
  def handle_cast({:leave_game, player_id}, state) do
    if player_id == state.host_id do
      # If host leaves, reset the game
      new_state = %{
        main_word: "",
        guess_words: [],
        host_id: nil,
        players: %{},
        game_status: :waiting
      }
      broadcast_state(new_state)
      {:noreply, new_state}
    else
      new_state = %{state | players: Map.delete(state.players, player_id)}
      broadcast_state(new_state)
      {:noreply, new_state}
    end
  end

  @impl true
  def handle_cast({:update_main_word, player_id, word}, state) do
    if player_id == state.host_id do
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
       word not in state.guess_words do
      new_state = %{state | guess_words: state.guess_words ++ [word]}
      broadcast_state(new_state)
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:remove_guess_word, player_id, index}, state) do
    if Map.has_key?(state.players, player_id) do
      new_state = %{state | guess_words: List.delete_at(state.guess_words, index)}
      broadcast_state(new_state)
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  # Helper function to broadcast state updates
  defp broadcast_state(state) do
    Phoenix.PubSub.broadcast(Willy.PubSub, @topic, {:state_updated, state})
  end

  # Helper to check if enough players to start
  def can_start?(state) do
    map_size(state.players) >= @min_players
  end
end
