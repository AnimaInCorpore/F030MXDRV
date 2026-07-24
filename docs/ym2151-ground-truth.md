# YM2151 ground truth from the vendored MAME tree

The DSP port should treat MAME's BSD-licensed ymfm core as the behavioral
reference, not infer chip behavior from the disassembled driver. The relevant
sources are:

- `third_party/mame/3rdparty/ymfm/src/ymfm_opm.h` and `ymfm_opm.cpp`;
- `third_party/mame/3rdparty/ymfm/src/ymfm_fm.h` and `ymfm_fm.ipp`;
- `third_party/mame/src/mame/sharp/x68k.cpp` for the X68000 clock;
- `third_party/mame/src/devices/sound/ymopm.cpp` for the MAME device wrapper.

## Clock and output contract

The X68000 config clocks the YM2151 from `16 MHz / 4`, or 4 MHz. ymfm defines
32 operators and a default prescale of 2, and computes the sample rate as
`clock / (prescale * operators)`. The native OPM output rate is therefore
62,500 Hz. Each output step clocks all channels once, mixes a full 14-bit FM
result without intermediate clipping, then performs a YM3012 external-DAC
10.3-float round trip.

The Falcon cannot silently substitute its codec rate. Its audio stage must
either resample 62.5 kHz explicitly or prove an equivalent phase/time mapping.
The current production kernel uses a drift-free 2560:1007 DDA to map this
native clock onto 24,584.9609375 Hz codec frames; the conformance kernel keeps
the native rate.

After a data-port write ymfm marks the chip busy for
`32 * clock_prescale = 64` input clocks. Busy is bit 7 of status. Timer A and B
status are bits 0 and 1.

Timer A's native-sample period is `1024 - value`; Timer B's is
`16 * (256 - value)`. Timer B's divide-by-16 source is free-running, so its
first period subtracts the current sample-clock phase modulo 16. A load bit
starts only a stopped timer, an expiration reloads it, clearing load cancels
it, and the separate enable bits gate status without stopping the counters.
Mode bits 4 and 5 clear Timer A and B status respectively. Timer A expiration
in CSM mode raises the CSM key source for every operator.

## Register map

| Address | Meaning |
| --- | --- |
| `01` | test; bit 1 holds LFO reset |
| `08` | operator key-on mask in bits 3-6, channel in bits 0-2 |
| `0f` | noise enable/frequency |
| `10`, `11` | 10-bit Timer A value |
| `12` | Timer B value |
| `14` | CSM, timer reset/enable/load control |
| `18` | LFO frequency |
| `19` | AM depth with bit 7 clear; PM depth with bit 7 set |
| `1b` | CT outputs in bits 6-7; LFO waveform in bits 0-1 |
| `20-27` | right/left pan, feedback, algorithm per channel |
| `28-2f` | 7-bit key code per channel |
| `30-37` | 6-bit key fraction in bits 2-7 |
| `38-3f` | PM and AM sensitivity per channel |
| `40-5f` | DT1 and multiplier per operator |
| `60-7f` | total level per operator |
| `80-9f` | key-scale rate and attack rate |
| `a0-bf` | AM enable and decay rate |
| `c0-df` | DT2 and sustain rate |
| `e0-ff` | sustain level and release rate |

ymfm keeps PM depth in an internal shadow at `1a`; direct writes to `1a` are
ignored. The DSP core implements this detail in its register image.
Reset clears all 256 registers, then sets `20-27` to `c0` so both outputs are
enabled by default.

## Operator and synthesis semantics

There are eight channels with four operators each. Raw register operator order
does not match algorithm order. For channel `n`, ymfm maps algorithm operators
to raw operator indices `[n, n+16, n+8, n+24]`, corresponding to
`[operator 1, operator 2, operator 3, operator 4]` in algorithm evaluation.

The eight algorithms and operator-1 feedback must follow the table in
`fm_channel::output_4op` in `ymfm_fm.ipp`. Channel 7 operator 4 is replaced by
the noise output when noise is enabled. Pan bits gate the already-mixed channel
into the two outputs.

OPM frequency is musical rather than an OPN-style F-number: three block bits,
four key-code bits, and six key-fraction bits form a 13-bit value. DT1, DT2,
multiplier, LFO PM, key scaling, and envelope rates must remain in the same
integer domains as ymfm until the final DSP fixed-point conversion is defined.

The build mechanically imports ymfm's phase-step, DT1, log-sine, power, and
envelope-increment tables. Fixed-width and delta packing reduce host-transfer
and DSP-memory cost. The packed source tables live in the 68030 executable;
command `$0a` uploads the complete 329-word block, which is expanded exactly
on the DSP before conformance or audio work begins. Codec-rate kernels use the
DSP56001's factory 256-step sine ROM instead of uploading a second waveform.
DT1 continues to be read from its packed table. Program code is installed by
the embedded second-stage loader, so TOS's former converted-LOD size ceiling
no longer constrains specialization.
The frequency path removes
the gaps from OPM key codes, applies the DT2 deltas `[0, 384, 500, 608]`, handles
octave overflow/clamping, adds signed DT1, and applies the x.1 multiplier
(`MUL=0` means 0.5). Protocol commands `05 cc oo` and `07 00 ii` expose phase
and envelope intermediates for exact conformance tests.

The implemented LFO uses 256-entry saw, square, triangle, or noise waveforms, a
4.4-style rate, separate 7-bit AM/PM depth, channel sensitivities, and
per-operator AM enable. The same global clock advances the 25-bit noise LFSR
twice per native sample and substitutes its latched sign for channel 7 operator
4 when enabled.

## Executable oracle

`tools/ym2151_oracle.cpp` subclasses the vendored `ymfm::ym2151` only to expose
its existing debug operator state. It is linked directly with `ymfm_opm.cpp`;
there is no independent host reimplementation of the chip math. The build uses
it in four ways:

- `--emit-m68k ATTACK_TRACE NOISE_TRACE CSM_TRACE VIBRATO_TRACE` produces the
  expected phase-step and stereo tone/noise/CSM/vibrato checkpoint constants
  included by the TOS smoke program;
- `--vectors TRACE SAMPLES` produces stereo output plus phase, phase step,
  envelope attenuation, and envelope state for all four channel operators;
- `--codec-vectors TRACE FRAMES [--algorithm N] [--feedback N]` emits exact
  output and operator/control state at the Falcon codec cadence, including the
  native-sample and ordered-write marker consumed by every frame; and
- `--perceptual-vectors TRACE FRAMES [--algorithm N] [--feedback N]` retains
  that exact boundary state but independently renders 256-step sine lookup,
  codec-rate feedback/topology, panning, noise, and YM3012 output.

`tools/compare_ym2151_realtime.py` validates the resulting perceptual corpus
and compares future DSP captures on state/rate and spectral boundaries. This
makes the MAME source both the documented and executable ground truth.
