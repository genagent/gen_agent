import Config

# runtime.exs is evaluated at app boot, after the code is loaded and
# before the application starts. This is the right place to read
# environment variables (API keys, model names, backend URLs) and
# wire them into ensembles that depend on external services.
#
# Example: override the system prompt of the "solo" ensemble with an
# env-supplied value, and fail fast if the Anthropic key is missing.
#
# if config_env() != :test do
#   api_key =
#     System.get_env("ANTHROPIC_API_KEY") ||
#       raise """
#       ANTHROPIC_API_KEY is not set. Export it in the shell that
#       starts iex, or switch the relevant ensembles to a different
#       backend (e.g. GenAgent.Backends.Mock for local-only use).
#       """
#
#   # The backend reads the API key from its own config; this just
#   # asserts presence at boot time.
#   _ = api_key
# end
