# Hedging

The `Hedging` middleware protects reads from a slow replica by racing duplicate
copies of the same request. The first copy is sent immediately; only when no
response satisfying the success policy arrives within `delay` seconds is a
duplicate sent (to the next URL in `targets`, when configured). The first
response satisfying the success policy is returned to the caller, so the
caller always observes exactly one result.

Because hedging repeats a request, it is restricted to safely repeatable
(idempotent) methods - GET, HEAD and OPTIONS by default - and the request
entity must be independently replayable: `nil`, a `String`, or an IO that can
be rewound and materialized. Anything else raises `Faraday::Error`.

```ruby
conn = Faraday.new('http://one.internal') do |f|
  f.request :hedging,
            delay: 0.05,                        # seconds before sending a duplicate
            max_copies: 2,                      # total copies, including the first
            targets: ['http://two.internal'],   # base URLs for copies 2..n
            deadline: 2,                        # overall time limit in seconds
            methods: %i[get head options],      # safely repeatable methods
            success_if: ->(res) { res.status.to_i < 500 }
  ...
end
```

### Behaviour notes

* A response that arrives exactly as the threshold is reached wins the race
  and no duplicate is sent.
* Faraday adapters do not support cancellation, so losing copies are left to
  finish naturally. Each copy runs against its own duplicated env, meaning a
  loser's body, headers or error can never leak into, or overwrite, the
  winning response.
* When every copy fails, a single failure (the first one received) is
  surfaced to the caller.
* When the overall `deadline` expires, a `Faraday::TimeoutError` is raised
  and any copy still in flight is abandoned (but never cancelled).
