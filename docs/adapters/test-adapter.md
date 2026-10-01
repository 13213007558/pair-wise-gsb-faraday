# Test Adapter

The built-in Faraday Test adapter lets you define stubbed HTTP requests. This can
be used to mock out network services in an application's unit tests.

The easiest way to do this is to create the stubbed requests when initializing
a `Faraday::Connection`. Stubbing a request by path yields a block with a
`Faraday::Env` object. The stub block expects an Array return value with three
values: an Integer HTTP status code, a Hash of key/value headers, and a
response body.

```ruby
conn = Faraday.new do |builder|
  builder.adapter :test do |stub|
    # block returns an array with 3 items:
    # - Integer response status
    # - Hash HTTP headers
    # - String response body
    stub.get('/ebi') do |env|
      [
        200,
        { 'Content-Type': 'text/plain', },
        'shrimp'
      ]
    end

    # test exceptions too
    stub.get('/boom') do
      raise Faraday::ConnectionFailed
    end
  end
end
```

You can define the stubbed requests outside of the test adapter block:

```ruby
stubs = Faraday::Adapter::Test::Stubs.new do |stub|
  stub.get('/tamago') { |env| [200, {}, 'egg'] }
end
```

This Stubs instance can be passed to a new Connection:

```ruby
conn = Faraday.new do |builder|
  builder.adapter :test, stubs do |stub|
    stub.get('/ebi') { |env| [ 200, {}, 'shrimp' ]}
  end
end
```

It's also possible to stub additional requests after the connection has been
initialized. This is useful for testing.

```ruby
stubs.get('/uni') { |env| [ 200, {}, 'urchin' ]}
```

You can also stub the request body with a string or a proc.
It would be useful to pass a proc if it's OK only to check the parts of the request body are passed.

```ruby
stubs.post('/kohada', 'where=sea&temperature=24') { |env| [ 200, {}, 'spotted gizzard shad' ]}
stubs.post('/anago', -> (request_body) { JSON.parse(request_body).slice('name') == { 'name' => 'Wakamoto' } }) { |env| [200, {}, 'conger eel'] }
```

If you want to stub requests that exactly match a path, parameters, and headers,
`strict_mode` would be useful.

```ruby
stubs = Faraday::Adapter::Test::Stubs.new(strict_mode: true) do |stub|
  stub.get('/ikura?nori=true', 'X-Soy-Sauce' => '5ml' ) { |env| [200, {}, 'ikura gunkan maki'] }
end
```

This stub expects the connection will be called like this:

```ruby
conn.get('/ikura', { nori: 'true' }, { 'X-Soy-Sauce' => '5ml' } )
```

If there are other parameters or headers included, the Faraday Test adapter
will raise `Faraday::Test::Stubs::NotFound`. It also raises the error
if the specified parameters (`nori`) or headers (`X-Soy-Sauce`) are omitted.

You can also enable `strict_mode` after initializing the connection.
In this case, all requests, including ones that have been already stubbed,
will be handled in a strict way.

```ruby
stubs.strict_mode = true
```

Finally, you can treat your stubs as mocks by verifying that all of the stubbed
calls were made. NOTE: this feature is still fairly experimental. It will not
verify the order or count of any stub.

```ruby
stubs.verify_stubbed_calls
```

After the test case is completed (possibly in an `after` hook), you should reset
the stubs so each test starts with its own set. When you hold a reference to the
`Stubs` instance, call `clear` to remove every stub, including consumed ones.

```ruby
stubs.clear
```

Alternatively, if you rely on the default connection, you can clear it to prevent
it from being cached between different tests.

```ruby
Faraday.default_connection = nil
```

## Named scenarios

Plain stubs match each request on its own, which cannot prove that calls
happen in the right order. Named scenarios describe a stateful API
workflow instead: which requests each state accepts, and how a successful
request moves the scenario to the next state.

```ruby
stubs = Faraday::Adapter::Test::Stubs.new do |s|
  s.scenario(:resource_lifecycle) do |scenario|
    scenario.state :empty do |state|
      state.on :post, '/resources', to: :pending do |_env, session|
        session[:id] = 'res-1'
        [201, {}, JSON.dump(id: session[:id], status: 'pending')]
      end
    end
    scenario.state :pending do |state|
      state.on :get, '/resources/{id}' do |_env, session|
        [200, {}, JSON.dump(id: session[:id], status: 'pending')]
      end
      state.on :delete, '/resources/{id}', to: :gone do
        [204, {}, '']
      end
    end
    scenario.state :gone, terminal: true
  end
end
```

The first defined state is the initial one. A request that matches the
initial state starts a new session, and every session keeps its own state
and captured data, so several resources can go through the lifecycle
independently. A step without a `to:` transition keeps the session in its
current state, which makes repeated polling natural; a step block may also
call `session.transition_to` to pick the next state dynamically.

Path templates like `/resources/{id}` capture a segment into the session
the first time they match and require the same value afterwards, so later
responses can reference data captured by earlier requests of the same
session. Steps may also use a Regexp path, and the block then receives the
match data as its third argument.

A request that does not fit the current state raises
`Faraday::Adapter::Test::Stubs::ScenarioMismatch` (a subclass of
`Stubs::NotFound`) explaining the expected next step, and no later step is
consumed. Transitions only happen when the response status is below 400,
so polling after a failed create reports the failed step instead of
silently advancing:

```
scenario :resource_lifecycle cannot accept DELETE http:/resources/res-1 yet;
expected one of: POST /resources; no later step was consumed

scenario :resource_lifecycle cannot accept GET http:/resources/res-1 yet;
session #1 is in state :empty and expects one of: POST /resources;
session #1 step POST /resources responded 500 and did not advance;
no later step was consumed
```

`verify_stubbed_calls` also checks that every scenario session reached a
terminal state, and `clear` resets all sessions so each test starts over.
Plain stubs and scenarios can be mixed freely on the same `Stubs` object.

## Examples

Working [RSpec] and [test/unit] examples for a fictional JSON API client are
available.

[RSpec]: https://github.com/lostisland/faraday/blob/main/examples/client_spec.rb
[test/unit]: https://github.com/lostisland/faraday/blob/main/examples/client_test.rb
