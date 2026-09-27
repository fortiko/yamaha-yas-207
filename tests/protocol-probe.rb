#!/usr/bin/env ruby

require 'optparse'
require 'serialport'
require_relative '../control/common'

class ProtocolProbe
	INIT = '0148545320436f6e74'
	INIT_FOLLOWUP = '020001'
	COMMANDS = {
		report_status: '0305',
		report_volume: '0312',
		mute_on: '407ea2',
		mute_off: '407ea3',
		volume_up: '40781e',
		volume_down: '40781f',
		set_input_analog: '4078d1',
	}.freeze

	def initialize(device, verbose_batch: false)
		@started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
		@verbose_batch = verbose_batch
		@packets = Queue.new
		@serial = SerialPort.new(device, baud: 115_200)
		@serial.set_encoding('ASCII-8BIT')
		@serial.flow_control = SerialPort::HARD
		@serial.sync = true
		@serial.read_timeout = -1
		@codec = YamahaPacketCodec.new do |packet|
			received_at = monotonic
			log('RX', packet.pack('C*').unpack1('H*'))
			@packets << [received_at, packet]
		end
		@reader = Thread.new do
			loop do
				data = @serial.read
				@codec.streaming_decode(data) unless data.nil? || data.empty?
				sleep 0.001
			end
		end
	end

	def close
		@reader&.kill
		@serial&.close
	end

	def sync
		transmit(INIT, 'init')
		wait_packet(0x04, 3.0)
		transmit(INIT_FOLLOWUP, 'init_followup')
		wait_packet(0x00, 3.0)
	end

	def aggregate_status
		sent_at = transmit(COMMANDS[:report_status], 'report_status')
		received_at, packet = wait_packet(0x05, 2.0, sent_at)
		state = {
			power: !packet[2].zero?,
			input: packet[3],
			mute: !packet[4].zero?,
			volume: packet[5],
		}
		log('RESULT', "report_status latency_ms=#{milliseconds(received_at - sent_at)} state=#{state}")
		state
	end

	def volume_status
		sent_at = transmit(COMMANDS[:report_volume], 'report_volume')
		received_at, packet = wait_packet(0x12, 2.0, sent_at)
		state = {mute: !packet[1].zero?, volume: packet[2]}
		log('RESULT', "report_volume latency_ms=#{milliseconds(received_at - sent_at)} state=#{state}")
		state
	end

	def command(name)
		transmit(COMMANDS.fetch(name), name)
	end

	def batch(name, count, spacing)
		started_at = monotonic
		log('BATCH', "start command=#{name} count=#{count} spacing_ms=#{milliseconds(spacing)}")
		count.times do |index|
			label = "#{name}[#{index + 1}/#{count}]" if @verbose_batch
			transmit(COMMANDS.fetch(name), label)
			sleep spacing if spacing.positive? && index + 1 < count
		end
		log('BATCH', "finish command=#{name} elapsed_ms=#{milliseconds(monotonic - started_at)}")
	end

	def wait(seconds)
		log('WAIT', "seconds=#{seconds}")
		sleep seconds
	end

	private

	def monotonic
		Process.clock_gettime(Process::CLOCK_MONOTONIC)
	end

	def milliseconds(seconds)
		(seconds * 1000).round(1)
	end

	def transmit(payload, label)
		frame = YamahaPacketCodec.encode(payload)
		sent_at = monotonic
		@serial.write(frame)
		log('TX', "#{label} #{frame.unpack1('H*')}", sent_at) if label
		sent_at
	end

	def wait_packet(type, timeout, after = 0)
		deadline = monotonic + timeout
		loop do
			remaining = deadline - monotonic
			raise "timed out waiting for packet 0x#{type.to_s(16)}" unless remaining.positive?

			begin
				received_at, packet = @packets.pop(true)
				return [received_at, packet] if received_at >= after && packet.first == type
			rescue ThreadError
				sleep [remaining, 0.001].min
			end
		end
	end

	def log(kind, message, at = monotonic)
		puts format('%9.3f %-6s %s', at - @started_at, kind, message)
	end
end

options = {
	device: ENV.fetch('CONTROL_DEVICE', '/dev/rfcomm0'),
	spacing: 0.05,
	settle: 0.2,
	count: 1,
	target: 10,
	boundary: 'lower',
	verbose_batch: false,
	query: 'volume',
}

parser = OptionParser.new do |opts|
	opts.banner = 'Usage: protocol-probe.rb [options] status|command|batch NAME'
	opts.on('--device PATH') { |value| options[:device] = value }
	opts.on('--count N', Integer) { |value| options[:count] = value }
	opts.on('--spacing SECONDS', Float) { |value| options[:spacing] = value }
	opts.on('--settle SECONDS', Float) { |value| options[:settle] = value }
	opts.on('--target RAW', Integer) { |value| options[:target] = value }
	opts.on('--boundary NAME', %w[lower upper]) { |value| options[:boundary] = value }
	opts.on('--query TYPE', %w[volume aggregate]) { |value| options[:query] = value }
	opts.on('--verbose-batch') { options[:verbose_batch] = true }
end
parser.parse!

operation = ARGV.shift || 'status'
name = ARGV.shift&.to_sym
probe = ProtocolProbe.new(options[:device], verbose_batch: options[:verbose_batch])

begin
	probe.sync
	case operation
	when 'status'
		probe.aggregate_status
		probe.volume_status
	when 'command'
		options[:query] == 'aggregate' ? probe.aggregate_status : probe.volume_status
		probe.command(name)
		probe.wait(options[:settle])
		options[:query] == 'aggregate' ? probe.aggregate_status : probe.volume_status
	when 'batch'
		options[:query] == 'aggregate' ? probe.aggregate_status : probe.volume_status
		probe.batch(name, options[:count], options[:spacing])
		probe.wait(options[:settle])
		options[:query] == 'aggregate' ? probe.aggregate_status : probe.volume_status
	when 'home'
		raise 'target must be in 0..50' unless (0..50).cover?(options[:target])

		probe.volume_status
		probe.command(:mute_on)
		probe.volume_status
		if options[:boundary] == 'lower'
			probe.batch(:volume_down, 55, options[:spacing])
			probe.batch(:volume_up, options[:target], options[:spacing])
		else
			probe.batch(:volume_up, 55, options[:spacing])
			probe.batch(:volume_down, 50 - options[:target], options[:spacing])
		end
		probe.command(:mute_on)
		probe.wait(options[:settle])
		state = probe.volume_status
		raise "homing failed: expected volume=#{options[:target]} mute=true, got #{state}" unless state == {mute: true, volume: options[:target]}
	else
		raise "unknown operation: #{operation}"
	end
ensure
	probe.close
end
