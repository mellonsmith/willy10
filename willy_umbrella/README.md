# Willy 10 - Word Guessing Game

A multiplayer word association game built with Phoenix LiveView where players take turns creating word lists and guessing each other's words.

## Prerequisites

- Erlang/OTP 25+
- Elixir 1.14+
- PostgreSQL 14+
- Node.js 16+ (for asset compilation)

## Quick Start

1. **Clone and navigate to the project:**
   ```bash
   cd willy_umbrella
   ```

2. **Install dependencies:**
   ```bash
   mix deps.get
   ```

3. **Set up the database:**
   ```bash
   mix ecto.create
   mix ecto.migrate
   ```

4. **Start the server:**
   ```bash
   mix phx.server
   ```

5. **Visit the game:**
   - Open [http://localhost:4000/game](http://localhost:4000/game)

## Common Commands

```bash
# Install/update dependencies
mix deps.get              # Download dependencies
mix deps.update --all     # Update all dependencies
mix deps.compile          # Compile dependencies

# Database
mix ecto.create           # Create database
mix ecto.migrate          # Run migrations
mix ecto.reset            # Drop, create, and migrate

# Run the server
mix phx.server            # Start Phoenix server
iex -S mix phx.server     # Start with interactive shell
```

## Docker PostgreSQL (Optional)

If you want to run PostgreSQL in Docker:

```bash
docker run -d \
  --name willy-postgres \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_PASSWORD=postgres \
  -e POSTGRES_DB=willy_dev \
  -p 5432:5432 \
  postgres:14
```

## How to Play

1. **Join the Game:**
   - One player joins as **Host** (manages the game)
   - 3-4 other players join as **Players**

2. **Choose Phase:**
   - The active player enters a main word
   - The active player creates 10 related guess words

3. **Guessing Phase:**
   - Other players take turns guessing the words
   - Each player has 60 seconds per turn
   - Click on words you think are correct

4. **Revealing Phase:**
   - The host reveals all words
   - Points are calculated based on correct guesses

5. **Next Round:**
   - The next player becomes active
   - Repeat until all players have had a turn

6. **Game Over:**
   - Final rankings are displayed
   - Host can start a new game or end the session

## Troubleshooting

**PostgreSQL not running?**
```bash
# Linux
sudo systemctl start postgresql

# macOS
brew services start postgresql

# Docker
docker start willy-postgres
```

**Port 4000 already in use?**
- Change the port in `config/dev.exs` or kill the process using port 4000

**Compilation errors?**
```bash
mix deps.clean --all
mix deps.get
mix deps.compile
```
