defmodule WillyWeb.GameState do
  use GenServer

  @topic "word_game"

  # Client API

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{main_word: "", guess_words: []}, name: __MODULE__)
  end

  def get_state do
    GenServer.call(__MODULE__, :get_state)
  end

  def update_main_word(word) do
    GenServer.cast(__MODULE__, {:update_main_word, word})
  end

  def add_guess_word(word) do
    GenServer.cast(__MODULE__, {:add_guess_word, word})
  end

  def remove_guess_word(index) do
    GenServer.cast(__MODULE__, {:remove_guess_word, index})
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
  def handle_cast({:update_main_word, word}, state) do
    new_state = %{state | main_word: word}
    broadcast_state(new_state)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:add_guess_word, word}, state) do
    if length(state.guess_words) < 10 and word not in state.guess_words do
      new_state = %{state | guess_words: state.guess_words ++ [word]}
      broadcast_state(new_state)
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:remove_guess_word, index}, state) do
    new_state = %{state | guess_words: List.delete_at(state.guess_words, index)}
    broadcast_state(new_state)
    {:noreply, new_state}
  end

  # Helper function to broadcast state updates
  defp broadcast_state(state) do
    Phoenix.PubSub.broadcast(Willy.PubSub, @topic, {:state_updated, state})
  end
end
