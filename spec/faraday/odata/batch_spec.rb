# frozen_string_literal: true

RSpec.describe Faraday::OData::Batch do
  def operation(url:, content_id: nil, method: :post)
    Faraday::OData::Operation.new(method: method, url: url, content_id: content_id)
  end

  it 'is valid when references point to preceding operations of the same change set' do
    batch = described_class.new([
                                  Faraday::OData::ChangeSet.new([
                                                                  operation(url: 'Customers', content_id: '1'),
                                                                  operation(url: '$1/Orders', content_id: '2')
                                                                ])
                                ])

    expect { batch.validate! }.not_to raise_error
  end

  it 'rejects duplicate Content-IDs across the whole batch' do
    batch = described_class.new([
                                  operation(url: 'Customers', content_id: '1', method: :get),
                                  Faraday::OData::ChangeSet.new([
                                                                  operation(url: 'Orders', content_id: '1')
                                                                ])
                                ])

    expect { batch.validate! }
      .to raise_error(Faraday::OData::ValidationError, /duplicate Content-ID "1"/)
  end

  it 'rejects change set operations without a Content-ID' do
    batch = described_class.new([
                                  Faraday::OData::ChangeSet.new([
                                                                  operation(url: 'Customers')
                                                                ])
                                ])

    expect { batch.validate! }
      .to raise_error(Faraday::OData::ValidationError, /missing a Content-ID/)
  end

  it 'rejects references to operations that come later' do
    batch = described_class.new([
                                  Faraday::OData::ChangeSet.new([
                                                                  operation(url: '$2/Orders', content_id: '1'),
                                                                  operation(url: 'Customers', content_id: '2')
                                                                ])
                                ])

    expect { batch.validate! }
      .to raise_error(Faraday::OData::ValidationError, /not a preceding operation/)
  end

  it 'rejects references to operations of another change set' do
    batch = described_class.new([
                                  Faraday::OData::ChangeSet.new([
                                                                  operation(url: 'Customers', content_id: '1')
                                                                ]),
                                  Faraday::OData::ChangeSet.new([
                                                                  operation(url: '$1/Orders', content_id: '2')
                                                                ])
                                ])

    expect { batch.validate! }
      .to raise_error(Faraday::OData::ValidationError, /not a preceding operation/)
  end

  it 'rejects references outside change sets' do
    batch = described_class.new([
                                  operation(url: '$1/Orders', method: :get)
                                ])

    expect { batch.validate! }
      .to raise_error(Faraday::OData::ValidationError, /outside a change set/)
  end

  it 'detects references in string bodies as well' do
    op = Faraday::OData::Operation.new(
      method: :post, url: 'Orders', body: '{"customer":"$9"}', content_id: '2'
    )
    batch = described_class.new([Faraday::OData::ChangeSet.new([op])])

    expect { batch.validate! }
      .to raise_error(Faraday::OData::ValidationError, /not a preceding operation/)
  end

  it 'does not mistake query options for references' do
    batch = described_class.new([
                                  operation(url: 'Orders?$filter=Amount gt 100&$top=5', method: :get)
                                ])

    expect { batch.validate! }.not_to raise_error
  end
end
