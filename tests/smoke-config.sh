#!/usr/bin/env bash
# Smoke test: configuration loading and tri-state semantics.
# Runs on any host with Ruby (no serial port required).

set -u

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
CONFIG="$REPO_ROOT/examples/profiles/analogue-sendspin.json"

if [ ! -f "$CONFIG" ]; then
    echo "FAIL: config not found at $CONFIG" >&2
    exit 1
fi

# Provide stubs so control.rb can be required without serialport/webrick.
TMPSTUB="$(mktemp -d)"
trap 'rm -rf "$TMPSTUB"' EXIT

mkdir -p "$TMPSTUB/webrick"
cat > "$TMPSTUB/serialport.rb" <<'EOS'
module SerialPort
  HARD = 0
  class SerialPort
    def initialize(*); end
    def set_encoding(*); end
    def flow_control=(*); end
    def sync=(*); end
    def read_timeout=(*); end
    def read; nil; end
    def write(*); end
    def self.open(*); raise 'no real port'; end
  end
end
EOS

cat > "$TMPSTUB/webrick.rb" <<'EOS'
module WEBrick
  class HTTPServer
    def initialize(*); end
    def mount_proc(*); end
    def start; end
  end
  class Log; def initialize(*); end; end
end
EOS

export YAS207_RUNTIME_DIR="$TMPSTUB/runtime"
export YAS207_CONFIG="$CONFIG"

ruby -I"$TMPSTUB" -I"$REPO_ROOT/control" -e "
require_relative '$REPO_ROOT/control/control'

remote = YamahaSoundbarRemote.new

failures = []

# Expected values from our example profile
expected = {
  'controller.manage_power' => false,
  'controller.initial_intent_mode' => 'present_empty',
  'controller.rfcomm_device' => '/dev/rfcomm0',
  'controller.http_bind' => '127.0.0.1',
  'controller.http_port' => 8000,
  'controller.rfcomm_channel' => 1,
  'controller.bluetooth_address' => '02:0A:0B:0C:0D:0E',
  'session.name' => 'sendspin',
  'session.stop_debounce_seconds' => 10,
  'volume.min_nonzero_raw' => 1,
  'volume.max_raw' => 50,
  'volume.zero_is_mute' => true,
  'volume.default_percent' => 50,
  'player.type' => 'sendspin',
  'player.name' => 'Example Room',
  'player.interface' => '192.0.2.135',
  'player.audio_device.match' => 'Example ALSA Device',
}

[
  ['controller.manage_power', remote.instance_variable_get(:@manage_power), expected['controller.manage_power']],
  ['controller.initial_intent_mode', remote.instance_variable_get(:@initial_intent_mode).to_s, expected['controller.initial_intent_mode']],
  ['controller.rfcomm_device', remote.instance_variable_get(:@rfcomm_device), expected['controller.rfcomm_device']],
  ['controller.http_bind', remote.instance_variable_get(:@http_bind), expected['controller.http_bind']],
  ['controller.http_port', remote.instance_variable_get(:@http_port), expected['controller.http_port']],
].each do |k, actual, want|
  if actual == want
    puts \"OK  #{k} = #{actual.inspect}\"
  else
    puts \"FAIL #{k}: got #{actual.inspect}, want #{want.inspect}\"
    failures << k
  end
end

[
  ['controller.rfcomm_channel', remote.config['controller']['rfcomm_channel'], 1],
  ['controller.bluetooth_address', remote.config['controller']['bluetooth_address'], '02:0A:0B:0C:0D:0E'],
  ['session.name', remote.config['session']['name'], 'sendspin'],
  ['session.stop_debounce_seconds', remote.config['session']['stop_debounce_seconds'], 10],
  ['volume.min_nonzero_raw', remote.config['volume']['min_nonzero_raw'], 1],
  ['volume.max_raw', remote.config['volume']['max_raw'], 50],
  ['volume.zero_is_mute', remote.config['volume']['zero_is_mute'], true],
  ['volume.default_percent', remote.config['volume']['default_percent'], 50],
  ['player.type', remote.config['player']['type'], 'sendspin'],
  ['player.name', remote.config['player']['name'], 'Example Room'],
  ['player.interface', remote.config['player']['interface'], '192.0.2.135'],
  ['player.audio_device.match', remote.config['player']['audio_device']['match'], 'Example ALSA Device'],
].each do |k, actual, want|
  if actual == want
    puts \"OK  #{k} = #{actual.inspect}\"
  else
    puts \"FAIL #{k}: got #{actual.inspect}, want #{want.inspect}\"
    failures << k
  end
end

# Tri-state explicit test
modes = {
  :absent        => {},
  :present_empty => { 'initial_intent' => {} },
  :configured    => { 'initial_intent' => { 'clearvoice' => false } },
}
modes.each do |expected_mode, ctrl|
  cfg = { 'controller' => ctrl }
  r = YamahaSoundbarRemote.new(cfg)
  actual = r.instance_variable_get(:@initial_intent_mode)
  if actual == expected_mode
    puts \"OK  tri-state #{expected_mode} -> #{actual}\"
  else
    puts \"FAIL tri-state #{expected_mode}: got #{actual}\"
    failures << \"tri-state #{expected_mode}\"
  end
end

if failures.empty?
  puts ''
  puts 'PASS'
  exit 0
else
  puts ''
  puts \"FAIL: #{failures.size} check(s)\"
  exit 1
end
"
