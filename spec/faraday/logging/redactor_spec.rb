# frozen_string_literal: true

RSpec.describe Faraday::Logging::Redactor do
  subject(:redactor) { described_class.new(rules) }

  let(:rules) { {} }

  describe '#empty?' do
    it 'is true when no rules are configured' do
      expect(described_class.new).to be_empty
      expect(described_class.new(nil)).to be_empty
    end

    it 'is false when any rule is configured' do
      expect(described_class.new(headers: %w[Authorization])).not_to be_empty
      expect(described_class.new(query: %w[token])).not_to be_empty
      expect(described_class.new(form: %w[password])).not_to be_empty
      expect(described_class.new(json: ['$.password'])).not_to be_empty
    end
  end

  describe '#redact_headers' do
    let(:rules) { { headers: %w[Authorization X-Api-Token] } }
    let(:headers) do
      Faraday::Utils::Headers.new(
        'Authorization' => 'Bearer s3cr3t',
        'x-api-token' => 'abc123',
        'Accept' => 'text/html'
      )
    end

    it 'redacts configured header names case-insensitively' do
      redacted = redactor.redact_headers(headers)
      expect(redacted).to contain_exactly(
        ['Authorization', '[REDACTED]'],
        ['x-api-token', '[REDACTED]'],
        ['Accept', 'text/html']
      )
    end

    it 'does not mutate the given headers' do
      redactor.redact_headers(headers)
      expect(headers['Authorization']).to eq('Bearer s3cr3t')
      expect(headers['X-Api-Token']).to eq('abc123')
    end

    it 'returns headers untouched when no header rules are configured' do
      bare = described_class.new(query: %w[token])
      expect(bare.redact_headers(headers)).to equal(headers)
    end

    it 'supports a custom replacement' do
      custom = described_class.new(headers: %w[Authorization], replacement: '***')
      expect(custom.redact_headers(headers)).to include(['Authorization', '***'])
    end
  end

  describe '#redact_url' do
    let(:rules) { { query: %w[token password] } }

    it 'redacts matching query keys and keeps the rest' do
      expect(redactor.redact_url('http://example.org/?token=abc&keep=1'))
        .to eq('http://example.org/?token=[REDACTED]&keep=1')
    end

    it 'redacts every occurrence of repeated keys' do
      expect(redactor.redact_url('http://example.org/?token=a&token=b&keep=1'))
        .to eq('http://example.org/?token=[REDACTED]&token=[REDACTED]&keep=1')
    end

    it 'redacts nested array keys' do
      expect(redactor.redact_url('http://example.org/?token[]=a&token[]=b'))
        .to eq('http://example.org/?token[]=[REDACTED]&token[]=[REDACTED]')
    end

    it 'redacts percent-encoded nested keys' do
      expect(redactor.redact_url('http://example.org/?user%5Btoken%5D=abc'))
        .to eq('http://example.org/?user%5Btoken%5D=[REDACTED]')
    end

    it 'redacts keys without values' do
      expect(redactor.redact_url('http://example.org/?token&keep=1'))
        .to eq('http://example.org/?token=[REDACTED]&keep=1')
    end

    it 'preserves the fragment' do
      expect(redactor.redact_url('http://example.org/?token=abc#section'))
        .to eq('http://example.org/?token=[REDACTED]#section')
    end

    it 'returns the url unchanged when there is no query' do
      expect(redactor.redact_url('http://example.org/path'))
        .to eq('http://example.org/path')
    end

    it 'returns the url unchanged when no query rules are configured' do
      bare = described_class.new(headers: %w[Authorization])
      expect(bare.redact_url('http://example.org/?token=abc'))
        .to eq('http://example.org/?token=abc')
    end

    it 'does not mutate the given url string' do
      url = +'http://example.org/?token=abc'
      redactor.redact_url(url)
      expect(url).to eq('http://example.org/?token=abc')
    end
  end

  describe '#redact_form_string' do
    let(:rules) { { form: %w[password phones] } }

    it 'redacts matching form keys and keeps other params' do
      expect(redactor.redact_form_string('password=hunter2&name=Unagi'))
        .to eq('password=[REDACTED]&name=Unagi')
    end

    it 'redacts repeated keys' do
      expect(redactor.redact_form_string('password=a&password=b'))
        .to eq('password=[REDACTED]&password=[REDACTED]')
    end

    it 'redacts nested arrays' do
      expect(redactor.redact_form_string('phones[]=138&phones[]=139&name=Unagi'))
        .to eq('phones[]=[REDACTED]&phones[]=[REDACTED]&name=Unagi')
    end

    it 'redacts deeply nested keys' do
      expect(redactor.redact_form_string('user[password]=hunter2'))
        .to eq('user[password]=[REDACTED]')
    end
  end

  describe '#redact_json_string' do
    let(:rules) do
      { json: ['$.password', '$.user.token', '$.phones[*]', '$.users[*].phone', '$.items[0]'] }
    end

    it 'redacts top-level keys' do
      expect(redactor.redact_json_string('{"password":"hunter2","name":"Unagi"}'))
        .to eq('{"password":"[REDACTED]","name":"Unagi"}')
    end

    it 'redacts nested keys' do
      expect(redactor.redact_json_string('{"user":{"token":"abc","name":"n"}}'))
        .to eq('{"user":{"token":"[REDACTED]","name":"n"}}')
    end

    it 'redacts every element of an array wildcard' do
      expect(redactor.redact_json_string('{"phones":["138","139"]}'))
        .to eq('{"phones":["[REDACTED]","[REDACTED]"]}')
    end

    it 'redacts keys inside array elements' do
      json = '{"users":[{"phone":"138","name":"a"},{"phone":"139","name":"b"}]}'
      expect(redactor.redact_json_string(json))
        .to eq('{"users":[{"phone":"[REDACTED]","name":"a"},' +               '{"phone":"[REDACTED]","name":"b"}]}')
    end

    it 'redacts array indexes' do
      expect(redactor.redact_json_string('{"items":["secret","keep"]}'))
        .to eq('{"items":["[REDACTED]","keep"]}')
    end

    it 'redacts whole subtrees, preserving their shape' do
      expect(redactor.redact_json_string('{"password":{"hash":"x","salt":"y"}}'))
        .to eq('{"password":{"hash":"[REDACTED]","salt":"[REDACTED]"}}')
    end

    it 'returns nil for unparsable JSON' do
      expect(redactor.redact_json_string('not json {')).to be_nil
    end
  end

  describe '#redact_body_string' do
    context 'with a form content type' do
      let(:rules) { { form: %w[password] } }

      it 'redacts form keys' do
        expect(redactor.redact_body_string('password=x&name=y', 'application/x-www-form-urlencoded'))
          .to eq('password=[REDACTED]&name=y')
      end

      it 'supports content types with parameters' do
        expect(redactor.redact_body_string('password=x', 'application/x-www-form-urlencoded; charset=utf-8'))
          .to eq('password=[REDACTED]')
      end

      it 'returns the body unchanged without a content type' do
        expect(redactor.redact_body_string('password=x', nil)).to eq('password=x')
      end
    end

    context 'with a JSON content type' do
      let(:rules) { { json: ['$.password'] } }

      it 'redacts JSON paths' do
        expect(redactor.redact_body_string('{"password":"x"}', 'application/json'))
          .to eq('{"password":"[REDACTED]"}')
      end

      it 'supports vendor JSON content types' do
        expect(redactor.redact_body_string('{"password":"x"}', 'application/vnd.api+json'))
          .to eq('{"password":"[REDACTED]"}')
      end

      it 'returns a restricted notice when the body cannot be parsed' do
        expect(redactor.redact_body_string('not json {', 'application/json'))
          .to eq('[body omitted: could not parse JSON body for redaction]')
      end
    end
  end

  describe '#redact_structured' do
    let(:rules) { { form: %w[password], json: ['$.phones[*]'] } }

    it 'redacts a deep copy without mutating the original' do
      body = { 'password' => 'hunter2', 'phones' => %w[138 139], 'name' => 'Unagi' }
      redacted = redactor.redact_structured(body)

      expect(redacted).to eq(
        'password' => '[REDACTED]',
        'phones' => ['[REDACTED]', '[REDACTED]'],
        'name' => 'Unagi'
      )
      expect(body).to eq(
        'password' => 'hunter2',
        'phones' => %w[138 139],
        'name' => 'Unagi'
      )
    end
  end

  describe '.parse_json_path' do
    it 'parses dot notation' do
      expect(described_class.parse_json_path('$.user.token')).to eq(%w[user token])
    end

    it 'parses paths without a leading $' do
      expect(described_class.parse_json_path('user.token')).to eq(%w[user token])
    end

    it 'parses array wildcards and indexes' do
      expect(described_class.parse_json_path('$.users[*].phone')).to eq(['users', :*, 'phone'])
      expect(described_class.parse_json_path('$.items[0]')).to eq(['items', 0])
    end
  end
end
