import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :willy_web, WillyWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "i+gvWQQVWABKNwuzl4wJ1m3ZBYDa1bFOjR5jKOAztq1DLhc8SlgAbM8eYl2Vr+KI",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# In test we don't send emails
# config :willy, Willy.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
# config :swoosh, :api_client, false

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true
