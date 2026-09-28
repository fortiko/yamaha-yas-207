#!/usr/bin/env bash
# Smoke test: manage_power gating of enforce_intent.
# Runs on any host with Ruby (no serial port required).
#
# Verifies that with controller.manage_power=false:
#   - :power is stripped from the intent before enforce_intent runs.
#   - The auto-power-on path is skipped when the device is off but
#     other intents exist.
#   - :power is stripped from user-supplied intents in parse_intent.
#
# Also verifies that with manage_power=true the upstream legacy
# auto-power-on behaviour is preserved.

set -u

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

TMPSTUB="$(mktemp -d)"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPSTUB" "$TMPROOT"' EXIT

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

export YAS207_RUNTIME_DIR="$TMPROOT/runtime"
unset YAS207_CONFIG

ruby -I"$TMPSTUB" -I"$REPO_ROOT/control" <<RUBY
require_relative '$REPO_ROOT/control/control'

failures = []

# --- 1. Default: manage_power=true (legacy behaviour) ---
r1 = YamahaSoundbarRemote.new({})
if r1.manage_power == true
  puts "OK  default manage_power=true"
else
  puts "FAIL manage_power default: #{r1.manage_power.inspect}"
  failures << 'manage_power default'
end

# --- 2. Configured: manage_power=false ---
r2 = YamahaSoundbarRemote.new({ 'controller' => { 'manage_power' => false } })
if r2.manage_power == false
  puts "OK  configured manage_power=false"
else
  puts "FAIL manage_power=false: #{r2.manage_power.inspect}"
  failures << 'manage_power=false'
end

# --- 3. parse_intent strips :power when manage_power=false ---
intent_no_power = r2.__send__(:parse_intent, { 'power' => true, 'volume' => 10 })
if !intent_no_power.key?(:power) && intent_no_power[:volume] == 10
  puts "OK  parse_intent strips :power when manage_power=false"
else
  puts "FAIL parse_intent strips :power: #{intent_no_power.inspect}"
  failures << 'parse_intent strips :power'
end

# --- 4. parse_intent preserves :power when manage_power=true ---
r3 = YamahaSoundbarRemote.new({})
intent_with_power = r3.__send__(:parse_intent, { 'power' => true, 'volume' => 10 })
if intent_with_power[:power] == true && intent_with_power[:volume] == 10
  puts "OK  parse_intent preserves :power when manage_power=true"
else
  puts "FAIL parse_intent preserves :power: #{intent_with_power.inspect}"
  failures << 'parse_intent preserves :power'
end

# --- 5. enforce_intent: with manage_power=false, no power_on when device off ---
OFF_STATE = [5, 1, 0, 0x7, 0, 10, 16, 0, 0, 0, 0, 0x0a, 0]   # power=off
r4 = YamahaSoundbarRemote.new({ 'controller' => { 'manage_power' => false } })
r4.handle_received(:reset)
r4.handle_received([4])
r4.handle_received([0, 2, 0])
# Disable initial-intent so we get a clean baseline.
r4.instance_variable_set(:@initial_intent_mode, :present_empty)
r4.handle_received(OFF_STATE)
# Now queue an intent to switch input to analog while device is off.
r4.send_intent({ 'input' => 'analog' })
# Inspect the queue: with manage_power=false we should NOT see power_on.
queue_strings = []
begin
  loop do
    q = r4.pop
    break unless q
    queue_strings << q.bytes.map { |b| '%02x' % b }.join
  end
rescue ThreadError
end
sent_power_on = queue_strings.any? { |s| s.include?('40787e') }
if !sent_power_on
  puts "OK  manage_power=false skips auto-power-on path"
else
  puts "FAIL manage_power=false emitted power_on: #{queue_strings.inspect}"
  failures << 'manage_power=false skips auto-power-on'
end

# --- 6. enforce_intent: with manage_power=true (legacy), power_on IS emitted ---
r5 = YamahaSoundbarRemote.new({})
r5.handle_received(:reset)
r5.handle_received([4])
r5.handle_received([0, 2, 0])
r5.instance_variable_set(:@initial_intent_mode, :present_empty)
r5.handle_received(OFF_STATE)
r5.send_intent({ 'input' => 'analog' })
queue_strings = []
begin
  loop do
    q = r5.pop
    break unless q
    queue_strings << q.bytes.map { |b| '%02x' % b }.join
  end
rescue ThreadError
end
sent_power_on = queue_strings.any? { |s| s.include?('40787e') }
if sent_power_on
  puts "OK  manage_power=true preserves legacy auto-power-on"
else
  puts "FAIL manage_power=true lost auto-power-on: #{queue_strings.inspect}"
  failures << 'manage_power=true legacy'
end

# --- 7. Initial-intent modes are reachable ---
modes = {
  :absent         => { 'controller' => {} },
  :present_empty  => { 'controller' => { 'initial_intent' => {} } },
  :configured     => { 'controller' => { 'initial_intent' => { 'clearvoice' => false } } },
}
modes.each do |expected, cfg|
  rr = YamahaSoundbarRemote.new(cfg)
  if rr.initial_intent_mode == expected
    puts "OK  tri-state #{expected}"
  else
    puts "FAIL tri-state #{expected}: got #{rr.initial_intent_mode.inspect}"
    failures << "tri-state #{expected}"
  end
end

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
