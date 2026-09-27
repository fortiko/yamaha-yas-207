#!/usr/bin/env ruby
# Shairport Sync integration: volume-control.rb
#
# Called by shairport-sync's run_this_when_volume_is_set configuration.
# Maps AirPlay's dB volume (-144..0 dB) to upstream YAS raw volume (0..50)
# and forwards the intent.
#
# See https://wejn.org/2021/04/yas-207-vs-shairport-sync-over-toslink/
# for the original design.

require 'json'
require 'net/http'
require 'uri'

HOST = ENV.fetch('YAS207_CONTROLLER_HOST', '127.0.0.1')
PORT = Integer(ENV.fetch('YAS207_CONTROLLER_PORT', '8000'))

def send_intent(intent)
  uri = URI("http://#{HOST}:#{PORT}/send")
  res = Net::HTTP.post_form(uri, 'intent' => intent.to_json)
  unless res.is_a?(Net::HTTPSuccess)
    STDERR.puts "volume-control.rb: HTTP #{res.code}: #{res.body}"
    exit 1
  end
end

# expected input: -144.0 for mute, -30.0..0.0 for volume level
# viz: https://nto.github.io/AirPlay.html#audio-volumecontrol
volume = Float(ARGV.first || -15.0)
if volume < -100.0  # -144.0 to be exact, but what the hell
  send_intent({ 'mute' => true })
else
  volume = -30.0 if volume < -30.0
  volume = 0.0    if volume > 0.0
  # (-30.0..0) -> (0..50)
  raw = (5 / 3.0 * volume + 50).round
  send_intent({ 'mute' => false, 'volume' => raw })
end
