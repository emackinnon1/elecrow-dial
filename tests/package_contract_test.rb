require 'base64'
require 'minitest/autorun'
require 'pathname'
require 'psych'

class PackageContractTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  TEMPLATE = 'src/main/dial_lights_sensors.yaml'
  TEXT_BINDINGS = %w[state_sensor modes_sensor color_sensor color_mode_sensor].freeze

  def load_yaml(path, variables = {})
    text = File.read(File.join(ROOT, path))
    variables.each { |name, value| text = text.gsub("${#{name}}", value.to_s) }
    Psych.load(text)
  end

  def package_files(path)
    path = Pathname.new(path).cleanpath.to_s
    config = load_yaml(path)
    [path] + config.fetch('packages', {}).values.flat_map do |include_path|
      package_files(File.join(File.dirname(path), include_path))
    end
  end

  def assert_unique_keys(node, path)
    if node.is_a?(Psych::Nodes::Mapping)
      keys = node.children.each_slice(2).map { |key, _value| key.value }
      assert_equal keys.uniq, keys, "Duplicate YAML keys in #{path}"
    end
    (node.children || []).each { |child| assert_unique_keys(child, path) }
  end

  def test_yaml_syntax_and_unique_keys
    paths = %w[dial.yaml elecrow-dial.yaml example_entry.yaml] +
            Dir.chdir(ROOT) { Dir['src/{main,pages}/*.yaml'] }
    paths.each do |path|
      assert_unique_keys(Psych.parse_file(File.join(ROOT, path)), path)
    end
  end

  def test_shared_package_has_no_device_credentials_or_lights
    config = load_yaml('dial.yaml')
    assert_empty config.keys & %w[wifi ota captive_portal dial_lights]
    assert_empty config['esphome'].keys & %w[name friendly_name]
    refute config['api'].key?('encryption')
    assert config['api'].key?('on_client_connected')
    assert config['api'].key?('on_client_disconnected')
    files = package_files('dial.yaml')
    assert_equal files.uniq, files, 'Shared package included more than once'
    files.each do |path|
      text = File.read(File.join(ROOT, path))
      refute_includes text, '!secret', "Secret lookup in remote package #{path}"
      refute_match(/entity_id:\s*light\./, text, "Hardcoded light in #{path}")
    end
    assert_equal [], load_yaml('src/main/defaults.yaml')['dial_lights']
    refute_includes files, TEMPLATE
  end

  def test_wrapper_and_hardware_boot_ownership
    assert_equal({'packages' => {'elecrow_dial' => 'dial.yaml'}}, load_yaml('elecrow-dial.yaml'))
    assert_equal package_files('dial.yaml'), package_files('elecrow-dial.yaml').drop(1)
    entry = load_yaml('example_entry.yaml')
    assert_equal({'name' => 'bedroom-elecrow-dial', 'friendly_name' => 'bedroom elecrow dial'}, entry['esphome'])
    assert_empty entry.keys & %w[esp32 psram output touchscreen sensor binary_sensor]
    assert_equal 1, entry['ota'].length
    boots = package_files('dial.yaml').flat_map do |path|
      load_yaml(path).fetch('esphome', {}).fetch('on_boot', [])
    end
    assert_equal [-100, -50, 800], boots.map { |boot| boot['priority'] }.sort
    assert_equal 1, boots.count { |boot| boot['then'].include?({'output.turn_on' => 'gpio_3_backlight_pwm'}) }
  end

  def test_example_credentials_and_revisions
    entry = load_yaml('example_entry.yaml')
    assert_equal 32, Base64.strict_decode64(entry['api']['encryption']['key']).bytesize
    assert_equal 'change-me-ota-password', entry['ota'][0]['password']
    assert_equal 'change-me-fallback-password', entry['wifi']['ap']['password']
    assert_operator entry['wifi']['ap']['password'].length, :>=, 8
    text = File.read(File.join(ROOT, 'example_entry.yaml'))
    assert_equal %w[wifi_ssid wifi_password], text.scan(/!secret\s+(\w+)/).flatten
    assert_equal '${package_ref}', entry['substitutions']['asset_ref']
    remote = entry['packages']['smart_home_button']
    assert_equal '${package_ref}', remote['ref']
    assert_equal 'https://github.com/emackinnon1/elecrow-dial', remote['url']
    assert_equal 'dial.yaml', remote['files'][0]
  end

  def test_zero_one_and_seven_light_bindings
    entry = load_yaml('example_entry.yaml')
    instances = entry['packages']['smart_home_button']['files'].drop(1)
    assert_equal 7, instances.length
    assert_equal 7, entry['dial_lights'].length
    [0, 1, 7].each do |count|
      sensors_by_id = {}
      instances.take(count).each do |instance|
        assert_equal TEMPLATE, instance['path']
        expanded = load_yaml(instance['path'], instance['vars'])
        assert_equal 4, expanded['text_sensor'].length
        assert_equal 4, expanded['sensor'].length
        expanded.each do |type, sensors|
          sensors.each do |sensor|
            refute sensors_by_id.key?(sensor['id']), "Duplicate ID: #{sensor['id']}"
            refute_match(/\$\{/, sensor.to_s, 'Unresolved per-light variable')
            assert sensor['internal']
            sensors_by_id[sensor['id']] = [type, sensor]
          end
        end
      end
      assert_equal count * 8, sensors_by_id.length
      entry['dial_lights'].take(count).each do |light|
        bindings = light.select { |key, _value| key.end_with?('_sensor') }
        assert_equal 8, bindings.length
        bindings.each do |binding, id|
          type, sensor = sensors_by_id.fetch(id)
          assert_equal(TEXT_BINDINGS.include?(binding) ? 'text_sensor' : 'sensor', type)
          assert_equal light['entity_id'], sensor['entity_id']
        end
      end
    end
  end

  def test_local_assembly_ids_and_substitutions
    entry = load_yaml('example_entry.yaml')
    shared = package_files('dial.yaml').map { |path| load_yaml(path) }
    instances = entry['packages']['smart_home_button']['files'].drop(1)
    [0, 1, 7].each do |count|
      consumer = entry.merge('dial_lights' => entry['dial_lights'].take(count))
      configurations = shared + instances.take(count).map do |instance|
        load_yaml(instance['path'], instance['vars'])
      end + [consumer]
      substitutions = configurations.each_with_object({}) do |config, merged|
        merged.merge!(config.fetch('substitutions', {}))
      end
      definitions = ['dial_lights_id']
      references = []
      walk = lambda do |node, location|
        case node
        when Hash
          if node['id'].is_a?(String)
            action = location.any? do |part|
              part.include?('.') || %w[then else].include?(part) || part.start_with?('on_')
            end
            (action ? references : definitions) << node['id']
          end
          node.each do |key, value|
            if %w[script.execute script.stop light.turn_on light.turn_off output.turn_on output.turn_off].include?(key) && value.is_a?(String)
              references << value
            end
            walk.call(value, location + [key])
          end
        when Array
          node.each { |child| walk.call(child, location) }
        when String
          node.scan(/\bid\((\w+)\)/) { |match| references << match[0] }
          node.scan(/\$\{(\w+)\}/) do |match|
            assert substitutions.key?(match[0]), "Undefined substitution #{match[0]} with #{count} lights"
          end
        end
      end
      configurations.each { |config| walk.call(config, []) }
      assert_equal definitions.uniq, definitions, "Duplicate IDs with #{count} lights"
      assert_empty references.uniq - definitions, "Unresolved IDs with #{count} lights"
    end
  end

  def test_assets_have_no_consumer_local_file_dependency
    sources = []
    paths = ['dial.yaml'] + Dir.chdir(ROOT) { Dir['src/pages/*.yaml'] }
    paths.each do |path|
      config = load_yaml(path)
      %w[image font].each do |section|
        config.fetch(section, []).each do |item|
          source = item['file']
          if source.is_a?(Hash)
            next if source['type'] == 'gfonts'
            assert_equal 'web', source['type']
            source = source.fetch('url')
          end
          next if source.start_with?('gfonts://')
          assert source.start_with?('${assets_base_url}/'), "Local source in #{path}: #{source}"
          asset = source.sub('${assets_base_url}/', 'src/assets/')
          assert File.file?(File.join(ROOT, asset)), "Missing source asset #{asset}"
          sources << source
        end
      end
    end
    assert_equal 24, sources.length
    defaults = load_yaml('src/main/defaults.yaml')['substitutions']
    assert_equal 'https://raw.githubusercontent.com/emackinnon1/elecrow-dial/${asset_ref}/src/assets', defaults['assets_base_url']
  end
end