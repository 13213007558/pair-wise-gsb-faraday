# Logging

The `Logger` middleware logs both the request and the response body and headers.
It is highly customizable and allows to mask confidential information if necessary.

### Basic Usage

```ruby
conn = Faraday.new(url: 'http://httpbingo.org') do |faraday|
  faraday.response :logger # log requests and responses to $stdout
end

conn.get
# => INFO  -- request: GET http://httpbingo.org/
# => DEBUG -- request: User-Agent: "Faraday v1.0.0"
# => INFO  -- response: Status 301
# => DEBUG -- response: date: "Sun, 19 May 2019 16:05:40 GMT"
```

### Customize the logger

By default, the `Logger` middleware uses the Ruby `Logger.new($stdout)`.
You can customize it to use any logger you want by providing it when you add the middleware to the stack:

```ruby
conn = Faraday.new(url: 'http://httpbingo.org') do |faraday|
  faraday.response :logger, MyLogger.new($stdout)
end
```

### Include and exclude headers/bodies

By default, the `logger` middleware logs only headers for security reasons, however, you can configure it
to log bodies and errors as well, or disable headers logging if you need to.
To do so, simply provide a configuration hash when you add the middleware to the stack:

```ruby
conn = Faraday.new(url: 'http://httpbingo.org') do |faraday|
  faraday.response :logger, nil, { headers: true, bodies: true, errors: true }
end
```

You can also configure the `logger` middleware with a little more complex settings
like "do not log the request bodies, but log the response bodies".

```ruby
conn = Faraday.new(url: 'http://httpbingo.org') do |faraday|
  faraday.response :logger, nil, { bodies: { request: false, response: true } }
end
```

Please note this only works with the default formatter.

### Filter sensitive information

You can filter sensitive information from Faraday logs using a regex matcher:

```ruby
conn = Faraday.new(url: 'http://httpbingo.org') do |faraday|
  faraday.response :logger do | logger |
    logger.filter(/(api_key=)([^&]+)/, '\1[REMOVED]')
  end
end

conn.get('/', api_key: 'secret')
# => INFO  -- request: GET http://httpbingo.org/?api_key=[REMOVED]
# => DEBUG -- request: User-Agent: "Faraday v1.0.0"
# => INFO  -- response: Status 301
# => DEBUG -- response: date: "Sun, 19 May 2019 16:12:36 GMT"
```

### Redact sensitive information

For structured redaction, provide a `redact` option with rules for header
names, URL query keys, form-encoded body keys and JSON paths. Redaction is
applied only to the logged output: the request and response passed through
the adapter (objects, bytes and signatures) are never modified, and
one-shot (IO-like) bodies are never read for logging. When a body cannot
be parsed for redaction, a restricted notice is logged instead of the raw
content.

```ruby
conn = Faraday.new(url: 'http://httpbingo.org') do |faraday|
  faraday.response :logger, nil, {
    bodies: true,
    redact: {
      headers: %w[Authorization],              # header names (case-insensitive)
      query: %w[token],                        # URL query keys
      form: %w[password],                      # form-encoded body keys
      json: ['$.user.password', '$.phones[*]'] # JSON paths
    }
  }
end

conn.post('/login?token=t1', 'password=hunter2&phones[]=138',
          'Content-Type' => 'application/x-www-form-urlencoded',
          'Authorization' => 'Bearer s3cr3t')
# => INFO  -- request: POST http://httpbingo.org/login?token=[REDACTED]
# => DEBUG -- request: Authorization: "[REDACTED]"
# => DEBUG -- request: password=[REDACTED]&phones[]=[REDACTED]
```

Rules can also be scoped per direction with the `request` and `response`
keys; rules without a direction apply to both. Repeated parameters and
nested arrays (e.g. `phones[]=1&phones[]=2`) are all covered, and JSON
paths support nested keys (`$.a.b`), array indexes (`$.a[0]`) and array
wildcards (`$.a[*]`). The replacement text defaults to `[REDACTED]` and
can be changed with the `replacement` rule.

```ruby
faraday.response :logger, nil, {
  bodies: true,
  redact: {
    request:  { json: ['$.password'] },
    response: { json: ['$.token'], replacement: '[HIDDEN]' }
  }
}
```

### Change log level

By default, the `logger` middleware logs on the `info` log level. It is possible to configure
the severity by providing the `log_level` option:

```ruby
conn = Faraday.new(url: 'http://httpbingo.org') do |faraday|
  faraday.response :logger, nil, { bodies: true, log_level: :debug }
end
```

### Customize the formatter

You can also provide a custom formatter to control how requests, responses and errors are logged.
Any custom formatter MUST implement the `request` and `response` method, with one argument which
will be passed being the Faraday environment.
Any custom formatter CAN implement the `exception` method,
with one argument which will be passed being the exception (StandardError).
If you make your formatter inheriting from `Faraday::Logging::Formatter`,
then the methods `debug`, `info`, `warn`, `error` and `fatal` are automatically delegated to the logger.

```ruby
class MyFormatter < Faraday::Logging::Formatter
  def request(env)
    # Build a custom message using `env`
    info('Request') { 'Sending Request' }
  end

  def response(env)
    # Build a custom message using `env`
    info('Response') { 'Response Received' }
  end

  def exception(exc)
    # Build a custom message using `exc`
    info('Error') { 'Error Raised' }
  end
end

conn = Faraday.new(url: 'http://httpbingo.org/api_key=s3cr3t') do |faraday|
  faraday.response :logger, nil, formatter: MyFormatter
end
```
