defmodule Willy.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {DNSCluster, query: Application.get_env(:willy, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Willy.PubSub},
      # Start the Finch HTTP client for sending emails
      {Finch, name: Willy.Finch},
      # Lobby infrastructure: one GameServer process per lobby code
      {Registry, keys: :unique, name: Willy.GameRegistry},
      {DynamicSupervisor, name: Willy.GameSupervisor, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Willy.Supervisor)
  end
end
