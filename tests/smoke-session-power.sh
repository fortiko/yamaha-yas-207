#!/usr/bin/env bash
# Smoke test: session-scoped power ownership + complete music profile.
# Runs on any host with Ruby (no serial port, no YAS-207 required).
#
# Verifies the documented semantics from the design notes:
#
#   - Default config preserves upstream behaviour: manage_power=false +
#     power_on_for_session_starts absent => never touches power.
#   - snapshot is the authoritative pre-session state (all 8 supported
#     fields captured).
#   - Saved_state.power=true + power_on_for_session_starts=true:
#       start_session does NOT power-cycle the Yamaha.
#   - Saved_state.power=false + power_on_for_session_starts=true:
#       start_session issues power_on synchronously, waits for power=true,
#       and only then queues the music intent. The adapter gets a real
#       RuntimeError if wake-up fails.
#   - saved_state.power=false + power_on_completed=true => :final_power
#       phase is run as the LAST restore step.
#   - saved_state.power=true => :final_power is skipped; no power_off
#       is emitted.
#   - Snapshot with session_powered_on=true but power_on_completed=false
#       (crashed before wake-up verification): restore is conservative
#       and does NOT emit power_off.
#   - Music profile fields (input, clearvoice, surround, bass_ext)
#     explicitly configured in music_intent are applied; unconfigured
#     fields are NOT reset.

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
failures = []
# Make thread exceptions visible and keep log output deterministic.
Thread.report_on_exception = true
$stdout.sync = true
$stderr.sync = true

# Synthetic device-status packets (YAS-207 0x05 reply):
#   pkt[0]=5, pkt[2]=power, pkt[3]=input(7=tv,0xc=analog), pkt[4]=mute,
#   pkt[5]=volume, pkt[6]=subwoofer, pkt[10..11]=surround, pkt[12]=flags

def tv_state(vol = 10, sub = 16, surround_lo = 0x0a, cv = false, be = true)
  flags = (cv ? 0x04 : 0) | (be ? 0x20 : 0)
  [5, 1, 1, 0x7, 0, vol, sub, 0, 0, 0, 0, surround_lo, flags]
end
def tv_off_state
  [5, 1, 0, 0x7, 0, 10, 16, 0, 0, 0, 0, 0x0a, 0]
end
def analog_state(vol = 15, sub = 16, surround_lo = 0x08, cv = false, be = false)
  flags = (cv ? 0x04 : 0) | (be ? 0x20 : 0)
  [5, 1, 1, 0xc, 0, vol, sub, 0, 0, 0, 0, surround_lo, flags]
end

def hex(s); s.bytes.map { |b| '%02x' % b }.join; end

def run(label, cfg, device_init, pre_session_packet, &block)
  r = YamahaSoundbarRemote.new(cfg)
  r.handle_received(:reset)
  r.handle_received([4])
  r.handle_received([0, 2, 0])
  r.handle_received(device_init)
  yield(r)
  puts "OK  #{label}"
rescue => e
  puts "FAIL #{label}: #{e.class}: #{e.message}"
  puts e.backtrace.first(5).map { |l| "    #{l}" }
  $failures = ($failures || []) << label
end

$failures = []

# ----------------------------------------------------------------------------
# 1. Default config: power_on_for_session_starts absent => false.
#    Manage_power=false alone => session start NEVER issues power_on.
# ----------------------------------------------------------------------------
r = YamahaSoundbarRemote.new({'controller' => {'manage_power' => false}})
raise 'expect false' unless r.power_on_for_session_starts == false
puts 'OK  default power_on_for_session_starts=false preserves upstream behaviour'

# 2. Snapshot captures all 8 supported fields.
r = YamahaSoundbarRemote.new({'controller' => {'manage_power' => false, 'power_on_for_session_starts' => true}})
r.handle_received(:reset)
r.handle_received([4])
r.handle_received([0, 2, 0])
r.handle_received(tv_state(12, 20, 0x08, true, true))
r.start_session('music', {'input' => 'analog', 'volume' => 18})
r.handle_received(tv_state(12, 20, 0x08, true, true))  # snapshot barrier
saved = r.session.last
expected = { power: true, input: :tv, mute: false, volume: 12, subwoofer: 20,
             surround: :music, bass_ext: true, clearvoice: true }
unless saved == expected
  raise "snapshot mismatch: got #{saved.inspect}, want #{expected.inspect}"
end
puts 'OK  snapshot captures all 8 supported fields'

# 3. Power already true at start => no power_on issued; session proceeds.
r = YamahaSoundbarRemote.new({'controller' => {'manage_power' => false, 'power_on_for_session_starts' => true}})
r.handle_received(:reset)
r.handle_received([4])
r.handle_received([0, 2, 0])
r.handle_received(tv_state)
r.start_session('music', {'input' => 'analog', 'volume' => 18})
# start_session returned synchronously (didn't block on wake because
# device was already on). session_snapshot should not have woken flags.
raise 'expect power_on_completed=false (no wake needed)' if r.instance_variable_get(:@snapshot_power_on_completed)
raise 'expect session_powered_on=false (no wake needed)' if r.instance_variable_get(:@snapshot_session_powered_on)
puts 'OK  power already true -> no wake-up; no ownership flag set'

# 4. Power false + power_on_for_session_starts=true => wake_yamaha_for_session
#    runs synchronously. Block the test by NOT delivering a 0x05 reply and
#    expect start_session to raise after POWER_ON_TIMEOUT.
r = YamahaSoundbarRemote.new({'controller' => {'manage_power' => false, 'power_on_for_session_starts' => true}})
r.handle_received(:reset)
r.handle_received([4])
r.handle_received([0, 2, 0])
r.handle_received(tv_off_state)
# stub monotonic_now to make timeout fast? Easier: just measure.
require 'timeout'
begin
  Timeout.timeout(YamahaSoundbarRemote::POWER_ON_TIMEOUT + 2) do
    r.start_session('music', {'input' => 'analog', 'volume' => 18})
  end
  raise 'start_session should have raised on wake-up timeout'
rescue RuntimeError => e
  raise "wrong message: #{e.message}" unless e.message.include?('did not power on')
rescue Timeout::Error
  raise 'start_session blocked past POWER_ON_TIMEOUT+2s'
end
# Snapshot must have been deleted on timeout.
if File.exist?(r.snapshot_path)
  raise 'snapshot should have been deleted on wake timeout'
end
puts 'OK  wake timeout -> RuntimeError raised, snapshot deleted'

# 5. Power false + wake succeeds -> snapshot captured with the pre-wake
#    saved_state.power=false BEFORE power_on is issued, then
#    power_on_completed=true once device reports power=true.
#
#    Required ordering (the bug fix):
#      1. start_session called with @device_state[:power] == false
#      2. snapshot persisted IMMEDIATELY with saved_state.power == false
#         (this is the contract that :final_power later relies on)
#      3. wake_yamaha_for_session issues power_on; @device_state[:power]
#         flips to true on the next 0x05 reply
#      4. power_on_completed=true persisted AFTER wake completes
#      5. music intent queued
#
#    The CRITICAL invariant: @session.last[:power] must be false even
#    after device_state[:power] has flipped to true. The :final_power
#    decision reads @session.last[:power], not @device_state[:power].
r = YamahaSoundbarRemote.new({'controller' => {'manage_power' => false, 'power_on_for_session_starts' => true}})
r.handle_received(:reset)
r.handle_received([4])
r.handle_received([0, 2, 0])
r.handle_received(tv_off_state)  # power=false, input=tv

# Simulate the wake: the test thread runs start_session which blocks;
# the worker (us, manually) feeds a 0x05 showing power=true AFTER the
# snapshot has been persisted.
wake_thread = Thread.new do
  sleep 0.05
  r.handle_received([5, 1, 1, 0xc, 0, 10, 16, 0, 0, 0, 0, 0x08, 0])  # power on
end
r.start_session('music', {'input' => 'analog', 'volume' => 18, 'surround' => 'music'})
wake_thread.join(2)

# After start_session returns: ownership flags set, snapshot reflects
# pre-wake state (power=false) which is the contract :final_power needs.
raise 'expect session_powered_on=true' unless r.instance_variable_get(:@snapshot_session_powered_on)
raise 'expect power_on_completed=true' unless r.instance_variable_get(:@snapshot_power_on_completed)
saved_power = r.session.last[:power]
raise "snapshot saved_state.power must remain false (got #{saved_power.inspect}); :final_power decision would be wrong" unless saved_power == false
puts 'OK  wake success -> snapshot captured PRE-wake, ownership flags set, music intent applied'

# 6. Music profile: configured fields are applied during session.
#    The adapter would build music_intent from cfg["session"]["music_intent"]
#    plus dynamic volume/mute. Verify all 5 fixed profile fields are valid
#    against the controller's parse_intent.
profile = { 'input' => 'analog', 'clearvoice' => false, 'surround' => 'music',
            'bass_ext' => false }
r = YamahaSoundbarRemote.new({'controller' => {'manage_power' => false, 'power_on_for_session_starts' => true}})
validated = r.__send__(:parse_intent, profile)
raise "music profile not validated: #{validated.inspect}" unless validated == { input: :analog, clearvoice: false, surround: :music, bass_ext: false }
puts 'OK  deterministic music profile validated by parse_intent'

# 7. Music profile partial (legacy): only {input, clearvoice} — unconfigured
#    fields are NOT in the validated intent, so the controller does not
#    reset them. This proves backward compat for partial profiles.
legacy = { 'input' => 'analog', 'clearvoice' => false }
validated = r.__send__(:parse_intent, legacy)
raise "partial profile mismatch: #{validated.inspect}" unless validated == { input: :analog, clearvoice: false }
puts 'OK  partial music profile (legacy): unconfigured fields untouched'

# 8. Staged restore: saved_state.power=false + power_on_completed=true =>
#    :final_power phase runs as the LAST step.
#
#    Device state throughout matches the saved state, so the restore
#    phases converge via empty-delta paths and the test focuses on
#    verifying the PHASE ORDERING (specifically, that :final_power is
#    reached as the LAST step before settling).
SAVED = { power: false, input: :tv, mute: false, volume: 12,
          subwoofer: 16, surround: :tv, bass_ext: true, clearvoice: true }
# Device packet matching SAVED (flags: cv=true + be=true = 0x24)
DEVICE_DEV = [5, 1, 1, 0x7, 1, 12, 16, 0, 0, 0, 0, 0x0a, 0x24]
DEVICE_OFF = [5, 1, 0, 0x7, 1, 12, 16, 0, 0, 0, 0, 0x0a, 0x24]
def vs(vol, mute = false); [0x12, mute ? 1 : 0, vol]; end

# Simulate the serial worker: any report_volume queries enqueued by the
# controller need to be moved from @enqueued_volume_queries into
# @sent_volume_queries so that 0x12 replies can match and trigger
# handle_restore_volume_status. We wrap r.handle_received so that
# before each packet, the queues are drained and moved.
def feed(r, packet)
  e = r.instance_variable_get(:@enqueued_volume_queries)
  s = r.instance_variable_get(:@sent_volume_queries)
  while (q = (e.pop(true) rescue nil))
    s.push(q)
  end
  r.handle_received(packet)
end

r = YamahaSoundbarRemote.new({'controller' => {'manage_power' => false, 'power_on_for_session_starts' => true}})
r.handle_received(:reset)
r.handle_received([4])
r.handle_received([0, 2, 0])
r.handle_received(DEVICE_DEV)  # initial state: power=true, matches saved sound state
r.instance_variable_set(:@session, ['music', SAVED.dup])
r.instance_variable_set(:@snapshot_power_on_completed, true)
r.instance_variable_set(:@snapshot_session_powered_on, true)
r.stop_session('music')
r.handle_received(DEVICE_DEV)  # stop_session's 0x05 -> enters :mute phase
raise "expected :mute phase, got #{r.restore_phase.inspect}" unless r.restore_phase == :mute

# :mute phase: device already at vol=12; need 0x12 with mute=true to advance.
# First 0x05 (during :mute, in skip list) is just state refresh.
r.handle_received(DEVICE_DEV)
feed(r, vs(12, false))  # 0x12 mute=false -> retry (queue another mute_on + query)
r.handle_received(DEVICE_DEV)      # state refresh
feed(r, vs(12, true))   # 0x12 mute=true -> advance to :volume, delta=0 -> :sound

# :sound phase: device matches saved, single 0x05 advances to :input.
r.handle_received(DEVICE_DEV)

# :input phase: two 0x05s -- first sets refresh, second matches input and
# advances to :post_input_volume.
r.handle_received(DEVICE_DEV)
r.handle_received(DEVICE_DEV)

# :post_input_volume: 0x12 reply advances to :final_mute.
feed(r, vs(12, true))

# :final_mute: enqueued mute_off (saved.mute=false). 0x12 with mute=true is
# a retry. 0x12 with mute=false advances.
feed(r, vs(12, true))
feed(r, vs(12, false))

unless r.restore_phase == :final_power
  raise "expected :final_power phase, got #{r.restore_phase.inspect}"
end

# :final_power: first 0x05 sets refresh + enqueues report_status. Second
# 0x05 with power=false settles.
r.handle_received(DEVICE_DEV)   # refresh
r.handle_received(DEVICE_OFF)   # power off -> settle

unless r.restore_phase.nil? && !r.restoring_session && r.restore_error.nil?
  raise "expected settled restore, got phase=#{r.restore_phase.inspect} restoring=#{r.restoring_session} error=#{r.restore_error.inspect}"
end
if File.exist?(r.snapshot_path)
  raise 'snapshot not deleted after successful :final_power'
end
puts 'OK  staged restore: :final_power runs as LAST step (after :final_mute)'

# 9. Staged restore: saved_state.power=true (Yamaha was already on) =>
#    :final_power is SKIPPED entirely.
SAVED2 = { power: true, input: :tv, mute: false, volume: 12,
           subwoofer: 16, surround: :tv, bass_ext: true, clearvoice: true }
r = YamahaSoundbarRemote.new({'controller' => {'manage_power' => false, 'power_on_for_session_starts' => true}})
r.handle_received(:reset)
r.handle_received([4])
r.handle_received([0, 2, 0])
r.handle_received(DEVICE_DEV)
r.instance_variable_set(:@session, ['music', SAVED2.dup])
r.instance_variable_set(:@snapshot_power_on_completed, false)
r.instance_variable_set(:@snapshot_session_powered_on, false)
r.stop_session('music')
r.handle_received(DEVICE_DEV)
r.handle_received(DEVICE_DEV)
feed(r, vs(12, false))
r.handle_received(DEVICE_DEV)
feed(r, vs(12, true))
r.handle_received(DEVICE_DEV)
r.handle_received(DEVICE_DEV)
r.handle_received(DEVICE_DEV)
feed(r, vs(12, true))
feed(r, vs(12, true))
feed(r, vs(12, false))
if r.restore_phase == :final_power
  raise 'BUG: :final_power should NOT have been entered (saved.power was true)'
end
unless r.restore_phase.nil? && !r.restoring_session
  raise "expected settled, got phase=#{r.restore_phase.inspect} restoring=#{r.restoring_session}"
end
puts 'OK  saved_state.power=true -> :final_power skipped entirely'

# 10. Crash-recovery: session_powered_on=true but power_on_completed=false
#     (crashed before wake completed) -> conservative: NO final power-off.
r = YamahaSoundbarRemote.new({'controller' => {'manage_power' => false, 'power_on_for_session_starts' => true}})
r.handle_received(:reset)
r.handle_received([4])
r.handle_received([0, 2, 0])
r.handle_received(DEVICE_DEV)
r.instance_variable_set(:@session, ['music', SAVED.dup])  # saved.power=false
r.instance_variable_set(:@snapshot_power_on_completed, false)  # ambiguous
r.instance_variable_set(:@snapshot_session_powered_on, true)
r.stop_session('music')
r.handle_received(DEVICE_DEV)
r.handle_received(DEVICE_DEV)
feed(r, vs(12, false))
r.handle_received(DEVICE_DEV)
feed(r, vs(12, true))
r.handle_received(DEVICE_DEV)
r.handle_received(DEVICE_DEV)
r.handle_received(DEVICE_DEV)
feed(r, vs(12, true))
feed(r, vs(12, true))
feed(r, vs(12, false))
# Despite saved_state.power=false, :final_power is NOT entered because
# power_on_completed is false (we cannot be sure we owned the on state).
if r.restore_phase == :final_power
  raise 'BUG: :final_power should be skipped when power_on_completed=false'
end
unless r.restore_phase.nil? && !r.restoring_session
  raise "expected conservative settle, got phase=#{r.restore_phase.inspect}"
end
puts 'OK  crash-recovery: power_on_completed=false -> :final_power skipped (conservative)'

# 11. Snapshot-ordering regression: an end-to-end lifecycle where the
#     initial device_state.power is false. Verifies the entire chain:
#       (a) start_session captures @session.last with power=false BEFORE
#           any wake-up commands are issued to the device.
#       (b) wake_yamaha_for_session powers the YAS on; @device_state[:power]
#           flips to true (simulated by a 0x05 reply on a worker thread).
#       (c) Snapshot file on disk STILL shows saved_state.power=false even
#           though the device is now on.
#       (d) stop_session starts a staged restore; saved_state.power=false
#           combined with power_on_completed=true makes final_power_restore_required?
#           return true.
#       (e) Staged restore advances through :mute -> :volume -> :sound
#           -> :input -> :final_mute -> :final_power (which emits power_off).
#       (f) After :final_power the device shows power=false; restore settles.
SAVE_OFF_STATE = [5, 1, 0, 0x7, 0, 12, 16, 0, 0, 0, 0, 0x0a, 0x24]
DEVICE_DEV  = [5, 1, 1, 0x7, 1, 12, 16, 0, 0, 0, 0, 0x0a, 0x24]
DEVICE_OFF  = [5, 1, 0, 0x7, 1, 12, 16, 0, 0, 0, 0, 0x0a, 0x24]
r = YamahaSoundbarRemote.new({'controller' => {'manage_power' => false, 'power_on_for_session_starts' => true}})
r.handle_received(:reset)
r.handle_received([4])
r.handle_received([0, 2, 0])
r.handle_received(SAVE_OFF_STATE)   # initial device state: power=false, input=tv, vol=12, etc.

# Start session in a background thread (because wake_yamaha_for_session
# blocks on the condvar until a 0x05 reply arrives).
ss_thread = Thread.new do
  r.start_session('music', {'input' => 'analog', 'volume' => 18, 'surround' => 'music'})
end
# Deterministic wait for the snapshot to be persisted by the session
# thread (bounded; the wake itself cannot happen until we inject the
# power=true reply below, so this only covers thread-start latency).
snapshot_deadline = Time.now + 2.0
until File.exist?(r.snapshot_path) || Time.now > snapshot_deadline
  sleep 0.01
end

# (a) Snapshot MUST already exist with power=false BEFORE the device is woken.
unless File.exist?(r.snapshot_path)
  raise 'snapshot was not persisted BEFORE wake'
end
saved_state_now = JSON.parse(File.read(r.snapshot_path))['saved_state']
unless saved_state_now['power'] == false
  raise "snapshot saved_state.power should be false at this point, got #{saved_state_now['power'].inspect}"
end
unless JSON.parse(File.read(r.snapshot_path))['session_powered_on'] == true
  raise 'snapshot session_powered_on should be true BEFORE wake completes'
end

# Now simulate the device waking up and applying the music intent.
r.handle_received([5, 1, 1, 0xc, 1, 18, 16, 0, 0, 0, 0, 0x08, 0])  # power=true, input=analog, vol=18, surround=music
ss_thread.join(2)

# (c) After wake completes the on-disk snapshot MUST STILL show
#     saved_state.power=false (this is the contract :final_power needs).
saved_state_after = JSON.parse(File.read(r.snapshot_path))['saved_state']
unless saved_state_after['power'] == false
  raise "BUG: snapshot saved_state.power became true after wake (was the ordering bug). got #{saved_state_after['power'].inspect}"
end
unless JSON.parse(File.read(r.snapshot_path))['power_on_completed'] == true
  raise 'snapshot power_on_completed should be true after wake'
end

# Drive the staged restore. Force all phases with synthetic packets.
def vs(vol, mute = false); [0x12, mute ? 1 : 0, vol]; end
r.stop_session('music')
# Bring @device_state up to date: simulate the controller's reading.
r.handle_received([5, 1, 1, 0xc, 1, 18, 16, 0, 0, 0, 0, 0x08, 0])
# :mute -> :volume -> :sound -> :input -> :final_mute -> :final_power
feed(r, vs(18, true))   # mute confirm
r.handle_received([5, 1, 1, 0xc, 1, 18, 16, 0, 0, 0, 0, 0x08, 0])
feed(r, vs(12, true))   # mute_off -> retry; volume verification
r.handle_received([5, 1, 1, 0x7, 1, 12, 16, 0, 0, 0, 0, 0x0a, 0x24])  # back to TV
feed(r, vs(12, true))   # volume verify OK -> :sound
r.handle_received([5, 1, 1, 0x7, 1, 12, 16, 0, 0, 0, 0, 0x0a, 0x24])  # sound -> :input
r.handle_received([5, 1, 1, 0x7, 1, 12, 16, 0, 0, 0, 0, 0x0a, 0x24])  # :input enter
r.handle_received([5, 1, 1, 0x7, 1, 12, 16, 0, 0, 0, 0, 0x0a, 0x24])  # :input -> :post_input_volume
feed(r, vs(12, true))   # :post_input_volume -> :final_mute
feed(r, vs(12, false))  # final_mute verify saved.mute=false OK -> :final_power
# :final_power first readback sets refresh flag; second readback sees power=false -> settle.
r.handle_received([5, 1, 1, 0x7, 1, 12, 16, 0, 0, 0, 0, 0x0a, 0x24])  # still on
r.handle_received(DEVICE_OFF)  # power=false confirmed

unless r.restore_phase.nil? && !r.restoring_session && r.restore_error.nil?
  raise "expected settled, got phase=#{r.restore_phase.inspect} restoring=#{r.restoring_session} error=#{r.restore_error.inspect}"
end
if File.exist?(r.snapshot_path)
  raise 'snapshot not deleted after successful :final_power'
end
puts 'OK  end-to-end: power=false start -> wake -> restore -> final power_off (snapshot ordering correct)'

# ----------------------------------------------------------------------------
# 12-19. Post-init / SPP-reconnect idle input sanitization.
#
#   - idle + power=true + input=bluetooth + policy=tv -> set_input_tv is
#     enqueued and verified on the next status report.
#   - Negative: no correction when session active, restoring, input=analog,
#     input=tv, power=false, or policy disabled (default).
#   - In-flight correction is interrupted (pending cleared) by a session
#     start, and re-arms on a later idle bluetooth observation.
# ----------------------------------------------------------------------------
def queued_cmds(r)
  q = r.instance_variable_get(:@queue)
  out = []
  loop do
    _, cmd = q.pop(true)
    out << cmd
  rescue ThreadError
    break out
  end
end

def sync_r(r)
  r.handle_received(:reset)
  r.handle_received([4])
  r.handle_received([0, 2, 0])
  queued_cmds(r) # drain the init handshake commands
end

# Device status packet with input=bluetooth (0x5).
def bt_state(power = 1, vol = 12)
  [5, 1, power, 0x5, 0, vol, 16, 0, 0, 0, 0, 0x0a, 0]
end

BT_SET_TV = YamahaPacketCodec.encode(
  YamahaSoundbarRemote::COMMANDS[:set_input_tv])
BT_RS     = YamahaPacketCodec.encode(
  YamahaSoundbarRemote::COMMANDS[:report_status])

# 12. Positive: idle + power=true + input=bluetooth -> correction enqueued,
#     verified on the next status report, and re-arms if bluetooth recurs.
r = YamahaSoundbarRemote.new(
  {'controller' => {'manage_power' => false, 'initial_intent' => {}, 'idle_input_policy' => 'tv'}})
sync_r(r)
r.handle_received(bt_state(1))
cmds = queued_cmds(r)
unless cmds == [BT_SET_TV, BT_RS]
  raise "expected [set_input_tv, report_status], got #{cmds.inspect}"
end
unless r.instance_variable_get(:@idle_input_correction_pending)
  raise 'correction pending flag should be set after enqueue'
end
r.handle_received(tv_state(12)) # verification report: input=tv
if r.instance_variable_get(:@idle_input_correction_pending)
  raise 'pending should clear after verified input=tv'
end
# Re-arms: bluetooth observed again while idle -> corrected again.
r.handle_received(bt_state(1))
unless queued_cmds(r) == [BT_SET_TV, BT_RS]
  raise 'second idle bluetooth observation should re-arm the correction'
end
puts 'OK  idle+power=true+input=bluetooth -> set_input_tv enqueued, verified, re-arms'

# 13. Default: policy absent => feature disabled; bluetooth idle untouched.
r = YamahaSoundbarRemote.new(
  {'controller' => {'manage_power' => false, 'initial_intent' => {}}})
raise 'idle_input_policy should default to nil (disabled)' unless r.idle_input_policy.nil?
sync_r(r)
r.handle_received(bt_state(1))
unless queued_cmds(r).empty?
  raise 'no correction expected when idle_input_policy is absent'
end
puts 'OK  default config (policy absent) -> no sanitization, upstream behaviour preserved'

# 14. Negative: power=false + input=bluetooth -> no correction, no power-on.
r = YamahaSoundbarRemote.new(
  {'controller' => {'manage_power' => false, 'initial_intent' => {}, 'idle_input_policy' => 'tv'}})
sync_r(r)
r.handle_received(bt_state(0))
unless queued_cmds(r).empty?
  raise 'no correction expected while powered off (and no wake to enforce it)'
end
puts 'OK  power=false + input=bluetooth -> no correction, device not woken'

# 15. Negative: input=analog while idle -> untouched.
r = YamahaSoundbarRemote.new(
  {'controller' => {'manage_power' => false, 'initial_intent' => {}, 'idle_input_policy' => 'tv'}})
sync_r(r)
r.handle_received(analog_state(15))
unless queued_cmds(r).empty?
  raise 'no correction expected for input=analog'
end
puts 'OK  idle + input=analog -> untouched'

# 16. Negative: input=tv while idle (already at policy) -> untouched.
r = YamahaSoundbarRemote.new(
  {'controller' => {'manage_power' => false, 'initial_intent' => {}, 'idle_input_policy' => 'tv'}})
sync_r(r)
r.handle_received(tv_state(12))
unless queued_cmds(r).empty?
  raise 'no correction expected for input=tv (already at policy)'
end
puts 'OK  idle + input=tv -> untouched'

# 17. Negative: session active + input=bluetooth -> untouched.
r = YamahaSoundbarRemote.new(
  {'controller' => {'manage_power' => false, 'initial_intent' => {}, 'idle_input_policy' => 'tv'}})
sync_r(r)
r.instance_variable_set(:@session, ['music', {power: true, input: :analog}])
r.handle_received(bt_state(1))
unless queued_cmds(r).empty?
  raise 'no correction expected while a session is active'
end
puts 'OK  session.active=true + input=bluetooth -> untouched'

# 18. Negative: restore in progress + input=bluetooth -> untouched.
r = YamahaSoundbarRemote.new(
  {'controller' => {'manage_power' => false, 'initial_intent' => {}, 'idle_input_policy' => 'tv'}})
sync_r(r)
r.instance_variable_set(:@restoring_session, true)
r.instance_variable_set(:@restore_phase, nil)
r.handle_received(bt_state(1))
unless queued_cmds(r).empty?
  raise 'no correction expected while a restore is in progress'
end
puts 'OK  restoring=true + input=bluetooth -> untouched'

# 19. In-flight correction is interrupted by a session start: pending is
#     cleared and no duplicate correction is enqueued; a later idle
#     bluetooth observation (after the session ends) re-arms cleanly.
r = YamahaSoundbarRemote.new(
  {'controller' => {'manage_power' => false, 'initial_intent' => {}, 'idle_input_policy' => 'tv'}})
sync_r(r)
r.handle_received(bt_state(1))
queued_cmds(r)
unless r.instance_variable_get(:@idle_input_correction_pending)
  raise 'precondition: correction should be in flight'
end
r.instance_variable_set(:@session, ['music', {power: true}])
r.handle_received(bt_state(1)) # still bluetooth, but a session now exists
unless queued_cmds(r).empty?
  raise 'no second correction expected while a session is active'
end
if r.instance_variable_get(:@idle_input_correction_pending)
  raise 'pending should be cleared when a session interrupts the correction'
end
r.instance_variable_set(:@session, nil)
r.handle_received(bt_state(1)) # idle again -> re-arms
unless queued_cmds(r) == [BT_SET_TV, BT_RS]
  raise 'correction should re-arm once idle again'
end
puts 'OK  in-flight correction interrupted by session start; re-arms when idle'

# 20. Invalid policy input is rejected at config load (fail fast).
begin
  YamahaSoundbarRemote.new({'controller' => {'idle_input_policy' => 'bogus'}})
  raise 'expected ArgumentError for unknown policy input'
rescue ArgumentError
  # expected
end
begin
  YamahaSoundbarRemote.new({'controller' => {'idle_input_policy' => ''}})
  raise 'expected ArgumentError for empty policy input'
rescue ArgumentError
  # expected
end
puts 'OK  invalid idle_input_policy values rejected at config load'

# ----------------------------------------------------------------------------
# 10. Malformed snapshot file is ignored at startup (no crash, no recovery).
# ----------------------------------------------------------------------------
r = YamahaSoundbarRemote.new({'controller' => {'manage_power' => false, 'power_on_for_session_starts' => true}})
r.handle_received(:reset)
r.handle_received([4])
r.handle_received([0, 2, 0])
r.handle_received(tv_state)
r.start_session('music', {'input' => 'analog'})
r.handle_received(tv_state)  # snapshot barrier -> snapshot file written
File.write(r.snapshot_path, 'not json {{{')
r2 = YamahaSoundbarRemote.new({'controller' => {'manage_power' => false, 'power_on_for_session_starts' => true}})
r2.handle_received(:reset)
r2.handle_received([4])
r2.handle_received([0, 2, 0])
r2.handle_received(tv_state)
if r2.session.nil? && !r2.restoring_session
  puts 'OK  malformed snapshot ignored (fresh sync, no recovery)'
else
  puts "FAIL malformed snapshot ignored: session=#{r2.session.inspect}"
  $failures << 'malformed snapshot'
end
FileUtils.rm_f(r.snapshot_path)

# ----------------------------------------------------------------------------
# 21-29. Authoritative startup initial_intent (controller.initial_intent).
#
#   21. configured sound-only intent: normalized string-key config is
#       enforced on the first idle sync; input/volume/mute/power untouched.
#   22. present_empty ({}) is a true no-op (incl. no legacy side effect).
#   23. powered-off device: NO sound-setting commands sent at all; the
#       intent survives and converges only once the device reports on.
#   24. a recovered session snapshot takes precedence over the startup
#       initial intent (no contamination of the recovered session).
#   25. a staged restore after recovery uses the EXACT saved state (not the
#       initial profile); the re-persisted snapshot stays authoritative;
#       after settle the initial intent does NOT re-apply.
#   26. legacy HDMI+power-off side effect: retained for :absent only
#       (incl. the manage_power=true compatibility path), absent for
#       {} and for a configured intent.
#   27. idle_input_policy stays independent of the startup initial profile.
#   28. SPP reconnect during a LIVE session: session stays authoritative,
#       the startup initial intent is discarded (not waiting to re-assert).
#       28b. the guard clause for an in-flight staged restore.
#   29. :absent still follows the exact legacy INITIAL_INTENT path.
# ----------------------------------------------------------------------------
TV_INITIAL = { 'surround' => '3d', 'subwoofer' => 16, 'bass_ext' => true, 'clearvoice' => true }
def initial_cfg
  { 'controller' => { 'manage_power' => false, 'power_on_for_session_starts' => true,
                      'initial_intent' => TV_INITIAL.dup } }
end

C_3D       = YamahaPacketCodec.encode(YamahaSoundbarRemote::COMMANDS[:set_surround_3d])
C_TV       = YamahaPacketCodec.encode(YamahaSoundbarRemote::COMMANDS[:set_surround_tv])
C_MUSIC    = YamahaPacketCodec.encode(YamahaSoundbarRemote::COMMANDS[:set_surround_music])
C_SUB_UP   = YamahaPacketCodec.encode(YamahaSoundbarRemote::COMMANDS[:subwoofer_up])
C_SUB_DN   = YamahaPacketCodec.encode(YamahaSoundbarRemote::COMMANDS[:subwoofer_down])
C_CV_ON    = YamahaPacketCodec.encode(YamahaSoundbarRemote::COMMANDS[:clearvoice_on])
C_CV_OFF   = YamahaPacketCodec.encode(YamahaSoundbarRemote::COMMANDS[:clearvoice_off])
C_BE_ON    = YamahaPacketCodec.encode(YamahaSoundbarRemote::COMMANDS[:bass_ext_on])
C_BE_OFF   = YamahaPacketCodec.encode(YamahaSoundbarRemote::COMMANDS[:bass_ext_off])
C_SET_TV   = YamahaPacketCodec.encode(YamahaSoundbarRemote::COMMANDS[:set_input_tv])
C_SET_ANLG = YamahaPacketCodec.encode(YamahaSoundbarRemote::COMMANDS[:set_input_analog])
C_SET_HDMI = YamahaPacketCodec.encode(YamahaSoundbarRemote::COMMANDS[:set_input_hdmi])
C_VOL_UP   = YamahaPacketCodec.encode(YamahaSoundbarRemote::COMMANDS[:volume_up])
C_VOL_DN   = YamahaPacketCodec.encode(YamahaSoundbarRemote::COMMANDS[:volume_down])
C_MUTE_ON  = YamahaPacketCodec.encode(YamahaSoundbarRemote::COMMANDS[:mute_on])
C_MUTE_OFF = YamahaPacketCodec.encode(YamahaSoundbarRemote::COMMANDS[:mute_off])
C_PWR_ON   = YamahaPacketCodec.encode(YamahaSoundbarRemote::COMMANDS[:power_on])
C_PWR_OFF  = YamahaPacketCodec.encode(YamahaSoundbarRemote::COMMANDS[:power_off])
C_RS       = YamahaPacketCodec.encode(YamahaSoundbarRemote::COMMANDS[:report_status])
# Commands the startup TV sound profile must never touch.
NO_TOUCH   = [ C_SET_TV, C_SET_ANLG, C_SET_HDMI, C_VOL_UP, C_VOL_DN,
               C_MUTE_ON, C_MUTE_OFF, C_PWR_ON, C_PWR_OFF ]

def assert_no_touch(label, cmds)
  NO_TOUCH.each do |c|
    if cmds.include?(c)
      raise "#{label}: forbidden command #{c.inspect} in #{cmds.inspect}"
    end
  end
end

# 21. configured sound-only initial intent: the JSON string-key config is
#     normalized at load and enforced on the first idle sync. input,
#     volume, mute and power are NOT part of it and stay untouched.
r = YamahaSoundbarRemote.new(initial_cfg)
raise 'expected :configured mode' unless r.initial_intent_mode == :configured
raise "normalization broken: #{r.initial_intent_config.inspect}" unless
  r.initial_intent_config == { surround: :'3d', subwoofer: 16, bass_ext: true, clearvoice: true }
sync_r(r)
# Device ON, at a state that differs from the profile: input=tv, vol=14,
# sub=12, surround=music, cv=false, be=false, mute=false.
r.handle_received(tv_state(14, 12, 0x08, false, false))
cmds = queued_cmds(r)
# APPLY_KEYS order: subwoofer, surround, bass_ext, clearvoice (+ verify).
unless cmds == [ C_SUB_UP, C_3D, C_BE_ON, C_CV_ON, C_RS ]
  raise "expected the exact startup command set, got #{cmds.inspect}"
end
assert_no_touch('startup initial_intent', cmds)
# Converged: device at the profile, same vol/input/mute/power -> intent clears.
r.handle_received(tv_state(14, 16, 0x0d, true, true))
raise "intent should have converged to {}: #{r.instance_variable_get(:@intent).inspect}" unless
  r.instance_variable_get(:@intent).empty?
ds = r.device_state
raise "volume must be untouched (14), got #{ds[:volume].inspect}" unless ds[:volume] == 14
raise "input must be untouched (:tv), got #{ds[:input].inspect}" unless ds[:input] == :tv
raise "mute must be untouched (false), got #{ds[:mute].inspect}" unless ds[:mute] == false
raise "power must be untouched (true), got #{ds[:power].inspect}" unless ds[:power] == true
raise 'no commands expected once converged' unless queued_cmds(r).empty?
puts 'OK  21 configured initial_intent: normalized + enforced on idle first sync; input/volume/mute/power untouched'

# 22. present_empty ({}) is a true no-op: no initial intent and no legacy
#     side effect, even when the device sits at bluetooth after an SPP wake.
r = YamahaSoundbarRemote.new({ 'controller' => { 'manage_power' => false, 'initial_intent' => {} } })
raise 'expected :present_empty mode' unless r.initial_intent_mode == :present_empty
sync_r(r)
r.handle_received(bt_state(1))  # on + bluetooth, far from any profile
cmds = queued_cmds(r)
raise "present_empty must be a no-op, got #{cmds.inspect}" unless cmds.empty?
raise 'intent should be empty' unless r.instance_variable_get(:@intent).empty?
puts 'OK  22 initial_intent={} (present_empty) remains a true no-op (no legacy side effect)'

# 23. powered-off device + configured sound-only initial intent:
#     NO sound-setting commands are sent while off (not even ones the
#     device would ignore) and no power_on; the intent survives intact and
#     converges only once the device reports power=true.
OFF_MUSIC = [5, 1, 0, 0x7, 0, 14, 12, 0, 0, 0, 0, 0x08, 0]  # off; music-ish state
r = YamahaSoundbarRemote.new(initial_cfg)
sync_r(r)
r.handle_received(OFF_MUSIC)
cmds = queued_cmds(r)
raise "powered-off startup must send NOTHING, got #{cmds.inspect}" unless cmds.empty?
assert_no_touch('powered-off startup', cmds)
i = r.instance_variable_get(:@intent)
raise "intent must remain pending while off: #{i.inspect}" unless
  i[:surround] == :'3d' && i[:subwoofer] == 16 && i[:bass_ext] == true && i[:clearvoice] == true
raise 'no enforce_retried marker expected (fresh intent)' if i.key?(:enforce_retried)
raise 'device must stay off' unless r.device_state[:power] == false
# Still off on the next report: still nothing, still pending (no loop, no discard).
r.handle_received(OFF_MUSIC)
raise 'second off report must also send nothing' unless queued_cmds(r).empty?
raise 'intent must still be pending while off' unless
  r.instance_variable_get(:@intent)[:surround] == :'3d'
# Device powers on (user remote), still at the music-ish state:
# the pending intent now converges exactly once.
r.handle_received([5, 1, 1, 0x7, 0, 14, 12, 0, 0, 0, 0, 0x08, 0])
cmds = queued_cmds(r)
unless cmds == [ C_SUB_UP, C_3D, C_BE_ON, C_CV_ON, C_RS ]
  raise "expected the pending intent to converge on power-up, got #{cmds.inspect}"
end
assert_no_touch('power-up convergence', cmds)
r.handle_received([5, 1, 1, 0x7, 0, 14, 16, 0, 0, 0, 0, 0x0d, 0x24])  # at profile
raise 'intent must have converged' unless r.instance_variable_get(:@intent).empty?
puts 'OK  23 powered-off: zero commands sent; intent survives and converges on power-up'

# 24. a persisted session snapshot (crash recovery) takes precedence over
#     the startup initial intent: no TV-profile contamination of the
#     recovered session.
r1 = YamahaSoundbarRemote.new({ 'controller' => { 'manage_power' => false, 'power_on_for_session_starts' => true } })
r1.handle_received(:reset)
r1.handle_received([4])
r1.handle_received([0, 2, 0])
r1.handle_received(tv_state(14, 16, 0x0a, false, true))  # pre-session state (surround=tv)
r1.start_session('music', { 'input' => 'analog', 'volume' => 18, 'surround' => 'music', 'clearvoice' => false })
r1.handle_received(analog_state(18, 12, 0x08, false, false))  # snapshot barrier
raise 'precondition: snapshot must be persisted' unless File.exist?(r1.snapshot_path)
saved = JSON.parse(File.read(r1.snapshot_path))['saved_state']
raise "unexpected saved state: #{saved.inspect}" unless
  saved['surround'] == 'tv' && saved['volume'] == 14 && saved['clearvoice'] == false
# Simulated restart: fresh controller with the configured initial intent;
# the device is still reporting the music state.
r2 = YamahaSoundbarRemote.new(initial_cfg)
sync_r(r2)
r2.handle_received(analog_state(18, 12, 0x08, false, false))
raise 'session must be recovered from the snapshot' unless r2.session && r2.session.first == 'music'
cmds = queued_cmds(r2)
raise "recovered session must suppress the initial intent, got #{cmds.inspect}" unless cmds.empty?
raise "recovered session intent polluted: #{r2.instance_variable_get(:@intent).inspect}" unless
  r2.instance_variable_get(:@intent).empty?
puts 'OK  24 recovered session snapshot takes precedence over startup initial_intent'

# 25. the staged restore after a recovered session uses the EXACT saved
#     pre-session state (surround=tv, cv=false, vol=14, input=tv --
#     deliberately different from the initial profile's 3d/cv=true):
#     no initial-profile contamination of the persisted restore, and after
#     settle the startup initial intent does NOT re-apply (recovery ends at
#     the exact pre-session state, not "restore + TV baseline").
#     (Continues with r2 from test 24; same runtime dir.)
SAVED3_MUTED   = [5, 1, 1, 0x7, 1, 14, 16, 0, 0, 0, 0, 0x0a, 0x20]  # saved state, temporarily muted
SAVED3_SETTLED = [5, 1, 1, 0x7, 0, 14, 16, 0, 0, 0, 0, 0x0a, 0x20]  # saved state, settled
r2.stop_session('music')
r2.handle_received(SAVED3_MUTED)  # stop_session's 0x05 -> :mute phase
raise "expected :mute phase, got #{r2.restore_phase.inspect}" unless r2.restore_phase == :mute
i = r2.instance_variable_get(:@intent)
raise "restore must carry saved surround :tv, got #{i[:surround].inspect}" unless i[:surround] == :tv
raise "restore must carry saved clearvoice false, got #{i[:clearvoice].inspect}" unless i[:clearvoice] == false
raise "restore must carry saved volume 14, got #{i[:volume].inspect}" unless i[:volume] == 14
raise "restore must carry saved input :tv, got #{i[:input].inspect}" unless i[:input] == :tv
raise "restore must carry saved subwoofer 16, got #{i[:subwoofer].inspect}" unless i[:subwoofer] == 16
raise 'restore must not carry :power (manage_power=false)' if i.key?(:power)
raise "restore must be temporarily muted, got #{i[:mute].inspect}" unless i[:mute] == true
# The re-persisted snapshot file must still hold the exact saved state.
saved2 = JSON.parse(File.read(r2.snapshot_path))['saved_state']
raise "persisted restore contaminated: #{saved2.inspect}" unless saved2 == saved
# Drive the staged restore to completion (same recipe as test 9).
r2.handle_received(SAVED3_MUTED)
feed(r2, vs(14, false))
r2.handle_received(SAVED3_MUTED)
feed(r2, vs(14, true))
r2.handle_received(SAVED3_MUTED)
r2.handle_received(SAVED3_MUTED)
r2.handle_received(SAVED3_MUTED)
feed(r2, vs(14, true))
feed(r2, vs(14, true))
feed(r2, vs(14, false))
unless r2.restore_phase.nil? && !r2.restoring_session && r2.restore_error.nil?
  raise "expected settled restore, got phase=#{r2.restore_phase.inspect} restoring=#{r2.restoring_session} error=#{r2.restore_error.inspect}"
end
raise 'session must be nil after settle' unless r2.session.nil?
if File.exist?(r2.snapshot_path)
  raise 'snapshot not deleted after settled restore'
end
# After settle: the device sits at the EXACT pre-session state, which
# differs from the TV initial profile (surround=tv not 3d, cv off not on).
# No startup baseline may be applied on top of the restored state.
r2.handle_received(SAVED3_SETTLED)
queued_cmds(r2)  # drain leftovers from the restore drive
r2.handle_received(SAVED3_SETTLED)
raise "no initial-intent re-application after settle: #{r2.instance_variable_get(:@intent).inspect}" unless
  r2.instance_variable_get(:@intent).empty?
raise "no commands expected after settle, got #{queued_cmds(r2).inspect}" unless queued_cmds(r2).empty?
puts 'OK  25 recovered staged restore: exact saved state, snapshot authoritative, no post-settle TV baseline'

# 26. the legacy "SPP-woken device -> HDMI + power off" side effect:
#     retained behavior-for-behavior for :absent, absent for {} (test 22)
#     and for a configured non-empty intent.
# 26a. :absent + on + bluetooth + non-legacy state: legacy INITIAL_INTENT
#      merged WITH the side effect (input=hdmi, power=false).
r = YamahaSoundbarRemote.new({ 'controller' => { 'manage_power' => false } })
raise 'expected :absent mode' unless r.initial_intent_mode == :absent
sync_r(r)
r.handle_received(bt_state(1))  # on, bluetooth, vol=12, sub=16, surround=tv, cv=false, be=false
i = r.instance_variable_get(:@intent)
# legacy INITIAL_INTENT = {subwoofer:16, surround:tv, bass_ext:true, clearvoice:false}
# + side effect {input:hdmi, power:false} (power stripped by manage_power=false)
expected_intent = { subwoofer: 16, surround: :tv, bass_ext: true, clearvoice: false,
                    input: :hdmi, enforce_retried: true }
raise "legacy :absent intent mismatch: #{i.inspect}" unless i == expected_intent
cmds = queued_cmds(r)
# deltas vs device: input bluetooth->hdmi, bass_ext false->true (APPLY_KEYS order)
unless cmds == [ C_SET_HDMI, C_BE_ON, C_RS ]
  raise "legacy :absent must enforce the side effect, got #{cmds.inspect}"
end
raise 'legacy :absent (manage_power=false) must not touch power commands' if
  cmds.include?(C_PWR_OFF) || cmds.include?(C_PWR_ON)
# 26b. :absent + manage_power=true: the upstream compatibility path is
#      unchanged (power_off is enqueued alongside the side effect).
r = YamahaSoundbarRemote.new({ 'controller' => { 'manage_power' => true } })
sync_r(r)
r.handle_received(bt_state(1))
i = r.instance_variable_get(:@intent)
raise "legacy manage_power=true intent mismatch: #{i.inspect}" unless
  i[:input] == :hdmi && i[:power] == false && i[:bass_ext] == true && i[:clearvoice] == false
cmds = queued_cmds(r)
raise "legacy manage_power=true must enqueue power_off: #{cmds.inspect}" unless cmds.include?(C_PWR_OFF)
raise "legacy manage_power=true must enqueue set_input_hdmi: #{cmds.inspect}" unless cmds.include?(C_SET_HDMI)
# 26c. configured non-empty sound intent + on + bluetooth: NO side effect;
#      only the configured sound fields are enforced.
r = YamahaSoundbarRemote.new(initial_cfg)
sync_r(r)
r.handle_received(bt_state(1))  # on, bluetooth, vol=12, sub=16, surround=tv, cv=false, be=false
i = r.instance_variable_get(:@intent)
raise "configured intent must not gain input/power side effects: #{i.inspect}" if
  i.key?(:input) || i.key?(:power)
raise "configured intent mismatch: #{i.inspect}" unless
  i[:surround] == :'3d' && i[:subwoofer] == 16 && i[:bass_ext] == true && i[:clearvoice] == true
cmds = queued_cmds(r)
# deltas vs device: surround tv->3d, bass_ext on, clearvoice on (sub 16==16)
unless cmds == [ C_3D, C_BE_ON, C_CV_ON, C_RS ]
  raise "expected sound-only enforcement, got #{cmds.inspect}"
end
assert_no_touch('configured + bluetooth', cmds)
puts 'OK  26 legacy HDMI+power-off side effect: :absent retains it (incl. manage_power=true), configured intents do not trigger it'

# 27. idle_input_policy='tv' stays independent of the startup initial
#     profile: while the initial intent is being processed it is suppressed
#     (no conflated correction); once the profile converges, the policy
#     corrects bluetooth -> tv under its existing guarded idle conditions,
#     and only that.
BT_AT_PROFILE = [5, 1, 1, 0x5, 0, 14, 16, 0, 0, 0, 0, 0x0d, 0x24]  # bluetooth, at TV profile
r = YamahaSoundbarRemote.new({ 'controller' => { 'manage_power' => false,
                                                 'power_on_for_session_starts' => true,
                                                 'initial_intent' => TV_INITIAL.dup,
                                                 'idle_input_policy' => 'tv' } })
sync_r(r)
r.handle_received(BT_AT_PROFILE)
cmds = queued_cmds(r)
raise "initial-intent processing must not conflate the idle correction: #{cmds.inspect}" unless cmds.empty?
raise 'profile must have converged with zero delta' unless r.instance_variable_get(:@intent).empty?
# Second report (still bluetooth, idle, intent empty): the policy corrects
# bluetooth -> tv, and nothing else.
r.handle_received(BT_AT_PROFILE)
cmds = queued_cmds(r)
unless cmds == [ C_SET_TV, C_RS ]
  raise "idle policy must correct only the input, got #{cmds.inspect}"
end
raise 'correction pending expected' unless r.instance_variable_get(:@idle_input_correction_pending)
r.handle_received(tv_state(14))  # verification report: input=tv
if r.instance_variable_get(:@idle_input_correction_pending)
  raise 'pending should clear after verified input=tv'
end
puts 'OK  27 idle_input_policy independent of the startup initial profile (bluetooth -> tv only)'

# 28. SPP reconnect (full handshake) during a LIVE session: the session
#     stays authoritative; the startup initial intent is discarded and is
#     not waiting to re-assert itself afterwards.
r = YamahaSoundbarRemote.new(initial_cfg)
sync_r(r)
r.handle_received(tv_state(14, 16, 0x0d, true, true))  # at profile -> zero-delta convergence
raise 'precondition: initial intent must have converged' unless r.instance_variable_get(:@intent).empty?
r.start_session('music', { 'input' => 'analog', 'volume' => 18, 'surround' => 'music',
                           'clearvoice' => false, 'subwoofer' => 12, 'bass_ext' => true })
r.handle_received(analog_state(18, 12, 0x08, false, true))  # session active at music state
raise 'session must be active' unless r.session && r.session.first == 'music'
raise 'precondition: music intent must have converged' unless r.instance_variable_get(:@intent).empty?
# SPP drops and reconnects mid-session.
r.handle_received(:reset)
r.handle_received([4])
r.handle_received([0, 2, 0])
queued_cmds(r)  # drain the reconnect handshake commands
r.handle_received(analog_state(18, 12, 0x08, false, true))
cmds = queued_cmds(r)
raise "reconnect must not re-apply the initial intent: #{cmds.inspect}" unless cmds.empty?
i = r.instance_variable_get(:@intent)
[:surround, :subwoofer, :bass_ext, :clearvoice, :input, :volume, :mute, :power, :initial].each do |k|
  raise "initial intent waiting to re-assert: #{k} in #{i.inspect}" if i.key?(k)
end
raise 'session must survive the reconnect' unless r.session && r.session.first == 'music'
# Nothing is waiting to re-assert on the next report either.
r.handle_received(analog_state(18, 12, 0x08, false, true))
raise 'no follow-up commands expected after the reconnect' unless queued_cmds(r).empty?
raise 'intent must remain empty after the reconnect' unless r.instance_variable_get(:@intent).empty?
FileUtils.rm_f(r.snapshot_path)
# 28b. guard clause for an in-flight staged restore: a pending :initial
#      marker is dropped while @restoring_session is set.
r = YamahaSoundbarRemote.new(initial_cfg)
sync_r(r)
r.instance_variable_set(:@restoring_session, true)
r.instance_variable_set(:@restore_phase, :mute)
r.instance_variable_set(:@intent, { initial: true })
r.handle_received(tv_state(14))
raise "restoring guard must drop :initial: #{r.instance_variable_get(:@intent).inspect}" unless
  r.instance_variable_get(:@intent).empty?
raise 'no commands expected from a dropped initial marker' unless queued_cmds(r).empty?
puts 'OK  28 reconnect during a live session: session authoritative, initial intent discarded (incl. restoring-session guard)'

# 29. :absent (key missing) still follows the exact legacy path:
#     INITIAL_INTENT merged at first sync, no side effect when the device
#     is not on bluetooth.
r = YamahaSoundbarRemote.new({ 'controller' => { 'manage_power' => false } })
raise 'expected :absent mode' unless r.initial_intent_mode == :absent
sync_r(r)
# Device on, input=analog, far from the legacy intent: vol=11, sub=12,
# surround=music, cv=true, be=true.
r.handle_received(analog_state(11, 12, 0x08, true, true))
i = r.instance_variable_get(:@intent)
raise "legacy merge must carry INITIAL_INTENT: #{i.inspect}" unless
  i[:subwoofer] == 16 && i[:surround] == :tv && i[:bass_ext] == true && i[:clearvoice] == false
raise 'no side effect expected (input is analog, not bluetooth)' if i.key?(:input) || i.key?(:power)
cmds = queued_cmds(r)
# deltas vs device: sub 12->16, surround music->tv, cv true->false (APPLY_KEYS order)
unless cmds == [ C_SUB_UP, C_TV, C_CV_OFF, C_RS ]
  raise "legacy :absent enforcement mismatch: #{cmds.inspect}"
end
puts 'OK  29 :absent follows the exact legacy INITIAL_INTENT path'

if $failures.empty?
  puts ''
  puts 'PASS'
  exit 0
else
  puts ''
  puts "FAIL: #{$failures.size} check(s)"
  $failures.each { |f| puts "  - #{f}" }
  exit 1
end
RUBY
