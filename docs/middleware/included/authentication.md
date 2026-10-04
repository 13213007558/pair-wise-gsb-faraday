# Authentication

The `Faraday::Request::Authorization` middleware allows you to automatically add an `Authorization` header
to your requests. It also features a handy helper to manage Basic authentication.
**Please note the way you use this middleware in Faraday 1.x is different**,
examples are available at the bottom of this page.

```ruby
Faraday.new(...) do |conn|
  conn.request :authorization, 'Bearer', 'authentication-token'
end
```

### With a proc

You can also provide a proc, which will be evaluated on each request:

```ruby
Faraday.new(...) do |conn|
  conn.request :authorization, 'Bearer', -> { MyAuthStorage.get_auth_token }
end
```

If the proc takes an argument, it will receive the forwarded `env` (see [The Env Object](getting-started/env-object.md)):

```ruby
Faraday.new(...) do |conn|
  conn.request :authorization, 'Bearer', ->(env) { MyAuthStorage.get_auth_token(env) }
end
```


### Basic Authentication

The middleware will automatically Base64 encode your Basic username and password:

```ruby
Faraday.new(...) do |conn|
  conn.request :authorization, :basic, 'username', 'password'
end
```

## Digest Authentication

The `Faraday::Request::DigestAuth` middleware answers
[RFC 7616](https://www.rfc-editor.org/rfc/rfc7616.html) Digest challenges for you:
it picks the strongest acceptable challenge when the server offers several, computes the
`Authorization` header (including `auth-int` entity-body hashes), tracks the nonce-count
per protection space, and follows `stale` and `Authentication-Info` (`nextnonce`/`rspauth`)
directives. SHA-256 and SHA-512-256 (plus their `-sess` variants) are supported; MD5 is
rejected unless you explicitly opt in with `allow_md5: true`.

```ruby
Faraday.new(...) do |conn|
  conn.request :digest_auth, 'username', 'password'
end
```

### Options

* `allow_md5:` (default `false`) accept MD5 and MD5-sess challenges.
* `max_retries:` (default `3`) maximum number of 401 retries for a single request,
  so wrong credentials fail instead of looping.
* `body_factory:` (default `nil`) a callable returning a fresh request body for retries.
  Bodies that cannot be replayed (e.g. a one-shot IO) are rejected before being resent
  unless a factory is provided.

```ruby
Faraday.new(...) do |conn|
  conn.request :digest_auth, 'username', 'password',
               allow_md5: true, max_retries: 2, body_factory: -> { File.open('payload.bin', 'rb') }
end
```

Add this middleware after body serializers (JSON, url-encoded) and after redirect-following
middleware, so digests are computed over the exact bytes being sent and credentials are
never forwarded to a different origin after a redirect.

### Faraday 1.x usage


In Faraday 1.x, the way you use this middleware is slightly different:

```ruby
# Basic Auth request
# Authorization: Basic dXNlcm5hbWU6cGFzc3dvcmQ=
Faraday.new(...) do |conn|
  conn.request :basic_auth, 'username', 'password'
end

# Token Auth request
# `options` are automatically converted into `key=value` format
# Authorization: Token authentication-token <options>
Faraday.new(...) do |conn|
  conn.request :token_auth, 'authentication-token', **options
end

# Generic Auth Request
# Authorization: Bearer authentication-token
Faraday.new(...) do |conn|
  conn.request :authorization, 'Bearer', 'authentication-token'
end
```
