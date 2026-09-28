#!/usr/bin/env bash
# Smoke test: staged session restore phase machine.
# Runs on any host with Ruby (no serial port, no YAS required).
#
# Drives the controller through a synthetic end-to-end sequence:
#
#   sync -> device-status (TV) -> start_session (analog) ->
#   device-status (TV again, snapshot captures pre-session state) ->
#   device-status (analog, music applied) -> stop_session ->
#   staged restore -> mute -> volume -> sound -> input -> final_mute
#
# Verifies each phase advances at the right barrier and that the
# final state reports session.active=false, session.restoring=false,
# session.restore_phase=nil, and the persistent snapshot is removed.

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

ruby -I"$TMPSTUB" -I"$REPO_ROOT/control" <<RUBY
require_relative '$REPO_ROOT/control/control'
failures = []

# Synthetic device-state packet bytes for the YAS-207 0x05 reply:
#   pkt[0]=5 status type
#   pkt[2]=power (1=on)
#   pkt[3]=input byte (7=tv, 0xc=analog, 0x5=bluetooth, 0=hdmi)
#   pkt[4]=mute (1=on)
#   pkt[5]=volume
#   pkt[6]=subwoofer
#   pkt[10..11]=surround (lo+hi; 0x0a=tv)
#   pkt[12]=bass_ext/clearvoice flags

TV_STATE      = [5, 1, 1, 0x7, 0, 10, 16, 0, 0, 0, 0, 0x0a, 0]
MUSIC_STATE   = [5, 1, 1, 0xc, 0, 20, 16, 0, 0, 0, 0, 0x0a, 0]
MUTED_MUSIC   = [5, 1, 1, 0xc, 1, 20, 16, 0, 0, 0, 0, 0x0a, 0]
RESTORED_TV   = [5, 1, 1, 0x7, 0, 10, 16, 0, 0, 0, 0, 0x0a, 0]

r = YamahaSoundbarRemote.new

# Sync
r.handle_received(:reset)
r.handle_received([4])
r.handle_received([0, 2, 0])

# First 0x05: TV state. INITIAL_INTENT applied.
r.handle_received(TV_STATE)

# Start music session: switch input to analog, raise volume to 20.
r.start_session('music', {'input' => 'analog', 'volume' => 20})

# Second 0x05: device still at TV (commands not yet applied).
# This is the snapshot barrier.
r.handle_received(TV_STATE)
saved_mute = r.session.last[:mute]
saved_volume = r.session.last[:volume]
saved_input = r.session.last[:input]

if saved_mute == false && saved_volume == 10 && saved_input == :tv
  puts "OK  pre-session snapshot captured: mute=#{saved_mute} vol=#{saved_volume} input=#{saved_input}"
else
  puts "FAIL pre-session snapshot: mute=#{saved_mute} vol=#{saved_volume} input=#{saved_input}"
  failures << 'pre-session snapshot'
end

# Third 0x05: music state applied. snapshot_recovered ran on first reply.
r.handle_received(MUSIC_STATE)

if r.session && r.session.first == 'music'
  puts "OK  session active after music applied"
else
  puts "FAIL session not active"
  failures << 'session active'
end

# Stop the session.
r.stop_session('music')
# Status reply carrying stop_session intent.
r.handle_received(MUSIC_STATE)

if r.restore_phase == :mute
  puts "OK  staged restore began at :mute"
else
  puts "FAIL staged restore phase: got #{r.restore_phase.inspect}"
  failures << 'restore phase'
end

if r.restoring_session
  puts "OK  restoring_session flag set"
else
  puts "FAIL restoring_session flag"
  failures << 'restoring_session flag'
end

if r.deferred_final_mute == saved_mute
  puts "OK  deferred_final_mute matches saved state"
else
  puts "FAIL deferred_final_mute: #{r.deferred_final_mute.inspect} vs #{saved_mute.inspect}"
  failures << 'deferred_final_mute'
end

# Mute phase: device at unmuted music state; first reply needs another
# mute_on + report_status cycle before mute is confirmed.
r.handle_received(MUSIC_STATE)        # mute phase: emit mute_on + status
r.handle_received(MUTED_MUSIC)        # mute confirmed -> advance to :volume

if r.restore_phase == :volume
  puts "OK  advanced to :volume after mute confirmation"
else
  puts "FAIL advance to :volume: #{r.restore_phase.inspect}"
  failures << 'advance to :volume'
end

# Volume phase: device at vol=20 muted. Emit volume_down*10 + report_volume.
r.handle_received(MUTED_MUSIC)
# 0x12 reply at vol=10, mute=true -> advance to :sound.
r.handle_received([0x12, 1, 10])

if r.restore_phase == :sound
  puts "OK  advanced to :sound after volume verification"
else
  puts "FAIL advance to :sound: #{r.restore_phase.inspect}"
  failures << 'advance to :sound'
end

# Sound phase: device at music state already (sub, surround, clearvoice, bass_ext
# all match saved). First reply triggers another status refresh.
r.handle_received(MUSIC_STATE)        # sound phase: report_status
r.handle_received(MUSIC_STATE)        # sound phase: delta empty -> :input

if r.restore_phase == :input
  puts "OK  advanced to :input after sound convergence"
else
  puts "FAIL advance to :input: #{r.restore_phase.inspect}"
  failures << 'advance to :input'
end

# Input phase: device at analog, target tv. Force readback first.
r.handle_received(MUSIC_STATE)        # input phase: report_status
r.handle_received(MUSIC_STATE)        # input phase: delta remains -> emit set_input_tv
r.handle_received(RESTORED_TV)        # input switched -> advance to :final_mute

if r.restore_phase == :final_mute
  puts "OK  advanced to :final_mute after input switch"
else
  puts "FAIL advance to :final_mute: #{r.restore_phase.inspect}"
  failures << 'advance to :final_mute'
end

# Final mute phase: device at TV state. Force readback first.
r.handle_received(RESTORED_TV)        # final_mute: emit report_volume
# 0x12 reply: vol=10, mute=false (deferred_final_mute was saved_mute=false)
r.handle_received([0x12, 0, 10])

if !r.restoring_session && r.restore_phase.nil? && r.restore_error.nil?
  puts "OK  staged restore fully settled"
else
  puts "FAIL restore not settled: restoring=#{r.restoring_session} phase=#{r.restore_phase.inspect} error=#{r.restore_error.inspect}"
  failures << 'restore settled'
end

if r.session.nil?
  puts "OK  @session cleared after settle"
else
  puts "FAIL session not cleared: #{r.session.inspect}"
  failures << 'session cleared'
end

if !File.exist?(r.snapshot_path)
  puts "OK  snapshot removed after settle"
else
  puts "FAIL snapshot still present"
  failures << 'snapshot removed'
end

# /state endpoint shape -- verify the keys/structure directly.
# (We do not bind to a TCP port here; just call the documented fields.)
state_keys = r.device_state.keys.sort
if state_keys == [:bass_ext, :clearvoice, :input, :mute, :power, :subwoofer, :surround, :volume]
  puts "OK  device_state keys complete"
else
  puts "FAIL device_state keys: #{state_keys.inspect}"
  failures << 'device_state keys'
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
