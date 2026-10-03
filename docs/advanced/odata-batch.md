# OData 4.01 Multipart Batch

Faraday includes standalone encoders and decoders for OData 4.01 `multipart/mixed` batch requests.
They are not middleware and do not require a deployed OData service to be tested.

```ruby
require 'faraday/odata'

batch = Faraday::OData.encode_batch([
  { method: :get, url: 'Products', content_id: 'products' },
  { changeset: [
    { method: :post, url: 'Products', body: { name: 'Parent' } },
    { method: :post, url: '$1/Children', body: { name: 'Child' } }
  ] }
])

connection = Faraday.new('https://services.example.org/odata')
response = connection.post(batch.path, batch.body, batch.headers)
decoded = Faraday::OData.decode_batch(response, batch: batch)

decoded.success?                       # false if any inner operation failed
decoded.operations.map(&:content_id)  # preserves response order, not request order
decoded.operation(1).status
```

Content-ID values are unique across the whole batch.
`$id` references are validated before the request is sent and may only address an earlier, creating operation in the same change set.
The decoder keeps the batch, change set, and operation hierarchy and parses nested boundaries, `application/http` status lines and headers, and binary bodies without assuming response order.
