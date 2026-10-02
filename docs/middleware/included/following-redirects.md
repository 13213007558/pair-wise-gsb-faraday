# Following Redirects

The `FollowRedirects` middleware follows HTTP redirect responses and returns
the final response to the caller. Relative `Location` headers are resolved
against the current URL, redirect loops are detected, and the number of hops
is limited.

```ruby
conn = Faraday.new(url: 'http://httpbingo.org') do |faraday|
  faraday.response :follow_redirects
end

response = conn.get('/redirect/2')
response.status          # => 200
response.env[:redirects] # => [{ method: :get, url: "...", status: 302, location: "..." }, ...]
```

Every hop is performed by re-entering the middleware stack *below*
`follow_redirects`, so each redirect goes through the same, clearly defined
middleware order (e.g. logging and the adapter). Middleware stacked above
`follow_redirects` only runs once per logical request.

The chain is recorded on the final env under `env[:redirects]`: an array of
hashes with the `:method`, `:url`, `:status` and `:location` of every hop.

## Method and body handling

* **301/302**: a `POST` is rewritten to a body-less `GET` for compatibility
  with common server expectations. Set `standards_compliant: true` to keep
  the original method and body instead. Other methods are never rewritten.
* **303**: the follow-up request always becomes a body-less `GET`
  (except `HEAD`, which stays `HEAD`).
* **307/308**: the method and body are always preserved.

When the body is dropped, entity headers (`Content-Type`, `Content-Length`,
`Content-Encoding`, `Content-MD5`) are removed as well. When the body is
kept, it must be replayable: strings are re-sent as-is and IO-like bodies
are rewound; a body that can only be read once raises
`Faraday::Response::FollowRedirects::NonReplayableBodyError`.

## Security

* Redirects to a different origin (scheme, host or port) drop the
  `Authorization` header and a manually set `Host` header.
* Redirects from HTTPS to HTTP are refused by default and raise
  `Faraday::Response::FollowRedirects::InsecureRedirectError`. Set
  `allow_https_to_http: true` to allow them.

## Errors

Failures raise subclasses of `Faraday::ClientError` whose messages include
the failing hop and the chain walked so far:

* `Faraday::Response::FollowRedirects::RedirectLimitReached` - the `:limit`
  was reached.
* `Faraday::Response::FollowRedirects::RedirectLoopError` - a URL was
  visited twice.
* `Faraday::Response::FollowRedirects::InsecureRedirectError` - HTTPS to
  HTTP downgrade.
* `Faraday::Response::FollowRedirects::NonReplayableBodyError` - the body
  cannot be sent a second time.

## Middleware Options

| Option                  | Default                    | Description |
|-------------------------|----------------------------|-------------|
| **limit**               | 3                          | Maximum number of redirects to follow before raising `RedirectLimitReached`. |
| **statuses**            | [301, 302, 303, 307, 308]  | Response statuses treated as redirects when they carry a `Location` header. |
| **standards_compliant** | false                      | When false, a 301/302 response to a POST is rewritten to a body-less GET. When true, method and body are preserved. |
| **allow_https_to_http** | false                      | Allow redirects that downgrade from HTTPS to HTTP. |

### Example Usage

```ruby
conn = Faraday.new(url: 'http://httpbingo.org') do |faraday|
  faraday.response :follow_redirects, limit: 5, standards_compliant: true
end

begin
  conn.get('/redirect/10')
rescue Faraday::Response::FollowRedirects::RedirectLimitReached => e
  e.message                  # => "redirect limit of 5 reached; stopped at GET ..."
  e.response[:redirects]     # => the hops followed before giving up
end
```
