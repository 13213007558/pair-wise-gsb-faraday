# Writing custom adapters

!> A template for writing your own custom adapter is available in the [faraday-adapter-template](https://github.com/lostisland/faraday-adapter-template) repository.

Adapters have methods that can help you implement support for a new backend.

This example will use a fictional HTTP backend gem called `FlorpHttp`. It doesn't
exist. Its only function is to make this example more concrete.

## An Adapter _is_ a Middleware

When you subclass `Faraday::Adapter`, you get helpful methods defined and all you need to do is to
extend the `call` method (remember to call `super` inside it!):

```ruby
module Faraday
  class Adapter
    class FlorpHttp < Faraday::Adapter
      def call(env)
        super
        # Perform the request and call `save_response`
      end
    end
  end
end
```

Now, there are only two things which are actually mandatory for an adapter middleware to function:

- a `#call` implementation
- a call to `#save_response` inside `#call`, which will keep the Response around.

These are the only two things, the rest of this text is about methods which make the authoring easier.

Like any other middleware, the `env` parameter passed to `#call` is an instance of [Faraday::Env][env-object].
This object will contain all the information about the request, as well as the configuration of the connection.
Your adapter is expected to deal with SSL and Proxy settings, as well as any other configuration options.

## Connection options and configuration block

Users of your adapter have two main ways of configuring it:
* connection options: these can be passed to your adapter initializer and are automatically stored into an instance variable `@connection_options`.
* configuration block: this can also be provided to your adapter initializer and it's stored into an instance variable `@config_block`.

Both of these are automatically managed by `Faraday::Adapter#initialize`, so remember to call it with `super` if you create an `initialize` method in your adapter.
You can then use them in your adapter code as you wish, since they're pretty flexible.

Below is an example of how they can be used:

```ruby
# You can use @connection_options and @config_block in your adapter code
class FlorpHttp < Faraday::Adapter
  def call(env)
    # `connection` internally calls `build_connection` and yields the result
    connection do |conn|
      # perform the request using configured `conn`
    end
  end

  def build_connection(env)
    conn = FlorpHttp::Client.new(pool_size: @connection_options[:pool_size] || 10)
    @config_block&.call(conn)
    conn
  end
end

# Then your users can provide them when initializing the connection
Faraday.new(...) do |f|
  # ...
  # in this example, { pool_size: 5 } will be provided as `connection_options`
  f.adapter :florp_http, pool_size: 5 do |client|
    # this block is useful to set properties unique to HTTP clients that are not
    # manageable through the Faraday API
    client.some_fancy_florp_http_property = 10
  end
end
```

## Implementing `#close`

Just like middleware, adapters can implement a `#close` method. It will be called when the connection is closed.
In this method, you should close any resources that you opened in `#initialize` or `#call`, like sockets or files.

```ruby
class FlorpHttp < Faraday::Adapter
  def close
    @socket.close if @socket
  end
end
```

## Helper methods

`Faraday::Adapter` provides some helper methods to make it easier to implement adapters.

### `#save_response`

The most important helper method and the only one you're expected to call from your `#call` method.
This method is responsible for, among other things, the following:
* Take the `env` object and save the response into it.
* Set the `:response` key in the `env` object.
* Parse headers using `Utils::Headers` and set the `:response_headers` key in the `env` object.
* Call `#finish` on the `Response` object, triggering the `#on_complete` callbacks in the middleware stack.

```ruby
class FlorpHttp < Faraday::Adapter
  def call(env)
    super
    # Perform the request using FlorpHttp.
    # Returns a FlorpHttp::Response object.
    response = FlorpHttp.perform_request(...)

    save_response(env, response.status, response.body, response.headers, response.reason_phrase)
  end
end
```

`#save_response` also accepts a `finished` keyword argument, which defaults to `true`, but that you can set to false
if you don't want it to call `#finish` on the `Response` object.

### Informational responses (`100` and `103`)

Adapters may receive provisional 1xx responses before the final response.
Because these are not the final response, they must not call `#save_response`,
`#finish`, response middleware, JSON decoding, or error-handling middleware.

Declare support explicitly and deliver each response through
`#save_information`. Adapters that do not declare support must not emit
informational events.

```ruby
class FlorpHttp < Faraday::Adapter
  self.supports_informational_responses = true

  def call(env)
    super
    save_information(env, response.status, response.headers)
    save_response(env, final.status, final.body, final.headers, final.reason)
  end
end
```

The callback receives an immutable `Faraday::InformationalResponse` with
`status`, `headers`, and `reason_phrase`:

```ruby
conn.get('/resources') do |request|
  request.options.on_informational_response = proc do |information|
    preload_links(information.headers['Link']) if information.status == 103
  end
end
```

After the final response completes, subsequent `#save_information` calls raise
`Faraday::LateInformationResponseError`. If a callback raises, Faraday marks
the pending response failed and the exception propagates as the terminal error.

### `#request_timeout`

Most HTTP libraries support different types of timeouts, like `:open_timeout`, `:read_timeout` and `:write_timeout`.
Faraday let you set individual values for each of these, as well as a more generic `:timeout` value on the request options.

This helper method knows about supported timeout types, and falls back to `:timeout` if they are not set.
You can use those when building the options you need for your backend's instantiation.

```ruby
class FlorpHttp < Faraday::Adapter
  def call(env)
    super
    # Perform the request using FlorpHttp.
    # Returns a FlorpHttp::Response object.
    response = FlorpHttp.perform_request(
      # ... other options ...,
      open_timeout: request_timeout(:open, env[:request]),
      read_timeout: request_timeout(:read, env[:request]),
      write_timeout: request_timeout(:write, env[:request])
    )

    # Call save_response
  end
end
```

## Register your adapter

Like middleware, you may register a nickname for your adapter.
People can then refer to your adapter with that name when initializing their connection.
You do that using `Faraday::Adapter.register_middleware`, like this:

```ruby
class FlorpHttp < Faraday::Adapter
  # ...
end

Faraday::Adapter.register_middleware(florp_http: FlorpHttp)
```

[env-object]: /getting-started/env-object.md
