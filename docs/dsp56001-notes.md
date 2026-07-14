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

Frequently accessed scalar state now occupies internal `X:$0000-$0041`.
Short-address loads and stores remove an extension word and avoid external RAM;
this reduced the initialized loader payload from 8,100 to 7,113 bytes before
adding the FIFO and audio transport. The current protocol-v10 image, including
interrupt-fed double buffering and PCM/FM mixing, is 8,082 bytes; the build
checks it against the 8 KiB TOS limit.

## Falcon SSI interrupt-buffered mixed path

The audio path configures SSI control A as `$4100`: 16-bit words and two words
per synchronous network frame. Control B is `$5a00`: synchronous network mode,
transmit enabled, and transmit interrupts enabled, while serial clock and
transmit frame sync remain crossbar inputs. SSI priority is level 2 through IPR
`$3000`. Each signed 16-bit YM sample is shifted into the upper 16 bits of the
DSP's 24-bit transmit register.

The normal SSI transmit vector at `P:$0010` is a two-instruction fast interrupt:
it moves `X:(r6)+` to TX and returns through the implicit fast-interrupt path.
The dedicated `r6/m6` pair is not used by synthesis, so refills can be
interrupted without saving ALU state or disturbing a hardware `DO` loop. The
transmit-exception vector at `P:$0012` is a long interrupt that reads SSISR and
then writes TX, the required sequence for clearing TUE. It is a recovery path,
not part of normal block playback.

The Falcon DAC rate selected by the host is 25.175 MHz divided by 4 and 128,
or 49,169.921875 Hz. Relative to the native 62,500 Hz OPM rate this is exactly
`1280/1007`, so the staging renderer advances one or two native samples per
codec frame and stores the latest result. Each 1007-frame block uses 2014
interleaved stereo words. Buffer A starts at external `X:$1000`, buffer B at
`X:$1800`; both are 2048-word aligned so `m6=2013` wraps each non-power-of-two
block correctly. They are uninitialized storage, add no `.LOD` records, and
both fit below the 8192-word external-X reservation.

Protocol command `$11` receives 1007 interleaved signed stereo frames rendered
by the 68030 PDX mixer. The DSP renders the matching FM period, adds and clamps
each channel to signed 16-bit, then starts interrupt-fed playback from buffer A.
Command `$13` selects the inactive buffer with `r7`, receives and mixes the next
period there while `r6` keeps the active block repeating, then switches only
after a complete stereo pair. The switch clears TIE while retaining transmit,
waits for TDE, supplies a matching right word if the active pointer is between
channels, preloads the new block's first left word, and restores `$5a00`.
Buffer pointers use `r6/r7`; the phase-cache loop owns `r4`, so sharing that
register would displace the refill position during every YM sample.

Protocol v10 implements the event shape with a rolling clock. A refillable
32-entry ring FIFO stores an absolute 16-bit native-sample time beside each
packed register write. Entries must be in nondecreasing modular order and
within the 32,767-sample future horizon; all writes due at a boundary are
applied before clocking that YM sample. FIFO and clock-query transactions are
serviced while SSI is active, and the clock continues across refills instead of
restarting at zero.

The previous direct-mode throughput instrument generated 5,679 fresh codec
frames and advanced 7,217 native samples during a nominal 50-VBL interval.
That is about 11.5% of the required 49,169.921875 frames per second. Direct mode
was removed to recover loader space; the double buffer now keeps transport
alive by repeating the last complete block, while the same result remains the
concrete optimization target for real-time fresh synthesis.
