# MDX execution ground truth

The host executor is cross-checked against the vendored MXDRV 2.06+17 source
at `third_party/x68kd11s/sound/mxdrv/2.06+17_Rel.X5-S/mxdrv17.s` and the raw
file layout documented by mdxtools. The relevant MXDRV routines are
`StartPlay`, `InitChannel`, `CommandFuncs`, `SetPCMVolume`, and `LoadVoice`.

## Sequence and track layout

The raw file begins with a Shift-JIS title terminated by `0d 0a 1a`, followed
by a zero-terminated PDX filename. The next byte is the sequence base. It holds
one unsigned relative word for the FM voice table followed by either 9 or 16
unsigned relative track words. All offsets are relative to the sequence base.
The first track offset encodes the table width: `(offset - 2) / 2` is 9 or 16.
Channels 0-7 are YM2151 FM tracks; channel 8 is the legacy PDX track, and
channels 8-15 map to eight PDX/PCM voices in a 16-track file.
The `$e8` command is the runtime backend switch: before it executes, track 8
uses the original single IOCS ADPCM-channel semantics; afterward the PCM8
volume and multi-voice semantics apply.

The port scans the variable header and resolves the voice and active track
offsets against the owned MDX copy before playback. A track fetch or operand
fetch at/past the copied end retires that track with `mxdrv_mdx_error` set. At
most 64 consecutive commands may execute before a duration-producing byte;
this bounds corrupt command-only streams.

## TTP file resolution

The TTP accepts an MDX filename followed by an optional PDX override. When the
override is omitted, the player uses the NUL-terminated PDX name from this
header, appends `.PDX` when the header omits an extension, and resolves a
basename beside the supplied MDX path. An empty embedded name means that no PDX
file is loaded. This lookup is a player convenience; it does not change the
raw MDX layout or the driver's PDX table semantics.

## Durations and notes

- `00`-`7f` is a rest of encoded value plus one timer ticks.
- `80`-`df` is a note, followed by an encoded duration byte. The total duration
  is again that byte plus one.
- FM note `n` uses MXDRV's pitch `(n << 6) + 5`, producing fractional register
  value `$14` and a KC byte from the original 96-byte `OPMNoteTable`.
- PCM note `n` selects PDX entry `bank * 96 + n`; track 8 maps to PCM voice 0,
  through track 15/voice 7. The currently supported raw PDX bank contains the
  standard 96 entries, so a nonzero bank is consumed faithfully but resolves
  as a silent missing entry.
- The default note-length value is 8. For nonnegative values, MXDRV computes
  the key gate as `(encoded_duration * note_length >> 3) + 1`.

The PCM defaults recovered from channel initialization are rate code 4
(15.625 kHz), volume 8 (unity in the PCM8 gain table), and center/both output.

## Implemented commands

| Byte | Reference command | Current behavior |
| --- | --- | --- |
| `ff dd` | tempo | mirrors tempo and writes YM register `$12` |
| `fe rr dd` | raw OPM write | sends the exact register/data pair to the DSP |
| `fd vv` | voice | finds and loads a 26-byte FM voice body, or selects a PCM bank |
| `fc pp` | pan | updates FM register `$20+channel`, or the PCM start parameters |
| `fb vv` | volume | sets indexed FM/PCM volume; legacy ADPCM caches but does not apply it, and FM also accepts raw `$80`-`$ff` attenuation |
| `fa` / `f9` | volume down/up | steps indexed or raw volume with the original endpoint clamps |
| `f8 ll` | note length | updates the key-gate scale |
| `f7` | legato | suppresses the current gate key-off so the following note slurs without retriggering held slots |
| `f6 cc ww` | repeat start | copies count `cc` into mutable work byte `ww` |
| `f5 oo oo` | repeat end | decrements target-minus-one and takes the signed branch while nonzero |
| `f4 oo oo` | repeat escape | follows a future F5 displacement and skips it when the counter is one |
| `f3 dd dd` | detune | stores a signed 1/64-semitone offset for following notes |
| `f2 pp pp` | portamento | applies the signed per-tick pitch delta to the next note |
| `f1 00` / `f1 oo oo` | performance end | retires the standalone track or jumps to the bounded loop target and increments the loop count |
| `f0 dd` | key-on delay | delays the next note's key edge by `dd` ticks |
| `ef cc` / `ee` | sync send/wait | raises a bounded channel flag or parks until that track's flag is raised |
| `ed dd` | noise / PCM frequency | writes YM noise control on FM tracks or selects the PCM rate on PCM tracks |
| `ec ...` | software pitch LFO | programs saw/square/triangle/random period and depth; `$80`/`$81` disable/re-enable |
| `eb ...` | software volume LFO | programs carrier-TL modulation; `$80`/`$81` disable/re-enable |
| `ea ...` | OPM LFO | programs waveform, rate, PMD, AMD, PMS/AMS, and optional key-on phase reset; `$80`/`$81` disable/re-enable sensitivity |
| `e9 dd` | LFO delay | holds and restarts the software LFOs after key-on |
| `e8` | enable PCM8 | switches subsequent PDX playback from fixed-gain legacy ADPCM to PCM8 gain/multi-voice semantics |
| `e7 00` | extension end | retires the track |
| `e7 01 ww` | extension fade | starts fadeout with wait reload `ww` |
| `e7 03 dd` | extension damp | enables/disables forced key-off before every key-on |
| `e0`–`e6` | performance end | retires the track |

An FM FD record is one ID byte followed by algorithm/feedback, PMS/AMS, four
DT1/MUL bytes, four TL bytes, and sixteen envelope/DT2 bytes. `LoadVoice` maps
those bytes to registers `$20`, `$38`, `$40`-`$58`, `$60`-`$78`, and
`$80`-`$f8` for the selected channel. This port preserves that mapping. Its
carrier mask is the original `$08,$08,$08,$08,$0c,$0e,$0e,$0f` table for
algorithms 0-7. Voice loading initially silences only carriers, retains each
modulator's base TL, then rewrites carrier TL as base plus MXDRV's indexed
attenuation table. FM volume bytes `$80`-`$ff` instead encode attenuation
0-127 directly. Both forms saturate at YM TL `$7f`; FA/F9 preserve the
different byte directions and endpoint behavior of indexed versus raw volume.
After E8, PCM FB/FA/F9 changes update an already-running decoder voice without
resetting its ADPCM or rate-conversion state. Before E8, MXDRV routes track 8
through IOCS ADPCM output, whose call has no volume operand. The port therefore
keeps the parsed volume byte but renders that legacy path at PCM8 code 8
(unity), including during fades; the fade's terminal stop still silences it.

F6-F5-F4 control flow preserves MXDRV's unusual in-stream mutable counter. F5
uses a signed displacement relative to the byte after its operands; the work
byte is immediately before that target. F4 uses an unsigned forward
displacement to the future F5 operands, then follows F5's signed displacement
to inspect the same counter. Both the counter and every control target are
checked against the owned MDX copy before use.

Other E7 host-extension forms retire only the affected track and set the
parser error byte. The same bounded failure applies to a truncated operand,
invalid repeat target, missing FM voice, or failed DSP write; other tracks may
continue.

## Timer service seam

`mxdrv_mdx_timer_service` is the re-entry-guarded scheduler entry point. Each
accepted call advances exactly one sequencer tick and increments a diagnostic
counter. Stopped, paused, or nested calls do not advance it.

`mxdrv_mdx_timer_period` returns `(256 - tempo) * 16` native 62.5 kHz samples.
YM2151 Timer B advances every 1024 input clocks, which is 16 samples at the
emulated chip's 4 MHz / 64 sample cadence. Thus the initial `$c8` tempo is 896
samples per tick and the integration fixture's `$a4` is 1472. Public play now
claims MFP Timer A only when its control, interrupt-enable, and
interrupt-mask state all show that it is unused. Timer A runs at 1024 Hz using
the 2.4576 MHz MFP clock, divisor 200, and data value 12. Its level-6 handler
adds exactly 4,000,000 units to a 16.16 native-sample phase accumulator per
interrupt and increments a saturating pending-tick count at every current
Timer-B boundary. Timer A is also the Falcon DMA-sound timer, so an existing
user causes play to fail instead of being displaced. Stop restores the saved
vector and idle register state.

The interrupt does not call XBIOS and does not communicate with the DSP.
`mxdrv_mdx_clock_pump` drains pending ticks in foreground context, where the
sequencer's synchronous DSP transfers are legal. Applications must therefore
pump regularly; timing accumulation is automatic, while DSP command execution
is deliberately deferred out of interrupt context.

## Integration fixture

The Hatari harness first copies a nine-track legacy MDX whose PCM track issues
`fb $0f` without E8 and proves that voice 0 starts at fixed unity gain. It then
copies a standard raw 16-track MDX through call `$02`
and starts it through call `$04`. Its FM track selects a standard voice,
executes FE/FF/E8, starts note 0, and keys it off one tick later. PCM track 8
starts PDX entry 0 for two ticks at volume 15, proving that E8 enables the
PCM8 gain table. The test checks the OPM mirror, MDX active
mask, PDX active mask, stopped playback flags, and exact Timer-B periods. A
carrier-volume fixture checks algorithm-0 modulator TL preservation, normal
indexed attenuation, raw `$80` stepping through FA/F9, and `$ff` saturation.
The PDX gate also changes and queries an active voice's volume without
restarting it. A second FM track takes a two-pass F6/F5 loop, executes F4 escape
on its final
pass, and proves the mutable work byte transitions from 2 to 1. A malformed F5
fixture verifies that an out-of-buffer target is rejected before memory is
touched. A long-rest fixture then waits three VBLs, observes automatically
accumulated Timer-A ticks, drains them in foreground, and verifies that stop
releases the timer. The clock gate emits `$01d10c`; the completed MDX gate emits
`$01d009`.
