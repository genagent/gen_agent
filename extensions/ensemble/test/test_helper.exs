unless Code.ensure_loaded?(GenAgent.Backends.Mock) do
  # The archive check also runs these tests against the previously published
  # Hex core, which predates the public Mock. Reuse the one root source file
  # until a release containing it is available.
  Code.require_file("../../../lib/gen_agent/backends/mock.ex", __DIR__)
end

ExUnit.start()
