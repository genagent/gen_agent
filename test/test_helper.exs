# Positive assert_receive defaults to 500ms so callback/EXIT assertions
# tolerate CI scheduling latency; refute_receive and explicit timeouts unchanged.
ExUnit.start(assert_receive_timeout: 500)
Code.require_file("support/down_assertions.exs", __DIR__)
Code.require_file("support/polling_assertions.exs", __DIR__)
