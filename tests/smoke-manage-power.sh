#!/usr/bin/env bash
# Smoke test: manage_power gating (legacy auto power-on path).
# Runs on any host with Ruby (no serial port, no YAS-207 required).
#
# Verifies the documented backwards-compatibility contract:
#   - manage_power absent => manage_power=true (upstream legacy behaviour).
#   - manage_power=true: parse_intent keeps :power and enforce_intent
#     auto-powers the device on when it is off.
#   - manage_power=false: parse_intent strips :power and enforce_intent
#     never issues power_on; while the device is off it enqueues NO
#     sound-setting commands (the pending intent is deferred and enforced
#     once the device reports power=true).
#   - initial_intent tri-state is reachable.

set -u

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
export REPO_ROOT

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

ruby -I"$TMPSTUB" -I"$REPO_ROOT/control" <<'RUBY'
require_relative File.join(ENV.fetch('REPO_ROOT'), 'control', 'control')
Thread.report_on_exception = true

failures = []

def hex(s); s.bytes.map { |b| '%02x' % b }.join; end

def drain_queue(r)
  q = []
  loop do
    p = r.pop
    break unless p
    q << hex(p)
  end
  q
end

# Synthetic device-status packet: power=off, input=tv, vol=10.
TV_OFF = [5, 1, 0, 0x7, 0, 10, 16, 0, 0, 0, 0, 0x0a, 0]

def sync_off(r)
  r.handle_received(:reset)
  r.handle_received([4])
  r.handle_received([0, 2, 0])
  r.handle_received(TV_OFF)
end

# --- 1. manage_power absent => legacy default true ---
r1 = YamahaSoundbarRemote.new({})
if r1.manage_power == true
  puts "OK  default manage_power=true (legacy)"
else
  puts "FAIL manage_power default: #{r1.manage_power.inspect}"
  failures << 'manage_power default'
end

# --- 2. Configured manage_power=false ---
r2 = YamahaSoundbarRemote.new({'controller' => {'manage_power' => false, 'initial_intent' => {}}})
if r2.manage_power == false
  puts "OK  configured manage_power=false"
else
  puts "FAIL manage_power=false: #{r2.manage_power.inspect}"
  failures << 'manage_power=false'
end

# --- 3. parse_intent strips :power when manage_power=false ---
intent = r2.__send__(:parse_intent, {'power' => true, 'volume' => 10})
if !intent.key?(:power) && intent[:volume] == 10
  puts "OK  parse_intent strips :power when manage_power=false"
else
  puts "FAIL parse_intent strips :power: #{intent.inspect}"
  failures << 'parse_intent strips :power'
end

# --- 4. parse_intent preserves :power when manage_power=true ---
r3 = YamahaSoundbarRemote.new({'controller' => {'initial_intent' => {}}})
intent = r3.__send__(:parse_intent, {'power' => true, 'volume' => 10})
if intent[:power] == true && intent[:volume] == 10
  puts "OK  parse_intent preserves :power when manage_power=true"
else
  puts "FAIL parse_intent preserves :power: #{intent.inspect}"
  failures << 'parse_intent preserves :power'
end

# --- 5. manage_power=false: device off -> no power_on and NO
#        sound-setting commands at all; the intent survives and is
#        enforced once the device reports power=true. ---
r4 = YamahaSoundbarRemote.new({'controller' => {'manage_power' => false, 'initial_intent' => {}}})
sync_off(r4)
r4.send_intent({'input' => 'analog'})
r4.handle_received(TV_OFF)  # next status report: still off
sent = drain_queue(r4)
intent = r4.instance_variable_get(:@intent)
if !sent.any? { |s| s.include?('40787e') } &&
   !sent.any? { |s| s.include?('4078d1') } &&
   intent[:input] == :analog
  # Device powers on: the pending intent must now be enforced.
  r4.handle_received([5, 1, 1, 0x7, 0, 10, 16, 0, 0, 0, 0, 0x0a, 0])  # on, input=tv
  sent = drain_queue(r4)
  if !sent.any? { |s| s.include?('40787e') } &&
     sent.any? { |s| s.include?('4078d1') }
    puts "OK  manage_power=false: no power_on, no off-device sound commands; deferred intent enforced on power-up"
  else
    puts "FAIL manage_power=false deferred intent on power-up: #{sent.inspect}"
    failures << 'manage_power=false deferred intent'
  end
else
  puts "FAIL manage_power=false off-device: sent=#{sent.inspect} intent=#{intent.inspect}"
  failures << 'manage_power=false skips auto-power-on'
end

# --- 6. manage_power=true (legacy): power_on IS emitted ---
r5 = YamahaSoundbarRemote.new({'controller' => {'initial_intent' => {}}})
sync_off(r5)
r5.send_intent({'input' => 'analog'})
r5.handle_received(TV_OFF)  # next status report triggers enforcement
sent = drain_queue(r5)
if sent.any? { |s| s.include?('40787e') }
  puts "OK  manage_power=true preserves legacy auto-power-on"
else
  puts "FAIL manage_power=true lost auto-power-on: #{sent.inspect}"
  failures << 'manage_power=true legacy'
end

# --- 7. initial_intent tri-state reachable ---
modes = {
  :absent         => {},
  :present_empty  => {'controller' => {'initial_intent' => {}}},
  :configured     => {'controller' => {'initial_intent' => {'clearvoice' => false}}},
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
