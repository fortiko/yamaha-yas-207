#!/usr/bin/env bash
# Smoke test: persistent session snapshot for crash recovery.
# Runs on any host with Ruby (no serial port required).
#
# Verifies:
#   1. start_session writes a JSON snapshot to the configured path.
#   2. A fresh controller instance picks up the snapshot on the
#      first 0x05 reply after sync and rehydrates @session.
#   3. If the snapshot file is unreadable or malformed, recovery is
#      skipped silently and the controller continues with @session=nil.
#   4. After the staged restore settles, the snapshot is removed.

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
require 'fileutils'

failures = []

TV_STATE    = [5, 1, 1, 0x7, 0, 10, 16, 0, 0, 0, 0, 0x0a, 0]
MUSIC_STATE = [5, 1, 1, 0xc, 0, 20, 16, 0, 0, 0, 0, 0x0a, 0]

# --- 1. start_session writes the snapshot ---
r1 = YamahaSoundbarRemote.new
r1.handle_received(:reset)
r1.handle_received([4])
r1.handle_received([0, 2, 0])
r1.handle_received(TV_STATE)
r1.start_session('music', {'input' => 'analog', 'volume' => 20})
# Snapshot barrier 0x05 (still TV state -- no commands applied yet).
r1.handle_received(TV_STATE)

if File.exist?(r1.snapshot_path)
  puts "OK  snapshot written on start_session"
else
  puts "FAIL snapshot not written: #{r1.snapshot_path}"
  failures << 'snapshot written'
end

# Snapshot file mode should be 0600.
mode = File.stat(r1.snapshot_path).mode & 0777
if mode == 0600
  puts "OK  snapshot file mode is 0600"
else
  puts "FAIL snapshot mode: #{mode.to_s(8)}"
  failures << 'snapshot mode'
end

snapshot_data = JSON.parse(File.read(r1.snapshot_path))
if snapshot_data['name'] == 'music' && snapshot_data['saved_state']['volume'] == 10
  puts "OK  snapshot contents: name=#{snapshot_data['name']} vol=#{snapshot_data['saved_state']['volume']}"
else
  puts "FAIL snapshot contents: #{snapshot_data.inspect}"
  failures << 'snapshot contents'
end

# --- 2. Fresh instance recovers the snapshot ---
r2 = YamahaSoundbarRemote.new
if r2.session.nil?
  puts "OK  fresh instance starts with @session=nil"
else
  puts "FAIL fresh instance: #{r2.session.inspect}"
  failures << 'fresh instance'
end

# Sync, then trigger 0x05 -> recover.
r2.handle_received(:reset)
r2.handle_received([4])
r2.handle_received([0, 2, 0])
r2.handle_received(TV_STATE)

if r2.session && r2.session.first == 'music'
  puts "OK  recovered session from snapshot: name=#{r2.session.first}"
else
  puts "FAIL recovery: session=#{r2.session.inspect}"
  failures << 'recovery'
end

# --- 3. Malformed snapshot is ignored ---
File.write(r1.snapshot_path, 'not json {{{')
r3 = YamahaSoundbarRemote.new
r3.handle_received(:reset)
r3.handle_received([4])
r3.handle_received([0, 2, 0])
r3.handle_received(TV_STATE)
if r3.session.nil?
  puts "OK  malformed snapshot ignored"
else
  puts "FAIL malformed snapshot caused recovery: #{r3.session.inspect}"
  failures << 'malformed snapshot'
end

# --- 4. Successful staged restore deletes snapshot ---
FileUtils.rm_f(r1.snapshot_path)
r4 = YamahaSoundbarRemote.new
r4.handle_received(:reset)
r4.handle_received([4])
r4.handle_received([0, 2, 0])
r4.handle_received(TV_STATE)
r4.start_session('music', {'input' => 'analog', 'volume' => 20})
r4.handle_received(TV_STATE)
r4.handle_received(MUSIC_STATE)
r4.stop_session('music')
r4.handle_received(MUSIC_STATE)
# Run the full staged restore.
r4.handle_received(MUSIC_STATE)
r4.handle_received([5, 1, 1, 0xc, 1, 20, 16, 0, 0, 0, 0, 0x0a, 0])  # muted music
r4.handle_received([5, 1, 1, 0xc, 1, 20, 16, 0, 0, 0, 0, 0x0a, 0])  # volume phase entry
r4.handle_received([0x12, 1, 10])                                      # volume reply
r4.handle_received(MUSIC_STATE)                                       # sound phase status
r4.handle_received(MUSIC_STATE)                                       # sound done
r4.handle_received(MUSIC_STATE)                                       # input phase status
r4.handle_received(MUSIC_STATE)                                       # input phase emit
r4.handle_received([5, 1, 1, 0x7, 0, 10, 16, 0, 0, 0, 0, 0x0a, 0])  # TV switched
r4.handle_received([5, 1, 1, 0x7, 0, 10, 16, 0, 0, 0, 0, 0x0a, 0])  # final_mute status
r4.handle_received([0x12, 0, 10])                                      # final_mute reply

if !File.exist?(r4.snapshot_path)
  puts "OK  snapshot deleted after successful restore"
else
  puts "FAIL snapshot not deleted: #{r4.snapshot_path}"
  failures << 'snapshot deleted'
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
