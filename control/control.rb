#!/usr/bin/env ruby

# Author: Michal Jirku (wejn.org)
# License: GNU Affero General Public License v3.0

begin
	require 'serialport'
rescue LoadError
	STDERR.puts "Missing serialport gem: #$!."
	exit 1
end
begin
	require_relative 'common'
rescue LoadError
	STDERR.puts "Missing common lib: #$!."
	exit 1
end
require 'thread'
require 'webrick'
require 'json'
require 'fileutils'

# YAS-207 remote.
#
# Provides higher-level abstraction (stateful management) on top of the soundbar.
#
# Also implements interface used by `YamahaSerialInputWorker`.
class YamahaSoundbarRemote
	# Init string sent to YAS-207
	INIT_STRING = "0148545320436f6e74"

	# Init-followup command sent to YAS-207 (that is sent after the response to init string)
	INIT_FOLLOWUP = "020001"

	# Commands accepted by the YAS-207 (that I know of)
	COMMANDS = {
		# power management
		power_toggle: "4078cc",
		power_on: "40787e",
		power_off: "40787f",

		# input management
		set_input_hdmi: "40784a",
		set_input_analog: "4078d1",
		set_input_bluetooth: "407829",
		set_input_tv: "4078df",

		# surround management
		set_surround_3d: "4078c9", # -- 3d surround
		set_surround_tv: "407ef1", # -- tv program
		set_surround_stereo: "407850",
		set_surround_movie: "4078d9",
		set_surround_music: "4078da",
		set_surround_sports: "4078db",
		set_surround_game: "4078dc",
		surround_toggle: "4078b4", # -- sets surround to `:movie` (or `:"3d"` if already `:movie`)
		clearvoice_toggle: "40785c",
		clearvoice_on: "407e80",
		clearvoice_off: "407e82",
		bass_ext_toggle: "40788b",
		bass_ext_on: "40786e",
		bass_ext_off: "40786f",

		# volume management
		subwoofer_up: "40784c",
		subwoofer_down: "40784d",
		mute_toggle: "40789c",
		mute_on: "407ea2",
		mute_off: "407ea3",
		volume_up: "40781e",
		volume_down: "40781f",

		# extra -- IR -- don't use?
		bluetooth_standby_toggle: "407834",
		dimmer: "4078ba",

		# status report (query, soundbar returns a message)
		report_status: "0305",
		report_volume: "0312"
	}.freeze

	# Mapping of input values to names
	INPUT_NAMES = {
		0x0 => :hdmi,
		0xc => :analog,
		0x5 => :bluetooth,
		0x7 => :tv,
	}.freeze

	# Mapping of surround values to names
	SURROUND_NAMES = {
		0x0d => :"3d",
		0x0a => :tv,
		0x0100 => :stereo,
		0x03 => :movie,
		0x08 => :music,
		0x09 => :sports,
		0x0c => :game,
	}.freeze

	# How long to wait for sync before retrying.
	SYNC_TIMEOUT = 15

	# How often to refresh status.
	STATUS_REFRESH = 30

	# Volume range accepted by the device
	VOLUME_RANGE = (0..0x32)

	# Domain (range) valid for the device
	SUBWOOFER_DOMAIN = 0.step(0x20, 4).to_a

	# Initial intent enforced at the first sync (more in `handle_received`, tho)
	INITIAL_INTENT = {
		subwoofer: 16,
		surround: :tv,
		bass_ext: true,
		clearvoice: false,
	}.freeze

	# Keys applied for general (non-restore) intent enforcement. Order chosen
	# for start-session semantics: input switches first so that subsequent
	# volume/sound changes are made into a silent source.
	APPLY_KEYS = [
		:input, :volume, :subwoofer, :surround, :bass_ext, :clearvoice,
		:mute, :power
	].freeze

	# Keys applied during stop-session restoration. Order is the staged-restore
	# safety order: silence first (mute), then reduce volume to saved level,
	# then sound character, then switch input (still muted, safe), then
	# restore final mute state.
	#
	# NOTE: :input is intentionally NOT in this list. Input switching is
	# handled by the dedicated :input phase below, which only runs once
	# :volume AND :sound have positively converged to the saved state.
	RESTORE_KEYS = [
		:mute, :volume, :surround, :bass_ext, :clearvoice, :subwoofer
	].freeze

	# Staged restore phases.
	# :mute     force and verify temporary mute
	# :volume   restore volume transactionally, with bounded correction
	# :sound    restore clearvoice / surround / bass_ext / subwoofer
	# :input    restore input (only after :volume AND :sound verified)
	# :final_mute restore saved mute value (after another volume check)
	RESTORE_PHASES = [
		:mute, :volume, :sound, :input, :final_mute
	].freeze

	# A distinct 0x12 reply is the completion barrier for volume operations.
	# Try direct correction first, then home to the lower boundary if needed.
	MAX_VOLUME_RESTORE_CORRECTIONS = 2
	VOLUME_HOME_MARGIN = 5

	# Load configuration from disk. Falls back to {} if no config file
	# exists; this preserves upstream legacy behaviour.
	def self.load_config
		path = ENV['YAS207_CONFIG']
		path ||= File.join(Dir.home, '.config', 'yas207', 'controller.json')
		return {} unless path && File.exist?(path)
		JSON.parse(File.read(path))
	rescue => e
		STDERR.puts "! Failed to load config from #{path}: #{e}"
		exit 2
	end

	# Resolve runtime directory deterministically from euid.
	def self.runtime_dir
		ENV['YAS207_RUNTIME_DIR'] || "/run/user/#{Process.euid}/yas207"
	end

	def initialize(config = nil)
		@config = config || self.class.load_config
		ctrl = @config['controller'] || {}

		@rfcomm_device    = ENV['CONTROL_DEVICE'] || ctrl['rfcomm_device'] || '/dev/rfcomm0'
		@http_bind        = ctrl['http_bind']   || '127.0.0.1'
		@http_port        = ctrl['http_port']   || 8000
		@sync_timeout     = ctrl['sync_timeout_seconds']   || SYNC_TIMEOUT
		@status_refresh   = ctrl['status_refresh_seconds'] || STATUS_REFRESH
		@manage_power     = ctrl.key?('manage_power') ? !!ctrl['manage_power'] : true
		@runtime_dir      = self.class.runtime_dir

		# Tri-state initial_intent handling.
		# :absent         => apply legacy INITIAL_INTENT on first sync
		# :present_empty  => apply NO initial intent
		# :configured     => apply exactly @initial_intent_config
		if !ctrl.key?('initial_intent')
			@initial_intent_mode = :absent
			@initial_intent_config = nil
		elsif ctrl['initial_intent'].nil? || (ctrl['initial_intent'].respond_to?(:empty?) && ctrl['initial_intent'].empty?)
			@initial_intent_mode = :present_empty
			@initial_intent_config = nil
		else
			@initial_intent_mode = :configured
			@initial_intent_config = ctrl['initial_intent']
		end

		@device_state = {}
		@queue = Queue.new
		@state = :initial
		@intent = {}
		@session = nil
		@restoring_session = false
		@restore_requested = false
		@deferred_final_mute = nil
		@snapshot_path = File.join(@runtime_dir, 'controller', 'session.json')
		@snapshot_recovered = false
		@restore_phase = nil
		@restore_phase_status_refreshed = false
		@restore_volume_attempts = 0
		@restore_volume_homed = false
		@restore_error = nil
		@restore_id = 0
		FileUtils.mkdir_p(File.dirname(@snapshot_path))
	end
	attr_reader :device_state, :config, :runtime_dir, :rfcomm_device, :http_bind,
		:http_port, :sync_timeout, :status_refresh, :manage_power,
		:initial_intent_mode, :initial_intent_config, :session,
		:restoring_session, :snapshot_path, :restore_phase, :restore_error

	# Handle packet received via serial.
	#
	# @param packet [Array<Integer>, :reset, :heartbeat] incoming packet
	def handle_received(packet)
		if packet == :reset
			@state = :initial
			@queue.clear # no use pushing anything when the comm broke
			@reset_at = Time.now
			enqueue(INIT_STRING)
		elsif packet == :heartbeat
			if @state == :synced
				if @last_status_at + @status_refresh < Time.now
					@last_status_at = Time.now
					enqueue(COMMANDS[:report_status])
				end
			else
				if @reset_at + @sync_timeout < Time.now
					STDERR.puts "! Couldn't sync, retrying by :reset."
					handle_received(:reset)
				end
			end
		else
			# handle packet -- XXX: we might get stray packet regardless of status
			case packet.first
			when 0x04 # received device id (in response to init?)
				if @state == :initial
					@state = :init_followup
					enqueue(INIT_FOLLOWUP)
				else
					STDERR.puts "! Received out of sequence did packet: #{packet.inspect}"
				end
			when 0x00 # response to init followup?
				if @state == :init_followup
					@state = :synced
					@last_status_at = Time.now
					# Apply initial intent per tri-state configuration:
					#   :absent         => upstream legacy INITIAL_INTENT
					#   :configured     => configured @initial_intent_config
					#   :present_empty  => no initial intent applied
					if @initial_intent_mode == :absent || @initial_intent_mode == :configured
						add_intent({initial: true})
					end
					if packet != [0, 2, 0]
						STDERR.puts "? Received unexpected init_followup packet: #{packet.inspect}"
					end
				else
					puts "? Received: #{packet.inspect}" # FIXME
				end
			when 0x05 # device status reply
				params = parse_device_status(packet)
				puts "+ DS: #{params.map { |k,v| "#{k}:#{v}" }.join(',')}"
				@device_state = params

				# Crash recovery: after the first device-state observation,
				# attempt to restore the persistent session snapshot if one
				# exists. We do this exactly once and only if no live session
				# is currently active.
				if !@snapshot_recovered
					@snapshot_recovered = true
					recover_session_snapshot
				end

				if @intent[:initial]
					# Initial-intent handling. Tri-state picks the source intent.
					intent = (@initial_intent_mode == :configured ? @initial_intent_config : INITIAL_INTENT).dup
					if @device_state[:power] && @device_state[:input] == :bluetooth
						# we probably just woke up the device → put it back to sleep @ HDMI
						intent.update({input: :hdmi, power: false})
					end
					rest_of_intent = @intent.dup
					rest_of_intent.delete(:initial)
					intent.update(rest_of_intent)
					@intent = intent
				elsif @intent[:start_session]
					name = @intent.delete(:start_session)
					if @session
						STDERR.puts "! Starting a new session '#{name}' while" +
							" '#{@session.first}' active; re-using the DS:" +
							" #{@session.last.inspect}; intent:" +
							" #{@intent.inspect}."
						@session = [name, @session.last]
					else
						puts "+ Starting a new session '#{name}' with" +
							" intent: #{@intent.inspect}."
						@session = [name, @device_state.dup]
						persist_session_snapshot(name, @session.last)
					end
				elsif @intent[:stop_session]
					name = @intent.delete(:stop_session)
					if @session
						if @session.first != name
							STDERR.puts "! Terminating session '#{name}' while" +
								" '#{@session.first}' active."
						end
						saved = @session.last
						@session = nil
						# Persist snapshot BEFORE we clear @intent, so a crash
						# mid-restore still allows the next restart to recover.
						persist_session_snapshot(name, saved)
						# Capture the saved mute value BEFORE any mutation --
						# the deferred-final-mute is restored later from this
						# capture.
						@deferred_final_mute = saved[:mute] if saved.key?(:mute)
						# Strip :power from restore if not managing power.
						restore_state = @manage_power ? saved : saved.reject { |k, _| k == :power }
						@intent.update(restore_state)
						# SAFETY INVARIANT: temporary mute BEFORE any other
						# state change so the staged restore cannot blast TV
						# audio at music-session volume.
						@intent[:mute] = true
						@restore_phase = :mute
						@restore_phase_status_refreshed = false
						@restore_volume_attempts = 0
						@restore_volume_homed = false
						@restore_error = nil
						@restore_id += 1
						@restoring_session = true
						@restore_requested = false
					else
						@restore_requested = false
					end
				end
				# and now enforce it
				if @restoring_session && @restore_phase
					unless @restore_phase == :failed
						@intent = enforce_staged_restore(@intent, @device_state.dup)
					end
					if @restoring_session && @intent.empty? && @restore_phase.nil?
						# Restore fully settled.
						@restoring_session = false
						delete_session_snapshot
					end
				elsif !@intent.empty?
					keys = @restoring_session ? RESTORE_KEYS : APPLY_KEYS
					@intent = enforce_intent(@intent, keys_to_enforce: keys)
				end
			when 0x12 # volume/mute reply to report_volume (03 12)
				params = parse_volume_status(packet)
				@device_state.update(params)
				puts "+ VS: mute:#{params[:mute]},volume:#{params[:volume]}"
				if @restoring_session && @restore_phase
					@intent = handle_restore_volume_status(@intent, params)
				end
			else
				puts "? Received: #{packet.inspect}" # FIXME
			end
		end
	end

	private def parse_device_status(pkt)
		params = {}
		params[:power] = !pkt[2].zero?
		params[:input] = INPUT_NAMES[pkt[3]] || pkt[3]
		params[:mute] = !pkt[4].zero?
		params[:volume] = pkt[5]
		params[:subwoofer] = pkt[6]
		srd = (pkt[10] << 8) + pkt[11]
		params[:surround] = SURROUND_NAMES[srd] || srd
		params[:bass_ext] = !(pkt[12] & 0x20).zero?
		params[:clearvoice] = !(pkt[12] & 0x4).zero?
		params
	end

	private def parse_volume_status(pkt)
		{
			mute: !pkt[1].zero?,
			volume: pkt[2],
		}
	end

	private def enqueue(command)
		cmd = YamahaPacketCodec.encode(command)
		@queue.push([Time.now, cmd])
		cmd
	end

	# Add given intent
	private def add_intent(intent)
		@intent.update(intent)
		enqueue(COMMANDS[:report_status])
		@intent.dup
	end

	# Enforce given intent and return whatever couldn't have been enforced.
	private def enforce_intent(intent, keys_to_enforce: APPLY_KEYS)
		intent = intent.dup
		retried = intent.delete(:enforce_retried)
		device_state = @device_state.dup

		# If power is not managed, strip :power from intent before computing deltas.
		intent.delete(:power) unless @manage_power

		delta_keys = intent.keys.reduce([]) { |m, x| m << x unless device_state[x] == intent[x]; m }

		return {} if delta_keys.empty? # zero diff → stable state reached
		# also zero diff (mute doesn't work when powered off) >>
		return {} if delta_keys == [:mute] && device_state[:power] == false

		# Pathological case: device is off but other intents exist. Upstream
		# auto-powers-on here; we only do so when manage_power is true.
		if @manage_power && !device_state[:power] && !(delta_keys - [:power]).empty?
			enqueue(COMMANDS[:power_on]) # turn on
			device_state[:power] = true # mark it's on
			delta_keys << :power unless delta_keys.include?(:power)
			intent[:power] ||= false # force off (unless intended otherwise)
		end

		# First power on (if needed); also gated on manage_power.
		if @manage_power && intent[:power] && !device_state[:power]
			enqueue(COMMANDS[:power_on])
		end

		# Enforce individual keys in the provided order.
		(keys_to_enforce & delta_keys).each do |k|
			case k
			when :input
				enqueue(COMMANDS[('set_input_' + intent[k].to_s).to_sym])
			when :volume
				delta = intent[:volume] - device_state[:volume]
				delta.abs.times {
					enqueue(COMMANDS[delta < 0 ? :volume_down : :volume_up]) }
			when :subwoofer
				delta = intent[:subwoofer] - device_state[:subwoofer]
				(delta.abs / 4).times {
					enqueue(
						COMMANDS[delta < 0 ? :subwoofer_down : :subwoofer_up]) }
			when :surround
				enqueue(COMMANDS[('set_surround_' + intent[k].to_s).to_sym])
			when :mute, :bass_ext, :clearvoice, :power
				enqueue(COMMANDS[(k.to_s + (intent[k] ? '_on' : '_off')).to_sym])
			else
				STERR.puts "! enforce_intent for unimplemented key: #{k}"
			end
		end

		if retried
			STDERR.puts "~ enforce_intent: loop breaker: #{intent.inspect} on #{device_state}, delta: #{delta_keys}" if $VERBOSE || $DEBUG
			{}
		else
			# had a diff, let's have another round after this one
			enqueue(COMMANDS[:report_status])
			intent.update({enforce_retried: true}) # avoid endless looping
		end
	end

	# Send raw command to device -- called by end users (if they speak raw).
	#
	# @param command [Array<Integer>, String] command understood by `YamahaPacketCodec.encode()`.
	# @raise [RuntimeError] when device not ready
	def send_raw(command)
		ensure_not_restoring!
		if @state == :synced
			enqueue(command)
		else
			raise RuntimeError, "device not ready"
		end
	end

	# Send a command to device -- called by end users.
	#
	# @param command [Symbol, String] name of the command to send.
	# @raise [RuntimeError] when device not ready
	# @raise [ArgumentError] when the command is wrong
	def send(command)
		ensure_not_restoring!
		if @state == :synced
			if c = COMMANDS[command.to_sym]
				enqueue(c)
				command.to_sym
			else
				raise ArgumentError, "unknown command: #{command}"
			end
		else
			raise RuntimeError, "device not ready"
		end
	end

	# Start a session with a given intent to device -- called by end users.
	#
	# @param name [String] session name.
	# @param intent [Hash<String, Object>] intent to send.
	# @raise [RuntimeError] when device not ready
	# @raise [ArgumentError] when the intent is wrong
	def start_session(name, intent)
		ensure_not_restoring!
		if @state == :synced
			add_intent(parse_intent(intent).update({start_session: name}))
		else
			raise RuntimeError, "device not ready"
		end
	end

	# Terminate a session -- called by end users.
	#
	# @param name [String] session name.
	# @raise [RuntimeError] when device not ready
	# @raise [ArgumentError] when the intent is wrong
	def stop_session(name)
		ensure_not_restoring!
		if @state == :synced
			@restore_requested = true
			begin
				add_intent({stop_session: name})
			rescue
				@restore_requested = false
				raise
			end
		else
			raise RuntimeError, "device not ready"
		end
	end

	# Send a given intent to device -- called by end users.
	#
	# @param intent [Hash<String, Object>] intent to send.
	# @raise [RuntimeError] when device not ready
	# @raise [ArgumentError] when the intent is wrong
	def send_intent(intent)
		ensure_not_restoring!
		if @state == :synced
			add_intent(parse_intent(intent))
		else
			raise RuntimeError, "device not ready"
		end
	end

	private def ensure_not_restoring!
		if @restore_requested || @restoring_session
			raise RuntimeError, "session restore in progress"
		end
	end

	private def parse_intent(intent)
		validated_intent = {}
		is_bool = proc { |x|
			unless x === true || x === false
				raise ArgumentError, "must be bool"
			else
				x
			end
		}
		valid_keys = {
			power: is_bool,
			mute: is_bool,
			bass_ext: is_bool,
			clearvoice: is_bool,
			input: proc { |x|
				if INPUT_NAMES.values.include?(x.to_sym)
					x.to_sym
				else
					raise ArgumentError, "must be one of: #{INPUT_NAMES.values.inspect}"
				end
			},
			volume: proc { |x|
				if VOLUME_RANGE.include?(Integer(x))
					Integer(x)
				else
					raise ArgumentError, "must be integer in: #{VOLUME_RANGE}"
				end
			},
			subwoofer: proc { |x|
				if SUBWOOFER_DOMAIN.include?(Integer(x))
					Integer(x)
				else
					raise ArgumentError, "must be integer in: #{SUBWOOFER_DOMAIN}"
				end

			},
			surround: proc { |x|
				if SURROUND_NAMES.values.include?(x.to_sym)
					x.to_sym
				else
					raise ArgumentError, "must be one of: #{SURROUND_NAMES.values.inspect}"
				end
			},
		}
		validated_intent = intent.map { |k, v|
			raise ArgumentError, "invalid key: #{k}" unless valid_keys[k.to_sym]
			begin
				[k.to_sym, valid_keys[k.to_sym][v]]
			rescue
				raise ArgumentError, "#{k} #$!"
			end
		}.to_h
		# manage_power=false: strip :power from user-supplied intents.
		validated_intent.delete(:power) unless @manage_power
		validated_intent
	end

	# Fetch next packet to be sent to device -- called by comm handler.
	#
	# @return [String, nil] packet that was enqueued, or `nil` when none
	def pop
		ts, payload = @queue.pop(true)
		if $DEBUG || $VERBOSE
			STDERR.puts "~ Dequeued #{payload.inspect} after #{"%.02f" % (Time.now - ts)}s."
		end
		payload
	rescue ThreadError
		nil
	end

	# ---- session snapshot persistence (process-crash recovery) ----

	private def persist_session_snapshot(name, saved)
		File.write(@snapshot_path, JSON.pretty_generate({
			'name' => name,
			'saved_state' => saved,
			'captured_at' => Time.now.utc.iso8601,
		}))
		File.chmod(0600, @snapshot_path)
	rescue => e
		STDERR.puts "! Failed to persist session snapshot: #{e}"
	end

	private def delete_session_snapshot
		File.unlink(@snapshot_path) if File.exist?(@snapshot_path)
	rescue => e
		STDERR.puts "! Failed to delete session snapshot: #{e}"
	end

	private def recover_session_snapshot
		return unless File.exist?(@snapshot_path)
		data = JSON.parse(File.read(@snapshot_path))
		name = data['name']
		saved = data['saved_state']
		return unless name && saved
		# Symbolize keys for parity with @device_state.
		saved_sym = saved.each_with_object({}) { |(k, v), h| h[k.to_sym] = v }
		@session = [name, saved_sym]
		puts "! Recovered session from snapshot: name=#{name}, saved=#{saved_sym.inspect}"
	rescue => e
		STDERR.puts "! Failed to recover session snapshot: #{e}"
	end

	# ---- staged session restore ----

	# Dispatch to the current restore phase. Each phase is responsible for
	# advancing @restore_phase once its verification criteria are met.
	private def enforce_staged_restore(intent, device_state)
		# Strip :power from intent unless we manage it.
		intent.delete(:power) unless @manage_power

		case @restore_phase
		when :mute
			enforce_restore_mute_phase(intent, device_state)
		when :volume
			enforce_restore_volume_phase(intent, device_state)
		when :sound
			enforce_restore_sound_phase(intent, device_state)
		when :input
			enforce_restore_input_phase(intent, device_state)
		when :final_mute
			enforce_restore_final_mute_phase(intent, device_state)
		else
			@restore_error = "unknown restore phase: #{@restore_phase}"
			@restore_phase = :failed
			STDERR.puts "! #{@restore_error}; input remains unchanged and snapshot is preserved."
			intent
		end
	end

	# Phase :mute -- force temporary mute on and verify.
	#
	# Forces mute_on, then queues a fresh status readback so the next 0x05
	# reply confirms whether the device actually muted. Bounded retry.
	private def enforce_restore_mute_phase(intent, device_state)
		unless device_state[:mute]
			unless @restore_phase_status_refreshed
				@restore_phase_status_refreshed = true
				enqueue(COMMANDS[:mute_on])
				enqueue(COMMANDS[:report_status])
				return intent.update({enforce_retried: true})
			end

			@restore_volume_attempts += 1
			if @restore_volume_attempts > MAX_VOLUME_RESTORE_CORRECTIONS
				fail_restore('temporary mute not confirmed')
				return intent
			end
			enqueue(COMMANDS[:mute_on])
			enqueue(COMMANDS[:report_status])
			return intent.update({enforce_retried: true})
		end

		# Mute confirmed; advance to :volume.
		@restore_phase = :volume
		@restore_phase_status_refreshed = false
		@restore_volume_attempts = 0
		@restore_volume_homed = false
		enqueue(COMMANDS[:report_status])
		intent.update({enforce_retried: true})
	end

	# Phase :volume -- drive volume to the saved value, with bounded
	# correction. The 0x12 reply is the completion barrier.
	private def enforce_restore_volume_phase(intent, device_state)
		target = intent[:volume]
		return advance_restore_to_sound(intent) unless target

		# If we already see the saved volume + mute, advance.
		if device_state[:volume] == target && device_state[:mute]
			return advance_restore_to_sound(intent)
		end

		# Re-mute defensively (volume_up/down clear mute on real hardware)
		# before any volume step.
		enqueue(COMMANDS[:mute_on])

		# If the volume matches target but mute is lost, re-mute and re-check.
		if device_state[:volume] == target
			enqueue(COMMANDS[:report_status])
			return intent.update({enforce_retried: true})
		end

		delta = target - device_state[:volume]
		command = delta.negative? ? :volume_down : :volume_up
		delta.abs.times { enqueue(COMMANDS[command]) }
		# Always reassert mute after the volume walk, then ask for a
		# fresh volume/mute readback (0x12).
		enqueue(COMMANDS[:mute_on])
		enqueue(COMMANDS[:report_volume])
		intent.update({enforce_retried: true})
	end

	# Phase :sound -- restore clearvoice / surround / bass_ext / subwoofer.
	private def enforce_restore_sound_phase(intent, device_state)
		sound_keys = [:clearvoice, :surround, :bass_ext, :subwoofer]
		delta_sound_keys = intent.keys & sound_keys
		actual_delta = delta_sound_keys.reject { |k| device_state[k] == intent[k] }

		if actual_delta.empty?
			@restore_phase_status_refreshed = false
			@restore_phase = :input
			enqueue(COMMANDS[:report_status])
			return intent.update({enforce_retried: true})
		end

		# Force a fresh status readback on the first pass of this phase.
		unless @restore_phase_status_refreshed
			@restore_phase_status_refreshed = true
			enqueue(COMMANDS[:report_status])
			return intent.update({enforce_retried: true})
		end

		(RESTORE_KEYS & actual_delta).each do |k|
			case k
			when :subwoofer
				d = intent[:subwoofer] - device_state[:subwoofer]
				(d.abs / 4).times {
					enqueue(COMMANDS[d < 0 ? :subwoofer_down : :subwoofer_up]) }
			when :surround
				enqueue(COMMANDS[('set_surround_' + intent[:surround].to_s).to_sym])
			when :clearvoice, :bass_ext
				enqueue(COMMANDS[(k.to_s + (intent[k] ? '_on' : '_off')).to_sym])
			end
		end
		enqueue(COMMANDS[:report_status])
		intent.update({enforce_retried: true})
	end

	# Phase :input -- restore the input. Only runs after :volume AND :sound
	# have converged. If saved input already matches current input, advance.
	private def enforce_restore_input_phase(intent, device_state)
		unless @restore_phase_status_refreshed
			@restore_phase_status_refreshed = true
			enqueue(COMMANDS[:report_status])
			return intent.update({enforce_retried: true})
		end

		if device_state[:input] == intent[:input]
			@restore_phase = :final_mute
			@restore_phase_status_refreshed = false
			enqueue(COMMANDS[:report_volume])
			return intent
		end

		enqueue(COMMANDS[('set_input_' + intent[:input].to_s).to_sym])
		enqueue(COMMANDS[:report_status])
		intent.update({enforce_retried: true})
	end

	# Phase :final_mute -- apply the deferred final mute value and verify.
	private def enforce_restore_final_mute_phase(intent, device_state)
		# We rely on the 0x12 reply to act, since the input switch may have
		# just changed the device state. Force a fresh status readback here.
		unless @restore_phase_status_refreshed
			@restore_phase_status_refreshed = true
			enqueue(COMMANDS[:report_volume])
			return intent.update({enforce_retried: true})
		end

		# The actual decision is made in handle_restore_volume_status once
		# the 0x12 reply arrives, since volume/mute are the relevant fields.
		intent
	end

	# Handle 0x12 (volume/mute) reply during staged restore.
	private def handle_restore_volume_status(intent, status)
		target = intent[:volume]
		return advance_restore_to_sound(intent) unless target

		if @restore_phase == :volume
			# First attempt: direct correction worked.
			if status[:volume] == target && status[:mute]
				return advance_restore_to_sound(intent)
			end

			# Volume correct but mute lost -- re-mute and ask again.
			if status[:volume] == target
				@restore_volume_attempts += 1
				if @restore_volume_attempts > MAX_VOLUME_RESTORE_CORRECTIONS
					return fail_restore("temporary mute not retained: volume=#{status[:volume]} mute=#{status[:mute]}")
				end
				enqueue(COMMANDS[:mute_on])
				enqueue(COMMANDS[:report_volume])
				return intent
			end

			# Volume not converged. Try direct correction up to N times.
			@restore_volume_attempts += 1
			if @restore_volume_attempts <= MAX_VOLUME_RESTORE_CORRECTIONS
				STDERR.puts "! Correcting volume mismatch: target=#{target} actual=#{status[:volume]} attempt=#{@restore_volume_attempts}"
				enqueue(COMMANDS[:mute_on])
				delta = target - status[:volume]
				command = delta.negative? ? :volume_down : :volume_up
				delta.abs.times { enqueue(COMMANDS[command]) }
				enqueue(COMMANDS[:mute_on])
				enqueue(COMMANDS[:report_volume])
				return intent
			end

			# Direct correction failed -- try homing to lower boundary first.
			unless @restore_volume_homed
				@restore_volume_homed = true
				STDERR.puts "! Direct volume correction failed; homing to raw 0 before restoring #{target}."
				# Drive to lower bound with margin, then back up.
				(VOLUME_RANGE.max + VOLUME_HOME_MARGIN).times { enqueue(COMMANDS[:volume_down]) }
				enqueue(COMMANDS[:mute_on])
				target.times { enqueue(COMMANDS[:volume_up]) }
				enqueue(COMMANDS[:mute_on])
				enqueue(COMMANDS[:report_volume])
				return intent
			end

			return fail_restore("volume mismatch after homing: target=#{target} actual=#{status[:volume]}")
		end

		if @restore_phase == :final_mute
			final_mute = @deferred_final_mute
			if status[:volume] != target
				return fail_restore("volume changed during input restoration: target=#{target} actual=#{status[:volume]}")
			end

			# Determine whether we need to apply the deferred final mute.
			unless final_mute.nil?
				if status[:mute] != final_mute
					@restore_volume_attempts += 1
					if @restore_volume_attempts > MAX_VOLUME_RESTORE_CORRECTIONS
						return fail_restore("final mute not applied: target=#{final_mute} actual=#{status[:mute]}")
					end
					enqueue(COMMANDS[final_mute ? :mute_on : :mute_off])
					enqueue(COMMANDS[:report_volume])
					return intent
				end
			end

			# Verification complete -- end restore.
			@restore_phase = nil
			@restoring_session = false
			@restore_error = nil
			@deferred_final_mute = nil
			delete_session_snapshot
			return {}
		end

		intent
	end

	private def advance_restore_to_sound(intent)
		@restore_phase = :sound
		@restore_phase_status_refreshed = false
		@restore_volume_attempts = 0
		enqueue(COMMANDS[:report_status])
		intent
	end

	private def fail_restore(reason)
		@restore_error = reason
		@restore_phase = :failed
		STDERR.puts "! Restore failed; input will not be changed further and snapshot is preserved: #{reason}"
		{}
	end
end

if __FILE__ == $0
	STDOUT.sync = true

	ysr = YamahaSoundbarRemote.new
	threads = []

	threads << Thread.new do
		print "+ BT handler init...\n"  # $10 to the first person explaining why not `puts`
		YamahaSerialInputWorker.as_thread(ysr.rfcomm_device, ysr)
	end

	threads << Thread.new do
		print "+ Webserver...\n"
		s = WEBrick::HTTPServer.new({
			:Port => ysr.http_port,
			:BindAddress => ysr.http_bind,
			:Logger => WEBrick::Log.new('/dev/null'),
			:AccessLog => [ [$stdout, "> %h %U %b"] ],
			:DoNotReverseLookup => true,
		})

		s.mount_proc("/send") do |req, res|
			q = req.query
			res['Content-Type'] = 'text/plain; charset=utf-8'
			if q["data"]
				out = []
				for code in q["data"].split(/,/)
					begin
						sent = ysr.send_raw(code)
						out << "sent #{sent.scan(/./m).map{|x| "%02x" % x.ord}.join}.\n"
					rescue
						out << "failed to send #{q["data"].inspect}: #{$!}.\n"
						break
					end
				end
				res.body = out.join
			elsif q["commands"]
				out = []
				for command in q["commands"].split(/,/)
					begin
						sent = ysr.send(command)
						out << "sent #{sent}.\n"
					rescue
						out << "failed to send #{q["command"].inspect}: #{$!}.\n"
						break
					end
				end
				res.body = out.join
			elsif q["intent"]
				out = []
				begin
					sent = ysr.send_intent(JSON.parse(q['intent']))
					out << "send intent: #{sent}.\n"
				rescue
					out << "failed to send intent #{q["intent"].inspect}: #{$!}.\n"
				end
				res.body = out.join
			else
				res.body = "nope (missing params: either data or commands).\n"
			end
		end

		s.mount_proc("/start-session") do |req, res|
			q = req.query
			res['Content-Type'] = 'text/plain; charset=utf-8'
			out = []
			if q["name"] && q["intent"]
				begin
					reply = ysr.start_session(q['name'], JSON.parse(q['intent']))
					out << "start session: #{reply}.\n"
				rescue
					out << "failed to start session: #{$!}.\n"
				end
				res.body = out.join
			else
				res.body = "nope (missing params: either name or intent).\n"
			end
		end

		s.mount_proc("/stop-session") do |req, res|
			q = req.query
			res['Content-Type'] = 'text/plain; charset=utf-8'
			out = []
			if q["name"]
				begin
					reply = ysr.stop_session(q['name'])
					out << "stop session: #{reply}.\n"
				rescue
					out << "failed to stop session: #{$!}.\n"
				end
				res.body = out.join
			else
				res.body = "nope (missing params: either name or intent).\n"
			end
		end

		# /state returns a JSON snapshot of current device state plus the
		# session model (name, active, restoring, current phase). Players
		# can use it to positively confirm session-restore completion
		# before they tear down their own resources.
		s.mount_proc("/state") do |req, res|
			res['Content-Type'] = 'application/json; charset=utf-8'
			res.body = JSON.pretty_generate({
				'device_state' => ysr.device_state,
				'session' => {
					'name'          => ysr.session ? ysr.session.first : nil,
					'active'        => !ysr.session.nil?,
					'restoring'     => ysr.restoring_session,
					'restore_phase' => ysr.restore_phase,
					'restore_error' => ysr.restore_error,
				},
			})
		end

		s.mount_proc("/") do |req, res|
			out = []
			if req.query['json'] || req.accept.include?("application/json")
				res['Content-Type'] = 'application/json; charset=utf-8'
				out << JSON.pretty_generate(ysr.device_state)
			else
				res['Content-Type'] = 'text/html; charset=utf-8'
				out << <<-EOF
<!DOCTYPE html>
<html lang="en">
<head>      
<meta charset="UTF-8">
<title>YAS-207 control</title>
<meta name="viewport" content="width=device-width">
</head>
<body>
				EOF
				out.last.strip!

				out << "<h1>YAS-207 control</h1>"
				out << "<pre>" + ysr.device_state.inspect + "</pre>"
				out << "</body>\n</html>"
			end
			res.body = out.join("\n")
			res
		end

		s.start 
	end

	begin
		threads.map(&:join)
	rescue Interrupt
		threads.map(&:kill)
	end
end
