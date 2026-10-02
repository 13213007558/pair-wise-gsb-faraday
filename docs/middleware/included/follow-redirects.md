# Following Redirects

The `Faraday::Request::FollowRedirects` middleware transparently follows HTTP
redirects (301, 302, 303, 307 and 308) before returning the response.

```ruby
Faraday.new(...) do |conn|
  conn.request :follow_redirects
end
```

Every hop re-traverses the middleware stacked *below* this one, so place it
early in the stack if other middleware should see each redirected request.

### Options

* `limit` (default: `3`) - maximum number of redirects to follow before
  raising `Faraday::RedirectLimitReached`.
* `convert_post_to_get_on_301_302` (default: `true`) - rewrite POST into GET
  on 301/302, matching widespread browser behaviour. 303 always rewrites to
  GET (except HEAD); 307/308 never rewrite the method.
* `allow_https_to_http` (default: `false`) - allow redirects that downgrade
  from HTTPS to HTTP. Refused by default with `Faraday::InsecureRedirectError`.
* `clear_authorization_header` (default: `true`) - remove credential headers
  (`Authorization`, `Proxy-Authorization`) when a redirect crosses origins.
  A manually set `Host` header is always dropped on cross-origin redirects.

### Method and body handling

When a redirect rewrites the request into a body-less GET, the entity headers
(`Content-Type`, `Content-Length`, `Content-Encoding`, `Content-MD5`)
are removed together with the body.

When the method and body are kept (307/308, or 301/302 with
`convert_post_to_get_on_301_302: false`), the body must be replayable:
strings are sent as-is and IO-like bodies are rewound. A body that can only be
read once raises `Faraday::NonReplayableBodyError`.

### Inspecting the chain

The hops followed are recorded on the final response env:

```ruby
response = conn.get('/redirected')
response.env[:redirects]
# => [{ status: 302, from: 'http://example.org/redirected', to: 'http://example.org/landed' }]
```

Redirect loops raise `Faraday::RedirectLoopDetected`. All redirect errors
subclass `Faraday::RedirectError` and carry the hops completed so far in
`error.redirects`, while the error message names the hop at which the chain
stopped.
