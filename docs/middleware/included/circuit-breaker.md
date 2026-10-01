# Circuit Breaker

The optional `CircuitBreaker` middleware keeps repeated failures from continuing to hit an upstream adapter.
It tracks each service independently using a rolling window, opens after a configurable failure threshold,
then allows a limited number of probe requests after a cooldown. Probe failures reopen immediately;
successful probes close the breaker again.

```ruby
conn = Faraday.new('https://example.com') do |f|
  f.request :circuit_breaker,
          service_key: 'example.com',
          failure_threshold: 5,
          rolling_window: 60,
          cooldown: 30,
          max_probe_requests: 1,
          successful_probe_requests: 1
  f.response :raise_error
  f.adapter Faraday.default_adapter
end
```

By default, HTTP `5xx` responses and `Faraday::TimeoutError`, `Faraday::ConnectionFailed`,
`Faraday::NilStatusError`, and `Faraday::ServerError` exceptions count as failures.
Place the middleware before `:raise_error` if raised server errors should be observed as exceptions.

Use `failure_statuses`, `failure_errors`, or `failure_classifier` to customize failure classification.
The classifier receives the request environment and the rescued exception, or `nil` for a completed response:

```ruby
f.request :circuit_breaker,
         failure_classifier: ->(env, error) {
           error.is_a?(Faraday::TimeoutError) || env.status == 503
         }
```

`service_key` can also be a callable. It defaults to the request host, which keeps state isolated by host.
Pass a shared `store` when multiple connections must share one circuit for a service. `clock` and `random`
can be injected for deterministic tests and cooldown jitter:

```ruby
f.request :circuit_breaker,
          service_key: 'billing',
          cooldown: 30,
          cooldown_jitter: 0..5,
          clock: controlled_clock,
          random: controlled_random,
          store: Faraday::Request::CircuitBreaker::Store.new
```

Rejected requests raise `Faraday::CircuitBreakerOpenError` and do not reach the adapter.
