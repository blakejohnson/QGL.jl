# translator for the APS2
module APS2

using HDF5

import QGL

const DAC_CLOCK = 1.2e9
const FPGA_CLOCK = 300e6
const ADDRESS_UNIT = 4  #everything is done in units of 4 timesteps
const MIN_ENTRY_LENGTH = 8
const MAX_WAVEFORM_PTS = 2^28  #maximum size of waveform memory
const WAVEFORM_CACHE_SIZE = 2^17
const MAX_WAVEFORM_VALUE = 2^13 - 1  #maximum waveform value i.e. 14bit DAC
const MAX_NUM_INSTRUCTIONS = 2^26
const MAX_REPEAT_COUNT = 2^16 - 1
const MAX_MARKER_COUNT = 2^32 - 1

# instruction encodings
const WFM = 0x00
const MARKER = 0x01
const WAIT = 0x02
const LOAD_REPEAT = 0x03
const DEC_REPEAT = 0x04
const CMP = 0x05
const GOTO = 0x06
const CALL = 0x07
const RETURN = 0x08
const SYNC = 0x09
const MODULATOR = 0x0a
const LOAD_CMP = 0x0b
const PREFETCH = 0x0c

typealias APS2Instruction UInt64

immutable Waveform
	address::UInt32
	count::UInt32
	isTA::Bool
	write_flag::Bool
	instruction::UInt64
end

# WFM/MARKER op codes
const PLAY_WFM = 0x0
const WAIT_TRIG = 0x1
const WAIT_SYNC = 0x2
const WFM_PREFETCH = 0x3
const WFM_OP_OFFSET = 46
const TA_PAIR_BIT = 45
const WFM_CT_OFFSET = 24

function Waveform(address, count, isTA, write_flag)
	ct = UInt64(count ÷ ADDRESS_UNIT - 1) & 0x000f_ffff # 20 bit count
	addr = UInt64(address ÷ ADDRESS_UNIT) & 0x00ff_ffff # 24 bit address
	header = UInt64( (WFM << 4) | (0x3 << 2) | (write_flag & 0x1) )
	payload = (UInt64(PLAY_WFM) << WFM_OP_OFFSET) | (UInt64(isTA) << TA_PAIR_BIT) | (ct << WFM_CT_OFFSET) | addr
	instr = (header << 56) | payload
	Waveform(addr, ct, isTA, write_flag, instr)
end

immutable Marker
	engine_select::UInt8
	state::Bool
	count::UInt32
	transition_word::UInt8
	write_flag::Bool
	instruction::UInt64
end

function Marker(marker_select, count, state, write_flag)
	count = UInt64(count)
	quad_count =  UInt64(count) ÷ ADDRESS_UNIT & UInt64(0x0fff_ffff) # 28 bit count
	count_rem = count % ADDRESS_UNIT
	if state
		transition_words = [0b1111; 0b0111; 0b0011; 0b0001]
		transition_word = transition_words[count_rem+1]
	else
		transition_words = [0b0000; 0b1000; 0b1100; 0b1110]
		transition_word = transition_words[count_rem+1]
	end
	header = (MARKER << 4) | ((marker_select & 0x3) << 2) | (write_flag & 0x1)
	payload = (UInt64(PLAY_WFM) << WFM_OP_OFFSET) | (UInt64(transition_word) << 33) | (UInt64(state) << 32) | quad_count
	instr = (UInt64(header) << 56) | payload
	Marker(UInt8(marker_select), state, quad_count, transition_word, write_flag, instr)
end

immutable ControlFlow
	instruction::UInt64
end

function write_sequence_file(filename, seqs, pulses)

	# TODO: inject modulation commands
	# inject_modulation_commands

	# translate pulses to waveforms
	wf_lib, wfs = create_wfs(pulses)

	# create instructions and waveforms
	instrs = create_instrs(seqs, wf_lib)

	write_to_file(filename, instrs, wfs)
end

const USE_PHASE_OFFSET_INSTRUCTION = false

function create_wfs(pulses)
	# TODO: better handle Id so we don't generate useless long wfs and have repeated 0 offsets
	instr_lib = Dict{QGL.Pulse, Union{Waveform,Marker}}()
	wfs = Vector{Vector{Int16}}()
	idx = 0
	for p in pulses
		if typeof(p.channel) == QGL.Qubit
			wf = p.amp * QGL.waveform(p, DAC_CLOCK)
			if !USE_PHASE_OFFSET_INSTRUCTION
				wf *= exp(1im * p.phase)
			end
			# reduce to Int16 with maximum for 14 bit DAC
			wf = round(Int16, MAX_WAVEFORM_VALUE*real(wf)) + 1im*round(Int16, MAX_WAVEFORM_VALUE*imag(wf))

			isTA = all(wf .== wf[1])
			instr_lib[p] = Waveform(idx, length(wf), isTA, true)
			if isTA
				idx += ADDRESS_UNIT
				push!(wfs, wf[1:ADDRESS_UNIT])
			else
				idx += length(wf)
				push!(wfs, wf)
			end
		elseif typeof(p.channel) == QGL.Marker
			num_points = round(UInt64, length(p) * DAC_CLOCK)
			instr_lib[p] = Marker(1, num_points, p.amp > 0.5, true)
		end

	end

	return instr_lib, wfs
end

function create_instrs(seqs, wf_lib)
	instrs = APS2Instruction[]

	for entry in seqs
		# play out pulses
		if typeof(entry) == QGL.PulseBlock
			time_stamps = Dict(chan => 0.0 for chan in QGL.channels(entry))
			all_done = Dict(chan => false for chan in QGL.channels(entry))
			idx = Dict(chan => 1 for chan in QGL.channels(entry))
			while !all(values(all_done))
				next_time = 0
				for chan in QGL.channels(entry)
					while !all_done[chan] && (time_stamps[chan] <= next_time)
						wf = wf_lib[entry.pulses[chan][idx[chan]]]
						push!(instrs, wf.instruction)
						time_stamps[chan] += wf.count+1
						next_time += wf.count+1
						idx[chan] += 1
						if idx[chan] > length(entry.pulses[chan])
							all_done[chan] = true
						end
					end

				end
			end

		else
			# convert control flow to APS2Instruction
			push!(instrs, convert(APS2Instruction, entry))
		end

	end

	return instrs

end

function convert(::Type{APS2Instruction}, cf::QGL.ControlFlow)
	if cf.op == QGL.WAIT
		return APS2Instruction(WAIT << 4 | 0x1) << 56
	elseif cf.op == QGL.GOTO
		return APS2Instruction(GOTO << 4 | 0x1) << 56 | UInt64(cf.target)
	else
		error("Untranslated control flow instruction")
	end
end

function write_to_file(filename, instrs, wfs)
	#flatten waveforms to vector
	wf_vec = Vector{Complex{Int16}}(sum(length(wf) for wf in wfs))
	idx = 1
	for wf in wfs
		wf_vec[idx:idx+length(wf)-1] = wf
		idx += length(wf)
	end

	h5open(filename, "w") do f
		attrs(f)["Version"] = 4.0
		attrs(f)["target hardware"] = "APS2"
		attrs(f)["minimum firmware version"] = 4.0
		attrs(f)["channelDataFor"] = UInt16[1; 2]
		chan_1 = g_create(f, "chan_1")
		write(chan_1, "waveforms", real(wf_vec))
		write(chan_1, "instructions", instrs)
		chan_2 = g_create(f, "chan_2")
		write(chan_2, "waveforms", imag(wf_vec))
	end
end

end
