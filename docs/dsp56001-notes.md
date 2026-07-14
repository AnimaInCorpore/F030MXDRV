# DSP56001 implementation notes

The local `docs/DSP56001_um.pdf` is the architectural reference for the DSP
side. The current DSP core relies on these specific rules from the Motorola
DSP56000/DSP56001 User's Manual.

## Numeric representation

Section 4.2, “Data Representation and Rounding” (manual pages 4-9 onward),
defines data-ALU words as signed 24-bit fractional values with the binary point
left justified. The same bit patterns can be manipulated as small integers with
logical shifts and adds, as the current synthesis kernel does, but future use of
`MPY`/`MAC`, scaling mode, rounding, or accumulator limiting must account for
the fractional alignment explicitly. Generated ymfm lookup values are emitted
as raw 24-bit words rather than silently rescaled constants.

## Address-generation pipeline

Section 8.1, pipeline Case 2 (manual page 8-2), states that an indirect address
is formed before the preceding `MOVE` has finished writing its `Rn` register.
One independent instruction cycle is required between writing `Rn` and using
it for an indirect memory access. The same scheduling discipline is used for
the `Nn` offsets in `src/dsp/ym2151.asm`. Where there is no useful independent
instruction, the core inserts a `NOP` before `x:(Rn+Nn)` or `y:(Rn+Nn)`.

## Hardware loops

The `DO` instruction description (manual pages A-63 through A-65) confirms that
the loop has no per-iteration overhead, but a count of zero means 65,536
iterations rather than zero. Variable-count loops in the synthesis kernel
therefore branch around `DO` when the count can be zero. Section 8.1.2 (manual pages 8-6
onward) also lists instructions forbidden near a loop end; loop bodies here are
kept to simple ALU or memory moves and are checked by Motorola ASM56000.

These constraints are part of correctness, not just optimization: violating
either the address delay or zero-count behavior produces valid assembly with
incorrect chip state at runtime.

## First synthesis hot-path pass

Deriving one OPM phase increment includes key-code gap removal, DT1/DT2 table
access, octave shifting, multiplier handling, and PM sensitivity. Repeating
that static work for all 32 operators on every sample dominated the initial
correctness-oriented kernel. The DSP now caches the no-PM increments and
rebuilds them after writes to the register groups that can contain KC/KF,
DT1/MUL, or DT2. A non-zero per-sample LFO PM value still selects the original
complete calculation, so the optimization does not approximate modulation.

The 32-word cache starts at internal `Y:$0100`. This keeps phase in X and its
increment in Y, allowing one parallel fetch followed by add/store: three
instructions per operator in the common no-PM path. It also avoids external
`Y:$0200`, which overlaps the external program address range under the Falcon
memory reservation used by this executable. The output path separately skips
four-operator evaluation when all four envelopes are `$3ff`, while explicitly
clocking that channel's next feedback input to zero. Released envelopes already
at `$3ff` bypass rate derivation until a later key-on makes them active again.
Phase, key edges, feedback history, LFO/noise, and timers continue to clock.

## Falcon SSI staging path

The bounded audio probe configures SSI control A as `$4100`: 16-bit words and
two words per synchronous network frame. Control B is `$1a00`: synchronous
network mode with transmit enabled, while serial clock and transmit frame sync
remain crossbar inputs. Each signed 16-bit YM sample is therefore shifted into
the upper 16 bits of the DSP's 24-bit transmit register.

The Falcon DAC rate selected by the host is 25.175 MHz divided by 4 and 128,
or 49,169.921875 Hz. Relative to the native 62,500 Hz OPM rate this is exactly
`1280/1007`, so the staging renderer advances one or two native samples per
codec frame and stores the latest result. A 1007-frame stereo block occupies
uninitialized external X RAM at `$0c00`; it adds no initialized `.LOD` records
and ends below the reserved X-memory boundary.
