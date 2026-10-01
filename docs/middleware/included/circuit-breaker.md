# Circuit Breaker

The optional `:circuit_breaker` request middleware prevents new requests from reaching an adapter after repeated failures.

```ruby
conn = Faraday.new('https://example.com') do |f|
  f.request :circuit_breaker,
            failure_threshold: 5,
            rolling_window: 60,
            cooldown: 30,
            max_probes: 1
  f.adapter :net_http
end
```

The breaker starts closed. After the configured number of classified failures occur in the rolling window it opens and rejects requests with `Faraday::Request::CircuitBreaker::CircuitOpenError`. When the cooldown expires, it moves to half-open and permits only the configured number of concurrent probes. A successful probe closes the breaker; a classified failure opens it again.

State is isolated by `service_key`, which defaults to the request host and can also be a string or a callable receiving the Faraday env. Pass a shared `store` when multiple middleware instances should coordinate for the same keys.

Use `error_statuses`, `exceptions`, or `error_classifier` to define which responses and exceptions count as failures. `clock` and `random` can be injected for deterministic tests.
