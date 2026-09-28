#!/usr/bin/env ruby

# Author: Michal Jirku (wejn.org)
# Modifications: fortiko (https://github.com/fortiko/yamaha-yas-207)
# License: GNU Affero General Public License v3.0
#
# This file is a backwards-compatible extension of wejn's upstream
# YamahaSoundbarRemote. See docs/configuration.md for the configuration
# schema and docs/profiles.md for the rationale of policy values.

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

		# status reports (queries; soundbar returns 0x05 and 0x12 respectively)
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

	# Initial intent enforced at the first sync if no `controller.initial_intent`
	# config key is present. (Tri-state: key absent => this legacy default;
	# key present as {} => no intent; key present non-empty => configured.)
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
	# restore final mute state via deferred follow-up.
	#
	# NOTE: :input is intentionally NOT in this list. Input switching is
	# deferred to a separate restore phase (:input) that runs only AFTER
	# the :volume phase has positively converged to the saved level.
	# This is the closed-loop-with-verification behaviour required to
	# prevent the input from changing before the volume has been confirmed
	# to match the saved value.
	RESTORE_KEYS = [
		:mute, :volume, :surround, :bass_ext, :clearvoice, :subwoofer
	].freeze

	# Staged restore phases.
	# :mute     force and verify temporary mute
	# :volume   restore volume transactionally, with bounded correction
	# :sound    restore clearvoice / surround / bass_ext / subwoofer
	# :input    restore input (only after :volume AND :sound verified)
	# :post_input_volume verify volume/mute again while still muted
	# :final_mute restore saved mute value
	# :final_power restore saved power value LAST. Only entered when the
	#              snapshot positively records this session owning an
	#              off->on transition (saved_state.power==false AND
	#              power_on_completed==true). Otherwise the phase is
	#              skipped entirely.
	RESTORE_PHASES = [
		:mute, :volume, :sound, :input, :post_input_volume, :final_mute,
		:final_power
	].freeze

	# A distinct 0x12 reply is the completion barrier for volume operations.
	# Try direct correction first, then home to the lower boundary if needed.
	MAX_VOLUME_RESTORE_CORRECTIONS = 2
	VOLUME_HOME_MARGIN = 5

	# Maximum time we synchronously wait for the Yamaha to confirm power=true
	# after issuing power_on during an explicit start_session wake-up.
	# Sized for real hardware (YAS-207 wakes from standby in ~1.5s; we leave
	# headroom for repeated retries and SPP latency).
	POWER_ON_TIMEOUT = 10.0
	# Bounded retry budget for the :final_power phase to confirm power=false.
	# Kept conservative so a stuck-CEC device doesn't loop forever.
	MAX_FINAL_POWER_ATTEMPTS = 2
	RESTORE_QUERY_TIMEOUT = 2.0

	# Bounded verification window for the idle-input sanitization
	# correction: after issuing the set_input command, this is how long we
	# wait for a device status report confirming the policy input before
	# giving up (the correction re-arms on the next idle observation of
	# input=:bluetooth).
	IDLE_INPUT_CORRECTION_TIMEOUT = 15.0

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
		# Session-scoped power ownership: only effective when @manage_power is
		# false. With @manage_power=true (legacy auto-power-on), this flag is
		# moot -- the upstream auto-power-on path runs as it always did.
		@power_on_for_session_starts =
			ctrl.key?('power_on_for_session_starts') ?
				!!ctrl['power_on_for_session_starts'] : false
		@runtime_dir      = self.class.runtime_dir
		@snapshot_path    = File.join(@runtime_dir, 'controller', 'session.json')
		FileUtils.mkdir_p(File.dirname(@snapshot_path))

		# Tri-state initial_intent handling.
		# :absent   => apply legacy INITIAL_INTENT on first sync
		# :present_empty => apply NO initial intent
		# :configured => apply exactly @initial_intent_config
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

		# Post-init / SPP-reconnect idle input sanitization. Disabled (nil)
		# unless controller.idle_input_policy is set, preserving upstream
		# behaviour by default. When set to an input name (e.g. "tv"), an
		# IDLE device -- powered on, no active session, no restore in
		# progress, no pending intent -- that is observed with
		# input=:bluetooth (e.g. woken by an SPP/RFCOMM reconnect) is
		# corrected to that input and verified via the next device status
		# report. SPP/RFCOMM stays control-only; this never touches power,
		# sessions, or restore state.
		@idle_input_policy = nil
		if ctrl.key?('idle_input_policy') && !ctrl['idle_input_policy'].nil?
			policy = ctrl['idle_input_policy']
			unless policy.is_a?(String) && !policy.empty?
				raise ArgumentError,
					"controller.idle_input_policy must be a non-empty input " +
					"name string, got #{policy.inspect}"
			end
			unless COMMANDS.key?(:"set_input_#{policy}")
				raise ArgumentError,
					"controller.idle_input_policy '#{policy}' has no " +
					"set_input command"
			end
			@idle_input_policy = policy.to_sym
		end

		@device_state = {}
		@queue = Queue.new
		@state = :initial
		@intent = {}
		@session = nil
		@restoring_session = false
		@restore_requested = false
		@deferred_final_mute = nil
		@snapshot_recovered = false
		@restore_phase = nil
		@restore_phase_status_refreshed = false
		@restore_volume_attempts = 0
		@restore_volume_homed = false
		@restore_error = nil
		@restore_id = 0
		@restore_query_sent_at = nil
		@enqueued_volume_queries = Queue.new
		@sent_volume_queries = Queue.new
		@status_generation = 0
		@volume_status_generation = 0

		# Session-scoped power ownership (see also @power_on_for_session_starts).
		# When a start_session wakes a sleeping Yamaha, we synchronously wait
		# for power=true on a ConditionVariable before queueing the music
		# intent. The serial worker thread signals the condvar from
		# handle_received when device_state[:power] flips to true.
		@wake_mutex = Mutex.new
		@wake_cond = ConditionVariable.new
		@wake_pending = false
		# Idle-input sanitization correction state (see sanitize_idle_input).
		@idle_input_correction_pending = false
		@idle_input_correction_at = nil
		# Snapshot-extended fields. These are only meaningful when a snapshot
		# has been persisted; defaults are conservative (no off->on owned,
		# no power-off at restore time).
		@snapshot_session_powered_on = false
		@snapshot_power_on_completed = false
		# Persistent saved-state reference used by :final_power to decide
		# whether to emit power_off. @session itself is cleared at
		# stop_session time, so we keep a separate copy. Populated by
		# stop_session, cleared when the staged restore settles (including
		# the :final_power phase).
		@restore_saved_state = nil
	end
	attr_reader :device_state, :session, :restoring_session, :restore_phase,
		:config, :runtime_dir, :rfcomm_device, :http_bind, :http_port,
		:sync_timeout, :status_refresh, :manage_power, :initial_intent_mode,
		:initial_intent_config, :snapshot_path, :restore_error,
		:status_generation, :volume_status_generation, :idle_input_policy,
		:power_on_for_session_starts

	# Handle packet received via serial.
	#
	# @param packet [Array<Integer>, :reset, :heartbeat] incoming packet
	def handle_received(packet)
		if packet == :reset
			@state = :initial
			@queue.clear # no use pushing anything when the comm broke
			@enqueued_volume_queries.clear
			@sent_volume_queries.clear
			@restore_query_sent_at = nil
			@idle_input_correction_pending = false
			@idle_input_correction_at = nil
			@reset_at = Time.now
			enqueue(INIT_STRING)
		elsif packet == :heartbeat
			if @restoring_session && @restore_query_sent_at &&
				monotonic_now - @restore_query_sent_at > RESTORE_QUERY_TIMEOUT
				fail_restore_volume(@intent, @device_state, 'timed out waiting for volume status')
			end
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
					# Trigger initial-intent application per tri-state.
					# :absent => upstream legacy; :configured => @initial_intent_config;
					# :present_empty => no initial intent applied.
					if @restoring_session
						@restore_phase = :mute
						@restore_volume_attempts = 0
						@restore_error = nil
						request_restore_mute_status
					elsif @initial_intent_mode == :absent || @initial_intent_mode == :configured
						add_intent({initial: true})
					end
					if packet != [0, 2, 0]
						STDERR.puts "? Received unexpected init_followup packet: #{packet.inspect}"
					end
				else
					puts "? Received: #{packet.inspect}" # FIXME
				end
			when 0x05 # aggregate device status reply to report_status (03 05)
				params = parse_device_status(packet)
				puts "+ DS: #{params.map { |k,v| "#{k}:#{v}" }.join(',')}"
				@device_state = params
				@status_generation += 1

				# Session-scoped wake-up: if start_session issued a synchronous
				# power_on and is waiting for verification, signal the condvar
				# the moment device_state[:power] flips to true. The waiting
				# thread (in start_session) wakes up, persists the
				# power_on_completed=true flag into the snapshot, and proceeds
				# with the music intent.
				if @wake_pending && @device_state[:power]
					@wake_mutex.synchronize { @wake_cond.broadcast }
				end

				# Crash recovery: after first device-state observation, attempt to
				# restore the persistent session snapshot if one exists. We do this
				# exactly once and only if no live session is currently active.
				if !@snapshot_recovered
					@snapshot_recovered = true
					recover_session_snapshot
				end

				# Post-init / SPP-reconnect idle input sanitization
				# (config-gated; see sanitize_idle_input).
				sanitize_idle_input

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
						# @session was pre-created by start_session BEFORE the
						# wake-up (if any). Its .last contains the pre-wake
						# saved_state; do NOT replace it with @device_state.dup
						# because by this point device_state[:power] may already
						# reflect the post-wake state. We just refresh the name
						# in case the same session is reused.
						if @session.first != name
							STDERR.puts "! Starting a new session '#{name}' while" +
								" '#{@session.first}' active; re-using the DS:" +
								" #{@session.last.inspect}; intent:" +
								" #{@intent.inspect}."
							@session = [name, @session.last]
						end
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
						# Persist snapshot BEFORE we clear @intent, so a crash mid-restore
						# still allows the next restart to recover.
						persist_session_snapshot(name, saved)
						# Keep an in-memory reference to saved so :final_power can
						# read saved_state[:power] after @session is gone.
						@restore_saved_state = saved
						# Strip :power from restore if not managing power.
						restore_state = @manage_power ? saved : saved.reject { |k, _| k == :power }
						@intent.update(restore_state)
						# SAFETY INVARIANT: temporary mute BEFORE volume/input changes
						# during stop_session restoration.
						@intent[:mute] = true
						# Defer final mute restoration until staged restore settles.
						@deferred_final_mute = saved[:mute] if saved.key?(:mute)
						# STAGED RESTORE PHASES:
						# 1. :mute     - force and verify temporary mute
						# 2. :volume   - restore volume as one verified transaction
						# 3. :sound    - clearvoice, surround, bass_ext, subwoofer
						# 4. :input    - restore input only after volume verification
						# 5. :final_mute - restore saved mute value
						@restore_phase = :mute
						@restore_phase_status_refreshed = false
						@restore_volume_attempts = 0
						@restore_volume_homed = false
						@restore_error = nil
						@restore_id += 1
						@restoring_session = true
						@restore_requested = false
						request_restore_mute_status
					else
						@restore_requested = false
					end
				end
				# and now enforce it
				if @restoring_session && @restore_phase
					unless [:mute, :volume, :post_input_volume, :final_mute, :failed].include?(@restore_phase)
						@intent = enforce_staged_restore(@intent, @device_state.dup)
					end
				elsif !@intent.empty?
					keys = @restoring_session ? RESTORE_KEYS : APPLY_KEYS
					@intent = enforce_intent(@intent, keys_to_enforce: keys)
				else
					# After restore settles, schedule the deferred final mute if any.
					if @restoring_session
						if !@deferred_final_mute.nil?
							final = @deferred_final_mute
							@deferred_final_mute = nil
							@intent = enforce_intent({mute: final}, keys_to_enforce: RESTORE_KEYS)
						else
							@restoring_session = false
							delete_session_snapshot
						end
					end
				end
			when 0x12 # volume/mute reply to report_volume (03 12)
				params = parse_volume_status(packet)
				@device_state.update(params)
				@volume_status_generation += 1
				puts "+ VS: mute:#{params[:mute]},volume:#{params[:volume]},generation:#{@volume_status_generation}"
				query = pop_queue(@sent_volume_queries)
				if query.is_a?(Hash) && query[:restore_id] == @restore_id &&
					query[:phase] == @restore_phase
					@restore_query_sent_at = nil
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

	private def monotonic_now
		Process.clock_gettime(Process::CLOCK_MONOTONIC)
	end

	private def pop_queue(queue)
		queue.pop(true)
	rescue ThreadError
		nil
	end

	private def enqueue(command, volume_query: nil)
		cmd = YamahaPacketCodec.encode(command)
		if cmd == YamahaPacketCodec.encode(COMMANDS[:report_volume])
			@enqueued_volume_queries.push(volume_query || :external)
		end
		@queue.push([Time.now, cmd])
		cmd
	end

	def handle_sent(command)
		return unless command == YamahaPacketCodec.encode(COMMANDS[:report_volume])

		query = pop_queue(@enqueued_volume_queries) || :external
		@sent_volume_queries.push(query)
		@restore_query_sent_at = monotonic_now if query.is_a?(Hash)
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
		if retried
			STDERR.puts "~ enforce_intent: loop breaker: #{intent.inspect} on #{device_state}, delta: #{delta_keys}" if $VERBOSE || $DEBUG
			return {}
		end

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
				STDERR.puts "! enforce_intent for unimplemented key: #{k}"
			end
		end

		# Had a diff; request one verification round without re-emitting the batch.
		enqueue(COMMANDS[:report_status])
		intent.update({enforce_retried: true})
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

	# Staged restore with explicit per-phase verification. The input phase is
	# unreachable until a distinct 0x12 reply has confirmed the saved volume.
	private def enforce_staged_restore(intent, device_state)
		# Strip :power from intent unless we manage it.
		intent.delete(:power) unless @manage_power

		case @restore_phase
		when :sound
			enforce_restore_sound_phase(intent, device_state)
		when :input
			enforce_restore_input_phase(intent, device_state)
		when :final_power
			enforce_restore_final_power_phase(intent, device_state)
		else
			@restore_error = "unknown restore phase: #{@restore_phase}"
			@restore_phase = :failed
			STDERR.puts "! #{@restore_error}; input remains unchanged and snapshot is preserved."
			intent
		end
	end

	# Phase :final_power -- the LAST phase of staged restore.
	#
	# Runs only when the snapshot positively records this session as the
	# owner of an off->on transition (saved_state.power==false AND
	# power_on_completed==true). Emits power_off and asks for a fresh
	# 0x05 readback; verification happens in the 0x05 branch below.
	#
	# On confirmation of power=false: snapshot removed, restore settles.
	# On persistent failure: log via @restore_error and settle anyway
	# -- a stuck-CEC Yamaha that we cannot power off is less disruptive
	# than leaving a stuck restore in progress.
	private def enforce_restore_final_power_phase(intent, device_state)
		if !@restore_phase_status_refreshed
			@restore_phase_status_refreshed = true
			enqueue(COMMANDS[:report_status])
			return intent.update({enforce_retried: true})
		end

		if !device_state[:power]
			# Power confirmed off. Done.
			@restore_phase = nil
			@restoring_session = false
			@restore_error = nil
			@restore_saved_state = nil
			@snapshot_session_powered_on = false
			@snapshot_power_on_completed = false
			delete_session_snapshot
			return {}
		end

		# Power is still on. Bounded retry of power_off.
		@restore_volume_attempts += 1
		if @restore_volume_attempts <= MAX_FINAL_POWER_ATTEMPTS
			STDERR.puts "! Final power-off retry: device still on (attempt #{@restore_volume_attempts})"
			enqueue(COMMANDS[:power_off])
			enqueue(COMMANDS[:report_status])
			return intent.update({enforce_retried: true})
		end

		# Bounded retry exhausted. Conservative settle: log the failure
		# via @restore_error but don't strand the snapshot. The Yamaha is
		# left on; if the user explicitly wants it off they can do so
		# manually. We DO NOT loop forever.
		@restore_error = "final power-off could not be confirmed after #{MAX_FINAL_POWER_ATTEMPTS} attempts; device left on"
		STDERR.puts "! #{@restore_error}"
		@restore_phase = nil
		@restoring_session = false
		@restore_saved_state = nil
		@snapshot_session_powered_on = false
		@snapshot_power_on_completed = false
		delete_session_snapshot
		return {}
	end

	private def request_restore_mute_status
		enqueue(COMMANDS[:mute_on])
		enqueue_restore_volume_query(:mute)
	end

	private def enqueue_restore_volume_query(phase)
		enqueue(
			COMMANDS[:report_volume],
			volume_query: {restore_id: @restore_id, phase: phase},
		)
	end

	# Handle only replies to the narrow volume/mute query. Heartbeat status
	# packets cannot enter this feedback loop, eliminating stale compensation.
	private def handle_restore_volume_status(intent, status)
		return verify_restore_final_mute(intent, status) if @restore_phase == :final_mute
		return verify_post_input_volume(intent, status) if @restore_phase == :post_input_volume

		target = intent[:volume]
		return advance_restore_to_sound(intent) unless target

		if @restore_phase == :mute
			unless status[:mute]
				@restore_volume_attempts += 1
				return fail_restore_volume(intent, status, 'temporary mute not confirmed') if @restore_volume_attempts > MAX_VOLUME_RESTORE_CORRECTIONS

				request_restore_mute_status
				return intent
			end

			@restore_volume_attempts = 0
			return queue_restore_volume_delta(intent, target - status[:volume])
		end

		return advance_restore_to_sound(intent) if status[:volume] == target && status[:mute]

		if status[:volume] == target
			@restore_volume_attempts += 1
			return fail_restore_volume(intent, status, 'temporary mute not retained') if @restore_volume_attempts > MAX_VOLUME_RESTORE_CORRECTIONS

			enqueue(COMMANDS[:mute_on])
			enqueue_restore_volume_query(:volume)
			return intent
		end

		@restore_volume_attempts += 1
		if @restore_volume_attempts <= MAX_VOLUME_RESTORE_CORRECTIONS
			STDERR.puts "! Correcting verified volume mismatch: target=#{target} actual=#{status[:volume]} attempt=#{@restore_volume_attempts}"
			return queue_restore_volume_delta(intent, target - status[:volume])
		end

		unless @restore_volume_homed
			@restore_volume_homed = true
			STDERR.puts "! Direct volume correction failed; homing to raw 0 before restoring #{target}."
			queue_restore_volume_steps(:volume_down, VOLUME_RANGE.max + VOLUME_HOME_MARGIN)
			queue_restore_volume_steps(:volume_up, target)
			enqueue_restore_volume_query(:volume)
			return intent
		end

		fail_restore_volume(intent, status, 'volume mismatch after lower-bound homing')
	end

	private def queue_restore_volume_delta(intent, delta)
		return advance_restore_to_sound(intent) if delta.zero?

		@restore_phase = :volume
		queue_restore_volume_steps(delta.negative? ? :volume_down : :volume_up, delta.abs)
		enqueue_restore_volume_query(:volume)
		intent
	end

	# Relative volume commands clear mute on real hardware. Reassert mute after
	# every step so the unmuted interval is bounded by the TX cadence.
	private def queue_restore_volume_steps(command, count)
		count.times do
			enqueue(COMMANDS[command])
			enqueue(COMMANDS[:mute_on])
		end
	end

	private def advance_restore_to_sound(intent)
		@restore_phase = :sound
		@restore_phase_status_refreshed = true
		enqueue(COMMANDS[:report_status])
		intent
	end

	private def fail_restore_volume(intent, status, reason)
		@restore_error = "#{reason}: target=#{intent[:volume]} actual=#{status[:volume]}"
		@restore_phase = :failed
		@restore_query_sent_at = nil
		STDERR.puts "! Restore failed; input will not be changed further and snapshot is preserved: #{@restore_error}"
		intent
	end

	private def begin_restore_final_mute(intent)
		@restore_phase = :final_mute
		@restore_volume_attempts = 0
		unless @deferred_final_mute.nil?
			enqueue(COMMANDS[@deferred_final_mute ? :mute_on : :mute_off])
		end
		enqueue_restore_volume_query(:final_mute)
		intent
	end

	private def verify_post_input_volume(intent, status)
		unless status[:volume] == intent[:volume] && status[:mute]
			enqueue(COMMANDS[:mute_on]) unless status[:mute]
			return fail_restore_volume(intent, status, 'volume/mute changed during input restoration')
		end

		begin_restore_final_mute(intent)
	end

	private def verify_restore_final_mute(intent, status)
		final_mute = @deferred_final_mute
		if status[:volume] != intent[:volume]
			enqueue(COMMANDS[:mute_on])
			return fail_restore_volume(intent, status, 'volume changed after input restoration')
		end

		if status[:volume] == intent[:volume] &&
			(final_mute.nil? || status[:mute] == final_mute)
			@deferred_final_mute = nil
			# After the saved mute has been verified, decide whether a
			# final power-off is required. Power is ALWAYS restored LAST;
			# we only enter the :final_power phase if the snapshot positively
			# records this session owning an off->on transition
			# (saved_state.power==false AND power_on_completed==true).
			# Otherwise skip directly to finalize.
			if final_power_restore_required?
				@restore_phase = :final_power
				@restore_phase_status_refreshed = false
				@restore_volume_attempts = 0
				# power_off is a status-bearing command; ask for a fresh
				# readback so the next 0x05 reply can confirm power=false.
				enqueue(COMMANDS[:power_off])
				enqueue(COMMANDS[:report_status])
				return intent
			end
			# No final power phase needed. Clean up and settle.
			@restore_phase = nil
			@restoring_session = false
			@restore_error = nil
			@restore_saved_state = nil
			@snapshot_session_powered_on = false
			@snapshot_power_on_completed = false
			delete_session_snapshot
			return {}
		end

		@restore_volume_attempts += 1
		if @restore_volume_attempts <= MAX_VOLUME_RESTORE_CORRECTIONS
			enqueue(COMMANDS[final_mute ? :mute_on : :mute_off]) unless final_mute.nil?
			enqueue_restore_volume_query(:final_mute)
			return intent
		end

		fail_restore_volume(intent, status, 'final volume/mute verification failed')
	end

	# Decide whether the staged restore should enter the :final_power phase.
	# Pre-conditions:
	#   - saved_state.power == false  (snapshot says we should leave it off)
	#   - @snapshot_power_on_completed == true  (we actually powered it on)
	# Without the second condition we may have crashed before our power_on
	# completed, leaving us unable to distinguish our wake-up from external
	# activity (e.g. TV being turned on). In that case we be conservative
	# and skip the power-off: leaving the device in its current state is
	# less disruptive than blindly powering off something the user just
	# turned on.
	private def final_power_restore_required?
		saved = @restore_saved_state
		return false unless saved
		return false unless @snapshot_power_on_completed
		saved[:power] == false
	end

	# Phase :sound.
	#
	# Restore clearvoice, surround, bass_ext, subwoofer. The mute
	# field is NOT touched here (it is forced on in :volume phase and
	# restored to its saved value in :final_mute phase). The volume
	# field was already handled in :volume phase. The :input field
	# is deferred to the :input phase.
	#
	# When all sound-state keys are at target, advance to :input.
	private def enforce_restore_sound_phase(intent, device_state)
		sound_keys = [:clearvoice, :surround, :bass_ext, :subwoofer]
		delta_sound_keys = intent.keys & sound_keys
		# Build the actual delta against device_state
		actual_delta = delta_sound_keys.reject { |k| device_state[k] == intent[k] }

		if actual_delta.empty?
			# All sound state converged. Advance to :input.
			@restore_phase_status_refreshed = false
			@restore_phase = :input
			enqueue(COMMANDS[:report_status])
			return intent.update({enforce_retried: true})
		end

		# Force a fresh status readback on the first pass of this phase.
		if !@restore_phase_status_refreshed
			@restore_phase_status_refreshed = true
			enqueue(COMMANDS[:report_status])
			return intent.update({enforce_retried: true})
		end

		# Emit commands for the actual delta in RESTORE_KEYS order.
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

	# Phase :input.
	#
	# Restore the input. This phase ONLY runs after :volume AND :sound
	# have converged. If the saved input matches the current input,
	# nothing is emitted and we advance to :final_mute.
	private def enforce_restore_input_phase(intent, device_state)
		# First force a fresh readback so we never emit a stale input switch.
		if !@restore_phase_status_refreshed
			@restore_phase_status_refreshed = true
			enqueue(COMMANDS[:report_status])
			return intent.update({enforce_retried: true})
		end

		if device_state[:input] == intent[:input]
			@restore_phase = :post_input_volume
			enqueue_restore_volume_query(:post_input_volume)
			return intent
		end

		# Emit input switch.
		enqueue(COMMANDS[('set_input_' + intent[:input].to_s).to_sym])
		enqueue(COMMANDS[:report_status])
		intent.update({enforce_retried: true})
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
			# Capture the COMPLETE pre-session snapshot BEFORE any session-owned
			# power_on. The saved_state must reflect the device state observed
			# at session acquisition; if the YAS was off when start_session
			# arrives, saved_state.power must remain false even though the
			# wake_yamaha_for_session that follows flips device_state[:power]
			# to true. This ordering is what lets the :final_power phase of
			# the eventual staged restore correctly decide whether to power
			# the device back off at session end.
			if @session.nil?
				@snapshot_session_powered_on = false
				@snapshot_power_on_completed = false
				@session = [name, @device_state.dup]
				persist_session_snapshot(name, @session.last)
			end

			# Session-scoped power ownership: if the user opted into
			# power_on_for_session_starts and the Yamaha is currently off,
			# synchronously wake it (with bounded timeout) BEFORE the music
			# intent is queued. wake_yamaha_for_session updates
			# @snapshot_session_powered_on / @snapshot_power_on_completed
			# but does NOT mutate @session.last, so the pre-wake saved_state
			# is preserved for the eventual :final_power decision.
			if @power_on_for_session_starts && @manage_power == false &&
				@device_state[:power] == false
				wake_yamaha_for_session
			end

			add_intent(parse_intent(intent).update({start_session: name}))
		else
			raise RuntimeError, "device not ready"
		end
	end

	# Synchronously issue power_on and wait for the next 0x05 reply that
	# shows device_state[:power]==true. Raises on timeout.
	#
	# The pre-session snapshot was already captured by start_session before
	# this method was called; @session.last already contains the
	# pre-wake device state. This method only mutates the snapshot's
	# session_powered_on / power_on_completed ownership flags:
	#
	#   session_powered_on=true is set BEFORE issuing power_on, so a crash
	#     before wake completes leaves a recoverable record on disk.
	#   power_on_completed=true is set AFTER observing power=true, so the
	#     :final_power phase of staged restore knows this session owns
	#     the off->on transition and should power the device back off.
	#
	# Importantly this method does NOT mutate @session.last -- the saved
	# pre-wake state must remain so the eventual :final_power decision
	# is correct.
	private def wake_yamaha_for_session
		# Mark this session as one that will own an off->on transition.
		@snapshot_session_powered_on = true
		@snapshot_power_on_completed = false
		persist_session_snapshot(@session ? @session.first : '',
			@session ? @session.last : {})

		@wake_pending = true
		enqueue(COMMANDS[:power_on])
		enqueue(COMMANDS[:report_status])

		# Wait until the device positively reports power=true (verified
		# wake) or the timeout expires. The loop condition checks
		# @device_state[:power] directly so a confirmed wake terminates
		# the wait immediately; the condvar broadcast from handle_received
		# only serves to interrupt the 0.1s poll interval. handle_received
		# assigns @device_state before taking @wake_mutex to broadcast, so
		# this check (performed under the same mutex) cannot miss it.
		deadline = monotonic_now + POWER_ON_TIMEOUT
		@wake_mutex.synchronize do
			while @wake_pending && !@device_state[:power] &&
				monotonic_now < deadline
				@wake_cond.wait(@wake_mutex, 0.1)
			end
		end
		@wake_pending = false

		unless @device_state[:power]
			# Wake-up failed. Tear down state we touched and re-raise so
			# the adapter /start-session returns non-200. Snapshot is
			# removed so a subsequent retry starts clean.
			@snapshot_session_powered_on = false
			@snapshot_power_on_completed = false
			@session = nil
			delete_session_snapshot
			raise RuntimeError,
				"yamaha did not power on within #{POWER_ON_TIMEOUT}s"
		end

		# Wake-up verified. Persist the completion flag so staged restore
		# will know to emit a final power_off at the end of the session.
		@snapshot_power_on_completed = true
		persist_session_snapshot(@session ? @session.first : '',
			@session ? @session.last : {})
	end

	# Post-init / SPP-reconnect idle input sanitization.
	#
	# An SPP/RFCOMM reconnect can wake the YAS-207, and the device may come
	# up with input=:bluetooth. Bluetooth AUDIO is not used in this
	# deployment -- SPP/RFCOMM is control-only -- so :bluetooth must never
	# be left as the idle input merely as a side effect of establishing the
	# control connection.
	#
	# Guarded narrowly: a correction is applied ONLY when
	#   - a policy input is configured (controller.idle_input_policy; the
	#     default nil disables this feature entirely),
	#   - the device is positively powered on,
	#   - no session is active (this also covers session start-up, since
	#     start_session pre-creates @session before any wake-up),
	#   - no staged restore is in progress,
	#   - no intent is pending (initial / manual / session commands),
	#   - the observed input is exactly :bluetooth.
	# The correction enqueues the set_input command plus a status report
	# and verifies via the next device status reply; it never powers the
	# device on or off and never mutates session or restore state. The
	# reconnect itself -- and any wake it caused -- is a separate
	# lifecycle observation, already visible in the DS lines; this method
	# only corrects the input.
	private def sanitize_idle_input
		return if @idle_input_policy.nil?
		return unless @state == :synced

		unless @session.nil? && !@restoring_session && @intent.empty?
			# A lifecycle transition (session start, restore, or a pending
			# command) interrupts any in-flight correction.
			@idle_input_correction_pending = false
			return
		end
		return unless @device_state[:power] == true

		if @idle_input_correction_pending
			# A correction is in flight; each subsequent status report is
			# the verification point.
			if @device_state[:input] == @idle_input_policy
				@idle_input_correction_pending = false
				puts "+ Idle input: policy input=#{@idle_input_policy} verified"
			elsif monotonic_now - @idle_input_correction_at >
					IDLE_INPUT_CORRECTION_TIMEOUT
				@idle_input_correction_pending = false
				STDERR.puts "! Idle input: correction to #{@idle_input_policy} " +
					"not verified within #{IDLE_INPUT_CORRECTION_TIMEOUT}s " +
					"(input still #{@device_state[:input].inspect})"
			end
			return
		end
		return unless @device_state[:input] == :bluetooth

		@idle_input_correction_pending = true
		@idle_input_correction_at = monotonic_now
		puts "+ Idle input: observed input=bluetooth while idle " +
			"(powered on, no session, no restore, no pending intent); " +
			"applying policy input=#{@idle_input_policy}"
		enqueue(COMMANDS[:"set_input_#{@idle_input_policy}"])
		enqueue(COMMANDS[:report_status])
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

	private def ensure_not_restoring!
		if @restore_requested || @restoring_session
			raise RuntimeError, "session restore in progress"
		end
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
		persist_session_snapshot_ext(name, saved,
			session_powered_on: @snapshot_session_powered_on,
			power_on_completed: @snapshot_power_on_completed)
	end

	private def persist_session_snapshot_ext(name, saved,
			session_powered_on: @snapshot_session_powered_on,
			power_on_completed: @snapshot_power_on_completed)
		File.write(@snapshot_path, JSON.pretty_generate({
			'name' => name,
			'saved_state' => saved,
			'captured_at' => Time.now.utc.iso8601,
			'session_powered_on' => session_powered_on ? true : false,
			'power_on_completed' => power_on_completed ? true : false,
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
		# session_powered_on / power_on_completed default to false on old
		# snapshots (backward-compatible: an old snapshot without these
		# fields will never trigger a final power-off at restore time).
		@snapshot_session_powered_on =
			data.key?('session_powered_on') ? !!data['session_powered_on'] : false
		@snapshot_power_on_completed =
			data.key?('power_on_completed') ? !!data['power_on_completed'] : false
		@session = [name, saved_sym]
		puts "! Recovered session from snapshot: name=#{name}, saved=#{saved_sym.inspect}, session_powered_on=#{@snapshot_session_powered_on}, power_on_completed=#{@snapshot_power_on_completed}"
	rescue => e
		STDERR.puts "! Failed to recover session snapshot: #{e}"
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
		# session model (name, active, restoring, restore_phase/error,
		# power-ownership flags). Used by adapters to positively confirm
		# session-restore completion.
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
					'powered_on_by_session' => ysr.instance_variable_get(:@snapshot_power_on_completed),
				},
				'protocol' => {
					'status_generation' => ysr.status_generation,
					'volume_status_generation' => ysr.volume_status_generation,
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
