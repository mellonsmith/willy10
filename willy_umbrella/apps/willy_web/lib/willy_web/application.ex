defmodule WillyWeb.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      WillyWeb.Telemetry,
      # Start the Endpoint (http/https)
      WillyWeb.Endpoint,
      # Start the game state process
      WillyWeb.GameState
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: WillyWeb.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    WillyWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
