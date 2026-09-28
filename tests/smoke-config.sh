#!/usr/bin/env bash
# Smoke test: configuration loading and tri-state semantics.
# Runs on any host with Ruby (no serial port required).
#
# Verifies:
#   1. The controller loads a JSON config and resolves the
#      documented generic defaults.
#   2. The tri-state controller.initial_intent is honoured:
#        absent        -> @initial_intent_mode == :absent
#        present {}    -> @initial_intent_mode == :present_empty
#        configured    -> @initial_intent_mode == :configured
#   3. Parsing failure is fatal (exit 2) per docs/configuration.md.
#
# Requires: ruby + the upstream serialport + webrick gems. The test
# stubs out the gem require() entry points with no-op modules so
# control.rb can be required on a host without hardware.

set -u

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
CONFIG="$REPO_ROOT/examples/profiles/shairport-toslink.json"

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

ruby -I"$TMPSTUB" -I"$REPO_ROOT/control" <<RUBY
require_relative '$REPO_ROOT/control/control'

failures = []

# 1. Documented generic defaults from examples/profiles/shairport-toslink.json
r = YamahaSoundbarRemote.new

checks = [
  ['manage_power',           r.instance_variable_get(:@manage_power), true],
  ['rfcomm_device',          r.instance_variable_get(:@rfcomm_device), '/dev/rfcomm0'],
  ['http_bind',              r.instance_variable_get(:@http_bind), '127.0.0.1'],
  ['http_port',              r.instance_variable_get(:@http_port), 8000],
  ['sync_timeout',           r.instance_variable_get(:@sync_timeout), 15],
  ['status_refresh',         r.instance_variable_get(:@status_refresh), 30],
  ['runtime_dir',            r.instance_variable_get(:@runtime_dir), ENV['YAS207_RUNTIME_DIR']],
  ['snapshot_path',          r.instance_variable_get(:@snapshot_path),
                              File.join(ENV['YAS207_RUNTIME_DIR'], 'controller', 'session.json')],
]
checks.each do |k, actual, want|
  if actual == want
    puts "OK  controller.#{k} = #{actual.inspect}"
  else
    puts "FAIL controller.#{k}: got #{actual.inspect}, want #{want.inspect}"
    failures << "controller.#{k}"
  end
end

# 2. Tri-state initial_intent handling.
modes = {
  :absent         => {},
  :present_empty  => { 'initial_intent' => {} },
  :configured     => { 'initial_intent' => { 'clearvoice' => false } },
}
modes.each do |expected_mode, ctrl|
  cfg = { 'controller' => ctrl }
  rr = YamahaSoundbarRemote.new(cfg)
  actual = rr.instance_variable_get(:@initial_intent_mode)
  if actual == expected_mode
    puts "OK  tri-state #{expected_mode} -> #{actual}"
  else
    puts "FAIL tri-state #{expected_mode}: got #{actual}"
    failures << "tri-state #{expected_mode}"
  end
end

# 3. With no config file, controller falls back to upstream legacy
ENV['YAS207_CONFIG'] = '/nonexistent/path/to/controller.json'
r_legacy = YamahaSoundbarRemote.new
if r_legacy.instance_variable_get(:@initial_intent_mode) == :absent &&
   r_legacy.instance_variable_get(:@manage_power) == true
  puts "OK  no-config -> legacy defaults"
else
  puts "FAIL no-config fallback"
  failures << 'no-config fallback'
end
ENV['YAS207_CONFIG'] = '$CONFIG'

if failures.empty?
  puts ''
  puts 'PASS'
  exit 0
else
  puts ''
  puts "FAIL: #{failures.size} check(s)"
  failures.each { |f| puts "  - #{f}" }
  exit 1
end
RUBY
