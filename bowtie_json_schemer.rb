# frozen_string_literal: true

require 'json'
require 'json_schemer'

$stdout.sync = true

class UnsupportedCommand < StandardError; end
class UnsupportedVersion < StandardError; end
class UnsupportedDialect < StandardError; end

JSON_SCHEMER_VERSION = Gem::Version.new(Gem::Specification.find_by_name('json_schemer').version)

if JSON_SCHEMER_VERSION >= '2.0.0'
  SUPPORTED_DIALECTS = [
    'https://json-schema.org/draft/2020-12/schema',
    'https://json-schema.org/draft/2019-09/schema',
    'http://json-schema.org/draft-07/schema#',
    'http://json-schema.org/draft-06/schema#',
    'http://json-schema.org/draft-04/schema#',
  ].freeze

  @meta_schema_refs = {
    JSONSchemer::Draft202012::BASE_URI => JSONSchemer::Draft202012::SCHEMA,
    JSONSchemer::Draft201909::BASE_URI => JSONSchemer::Draft201909::SCHEMA,
    JSONSchemer::Draft7::BASE_URI => JSONSchemer::Draft7::SCHEMA,
    JSONSchemer::Draft6::BASE_URI => JSONSchemer::Draft6::SCHEMA,
    JSONSchemer::Draft4::BASE_URI => JSONSchemer::Draft4::SCHEMA,
  }
  @meta_schema_refs.merge!(JSONSchemer::Draft202012::Meta::SCHEMAS)
  @meta_schema_refs.merge!(JSONSchemer::Draft201909::Meta::SCHEMAS)
  @meta_schema_refs.transform_keys! { |uri| uri.dup.tap { _1.fragment = nil } }

  def compiler_for(dialect)
    lambda { |kase|
      JSONSchemer.schema(
        kase.fetch('schema'),
        meta_schema: JSONSchemer::META_SCHEMAS_BY_BASE_URI_STR[dialect],
        format: false,
        regexp_resolver: 'ecma',
        ref_resolver: proc { |uri| kase.dig('registry', uri.to_s) || @meta_schema_refs[uri] },
      )
    }
  end
else
  SUPPORTED_DIALECTS = [
    'http://json-schema.org/draft-07/schema#',
    'http://json-schema.org/draft-06/schema#',
    'http://json-schema.org/draft-04/schema#',
  ].freeze

  if JSON_SCHEMER_VERSION >= '0.2.25'
    @classes_by_meta_schema = JSONSchemer::SCHEMA_CLASS_BY_META_SCHEMA
  elsif JSON_SCHEMER_VERSION >= '0.2.17'
    @classes_by_meta_schema = JSONSchemer::DRAFT_CLASS_BY_META_SCHEMA
  end

  def compiler_for(dialect)
    schemer = @classes_by_meta_schema[dialect]
    lambda { |kase|
      schemer.new(
        kase.fetch('schema'),
        ref_resolver: proc { |uri| kase.dig('registry', uri.to_s) },
      )
    }
  end
end

@compiler = nil

def unescape_json_pointer_token(token)
  token.gsub(/~[01]/, '~1' => '/', '~0' => '~')
end

def collect_annotations(output_unit)
  return [] unless output_unit.fetch('valid')

  output_unit.fetch('annotations', []).filter_map do |unit|
    next unless unit.key?('annotation')

    keyword_token = unit.fetch('keywordLocation').split('/').last
    {
      keyword: unescape_json_pointer_token(keyword_token),
      instanceLocation: unit.fetch('instanceLocation'),
      absoluteKeywordLocation: unit.fetch('absoluteKeywordLocation'),
      annotation: unit.fetch('annotation'),
    }
  end
end

def evaluate_test(schemer, test, output)
  instance = test.fetch('instance')
  return { valid: schemer.valid?(instance) } unless output == 'annotations'

  result = schemer.validate(
    instance,
    output_format: 'basic',
    resolve_enumerators: true,
  )
  {
    valid: result.fetch('valid'),
    annotations: collect_annotations(result),
  }
end

def handle_run(request)
  kase, seq = request.fetch_values('case', 'seq')
  output = request.fetch('output', 'flag')

  if output != 'flag' && (output != 'annotations' || JSON_SCHEMER_VERSION < '2.0.0')
    return {
      seq: seq,
      results: kase.fetch('tests').map do
        { skipped: true, message: "Unsupported output format: #{output}" }
      end,
    }
  end

  schemer = @compiler.call kase
  {
    seq: seq,
    results: kase.fetch('tests').map { |test| evaluate_test(schemer, test, output) },
  }
rescue StandardError => e
  {
    seq: seq,
    errored: true,
    context: { message: e.message, traceback: e.full_message },
  }
end

ARGF.each_line do |line| # rubocop:disable Metrics/BlockLength
  request = JSON.parse(line)
  cmd = request.fetch('cmd')

  response = case cmd
  when 'start'
    version = request.fetch('version')
    raise UnsupportedVersion, version unless version == 1

    os = `lsb_release -is`
    os_version = `lsb_release -rs`

    {
      version: version,
      implementation: {
        language: :ruby,
        name: :json_schemer,
        version: JSON_SCHEMER_VERSION.to_s,
        homepage: 'https://github.com/davishmcclurg/json_schemer',
        issues: 'https://github.com/davishmcclurg/json_schemer/issues',
        source: 'https://github.com/davishmcclurg/json_schemer',
        dialects: SUPPORTED_DIALECTS,
        os: os.chomp!,
        os_version: os_version.chomp!,
        language_version: RUBY_VERSION,
      },
    }
  when 'dialect'
    dialect = request.fetch('dialect')

    @compiler = compiler_for(dialect)
    raise UnsupportedDialect, dialect unless @compiler

    { ok: true }
  when 'run'
    handle_run(request)
  when 'stop'
    exit(0)
  else
    raise UnsupportedCommand, cmd
  end

  $stdout.puts(JSON.generate(response))
end
