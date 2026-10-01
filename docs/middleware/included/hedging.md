# Hedging

The `Hedging` middleware protects reads against a slow replica: when the first
copy of a request does not complete within `threshold` seconds, a duplicate
copy is sent (up to `max_copies` in total). The first response satisfying
`success_policy` is returned to the caller, so the caller always observes
exactly one result.

```ruby
conn = Faraday.new(...) do |f|
  f.request :hedging, threshold: 0.2, max_copies: 2, deadline: 2
  ...
end
```

### Options

* `threshold` (default `0.5`): seconds the first copy may take before a duplicate is launched.
* `max_copies` (default `2`): maximum number of copies, including the original request.
* `deadline` (default `nil`): overall time limit in seconds for the whole hedged request.
  Raises `Faraday::TimeoutError` when exceeded.
* `methods` (default `%i[get head options trace put delete]`): idempotent HTTP methods
  eligible for hedging.
* `success_policy` (default: 2xx success): a callable receiving the response env and
  returning whether the response wins the race.

### Safety

Hedging is only applied to requests that are safe to repeat: the HTTP method must be
idempotent, the request body must be independently replayable by every copy (`nil` or a
`String`; streaming/IO bodies are never hedged), and the request must not stream its
response or run in parallel mode. Requests that do not meet these criteria are sent once,
as if the middleware was not present.

When the underlying adapter responds to `cancel(env)`, losing copies are cancelled.
Otherwise they are left to finish naturally in the background; since every copy runs
against its own duplicated env, their bodies and errors can neither leak into nor
overwrite the winning response.
