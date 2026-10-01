# Informational responses

Informational responses are `1xx` responses such as `100 Continue` and
`103 Early Hints` that can arrive before the final response. Supporting them is
an optional adapter capability.

## Declare the capability

Tell Faraday your adapter emits informational responses:

```ruby
class FlorpHttp < ::Faraday::Adapter
  self.supports_informational_responses = true
end
```

The base `Faraday::Adapter` defaults to `false`. Do not enable it unless your
adapter actually delivers real `1xx` responses - adapters without the
capability must never fabricate informational events.

## Emit events

For each informational response received from the network, call the private
`informational_response` helper, in arrival order:

```ruby
class FlorpHttp < ::Faraday::Adapter
  self.supports_informational_responses = true

  def call(env)
    super

    # Whenever the underlying client reports a 1xx response:
    informational_response(env, 100, continue_headers)
    informational_response(env, 103, early_hints_headers)

    # ... then save the final response as usual with #save_response.
  end
end
```

The helper validates that the status is in the `100-199` range and hands
listeners an independent, immutable `Faraday::Response::Information` snapshot.
It raises `Faraday::Response::LateInformationError` if called after the
response has already finished or been aborted, so adapters must stop forwarding
`1xx` frames once the final response is in.

## Cancellation and failures

If the request is cancelled or fails before the final response (for example,
after one or more early hints were already delivered), call `abort_response`:

```ruby
rescue FlorpHttp::NetworkError => e
  abort_response(env, e)
  raise
end
```

This releases pending callbacks, puts the response in a terminal aborted state,
and rejects any late informational events or `finish` with the stored error.

## Contract summary

- Deliver `1xx` responses in arrival order, before calling `save_response`.
- Never mutate `env.status` or `env.response_headers` from an informational
  response; the final response remains authoritative.
- Informational responses must not run `on_complete`, JSON decoding or
  error-raising middleware - the framework guarantees this for you.
- Stop emitting after the final response, an abort, or a callback error.
