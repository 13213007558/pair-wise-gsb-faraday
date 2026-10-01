# Informational Responses (100/103)

Faraday can deliver informational HTTP responses (responses with a `1xx`
status) to your code as they arrive, before the final response is available.
The most common example is [103 Early Hints](https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/103),
which servers use to push `Link` headers (e.g. for preloading assets) while
still preparing the final response.

## Observing informational responses

Pass an `on_information` callback in the request options. It is called, in
arrival order, once per informational response. The callback receives an
immutable `Faraday::Response::Information` snapshot:

```ruby
connection.get('/page') do |request|
  request.options.on_information = proc do |information|
    next unless information.status == 103

    link = information.headers['Link']
    puts "Early hint: #{link}"
  end
end
```

You can also inspect the informational responses after the request completes
through `Faraday::Response#informations`, which returns every snapshot
received for that response in arrival order. `Response#on_information`
additionally replays snapshots already received while the request is still in
flight.

## Guarantees

- Every notification is an **independent, immutable snapshot** of its headers.
  Mutating the headers you passed to the adapter never affects a previously
  delivered notification.
- Informational responses are delivered **in arrival order** and do not change
  the response status. The final response (e.g. `200`) remains authoritative.
- Informational responses **do not** trigger `on_complete` callbacks, JSON
  decoding, or error-raising middleware such as `Faraday::Response::RaiseError`.
- Events that arrive after the response finished, or after the request was
  cancelled/failed, are rejected and never delivered.
- If an `on_information` callback raises, the request is aborted with that
  error and no further events are delivered.

## Adapter support

Emitting informational responses is an opt-in adapter capability. An adapter
that does not declare support will never fabricate `1xx` events, so the
callback is simply not invoked. The bundled Test adapter supports the
capability - see [Test Adapter](/adapters/test-adapter.md) for stubbing
examples. See [Writing custom adapters](/adapters/custom/informational-responses.md)
for how to implement it in a real network adapter.
