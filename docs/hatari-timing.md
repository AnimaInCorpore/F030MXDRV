# Which Hatari the gates run, and what changed when it changed

Every emulator gate in this repository now runs the DSP-calibrated Hatari built
in the F030Arcade tree, not the Homebrew release. The two builds agree
instruction for instruction; they disagree about how much time the Falcon's
DSP56001 has. That disagreement originally hid 351 late periods, then three
host-pipeline misses; the producer/consumer pipeline recorded below cleared
the last of them, and the calibrated emulator remains the only build whose
pass actually describes the Falcon's clock.

## Selecting the binary

`HATARI` resolves, in order, to an explicit override, the calibrated build
under `F030ARCADE`, and finally `hatari` on `PATH`:

```sh
make smoke                                    # calibrated build if present
make smoke HATARI=/opt/homebrew/bin/hatari    # explicit override
make smoke F030ARCADE=/path/to/F030Arcade     # relocated tree
```

`tools/hatari_binary.py` applies the same order to the Python gates, which also
accept `--hatari` and honour the `HATARI` environment variable. Every
target that launches an emulator — `smoke`, `capture-realtime`, `stock-audio`,
`endurance`, `endurance-batch`, `run`, and all `profile-dsp*` targets — goes
through it.

Running on any other binary is allowed and prints a warning, because a stock
build reports the same cycle profiles and the same passes while measuring a
machine with twice the Falcon's DSP throughput. A silent fallback is exactly
how the result in the rest of this document went unnoticed.

## What the calibrated build fixes

Two independent errors, both documented in `F030Arcade/hatari.md`, both
verified there against DSPBench v3.0b:

- **DSP clock.** Every caller already scaled CPU cycles by
  `DSP_CPU_FREQ_RATIO` before calling `DSP_Run()`, and `DSP_Run()` applied the
  ratio a second time. Stock Hatari therefore runs the DSP at 32 MIPS instead
  of the Falcon's 16. The per-instruction cycle model was already exact,
  external-memory penalty included; only the rate at which cycles were handed
  out was wrong.
- **Host port.** Upstream charges zero wait states for the first byte of a
  CPU-side host-port access and four for each later byte, which DSPBench
  measures at 72–174 % of hardware. The calibrated build replaces that with a
  per-direction, per-size table charged once per access (read 3/7/10, write
  4/3/7 for byte/word/long), which brings the eleven host tests from 28.3 pp
  RMS error to 10.4 pp.

## What did not change: the cycle profiles

All eleven bracketed profile reports are byte-identical between the two builds:

| target | measured | budget | required speedup |
| --- | --- | --- | --- |
| `profile-dsp` | 12,271.21 per native 62.5 kHz sample | 256.68 | 47.81x |
| `profile-dsp-rt` | 39.16 per codec frame (313.31 projected) | 326.27 | 0.96x |
| `profile-dsp-rt2` | 37.75 per codec frame (301.98 projected) | 326.27 | 0.93x |
| `profile-dsp-rt3` | 37.70 per codec frame (301.61 projected) | 326.27 | 0.92x |
| `profile-dsp-rt4-alg1..6` | 35.98-39.05 per codec frame (287.86-312.37 projected) | 326.27 | 0.88-0.96x |
| `profile-dsp-rt5` | 336.60 per codec frame | 489.40 | 0.69x |

This is the expected result and it is worth stating plainly: the static budget
analysis in [`dsp56001-notes.md`](dsp56001-notes.md) was never inflated by the
emulator. `489.40 = 32,084,988 / 2 / 32,779.95` is the hardware's 16 MIPS, so
the rt5 figure of 336.60 cycles per frame with 31.2% spare is a
statement about a real Falcon. Only the *emulated machine* was twice as fast as
the one those numbers describe.

## What did change: everything paced by real time

`make stock-audio` replays Xevious at the stock 16 MHz 68030 and requires every
steady SSI buffer handoff to land exactly 1024 words after the previous one.
The calibration first exposed 351 late boundaries. With the optimized player,
the same 1500-frame calibrated run is down to three:

| implementation / Hatari | handoffs | steady intervals | late |
| --- | ---: | --- | ---: |
| before optimization / Homebrew 2.6.1 | 1113 | 1111 × 1024 | 0 (0.00%) |
| before optimization / calibrated | 761 | 408 × 1024, 351 × 2048 | 351 (46.25%) |
| optimized / calibrated | 1105 | 1100 × 1024, 3 × 2048 | 3 (0.27%) |
| pipelined / calibrated | 1111 | 1109 × 1024 | 0 (0.00%) |

An interval of 2048 words is the transmit path repeating the last complete
period because the next one was not ready — the designed underrun response.
The producer/consumer pipeline described below eliminated the last three
repeats: every steady handoff in the calibrated run lands exactly 1024 SSI
words after the previous one, and `make stock-audio` passes.

Every other gate still passes, because none of them asserts period-boundary
punctuality and the capture path is blocking rather than real-time paced:

| gate | Homebrew 2.6.1 | calibrated |
| --- | --- | --- |
| `check` | pass | pass (no emulator) |
| `smoke` | pass | pass |
| `capture-realtime` | pass | pass, 24/24 scenarios |
| `endurance` | pass | pass |
| `endurance-batch` | pass | pass, 19/19 corpus songs |
| `stock-audio` | pass | pass — 0 missed boundaries with the pipeline |

`endurance` and `endurance-batch` score refill volume and a clean `Dsp_Unlock`,
not punctuality, so a run in which a third of the periods are repeats still
counts every refill and passes. `stock-audio` is the only gate that measures
the boundary, and it is the only one that moved.

## Where the budget actually goes

`make profile-dsp-live` (`tools/profile_dsp_live.py`) arms the DSP profiler at
the 300th realtime refill of a real corpus song and saves it 128 refills later,
so the window covers whole production periods including the SSI transmit
interrupt, the host-port receive and the refill command — all of which the
bracketed `profile-dsp-rt*` windows exclude. Xevious, 16 MHz 68030:

```
  instruction cycles per codec frame (budget 489.40):
    synthesis and transport:    391.80     80.1% of budget
    stalled on the host port:     0.44      0.1% of budget
    idle at the SSI boundary:    97.15     19.9% of budget

  DSP occupancy:              80.1% of real time
  margin:                     97.16 cycles per frame
```

(Before the eight-track work below, the same window read 426.76 work, 87.3%
occupancy and a 62.18-cycle margin; the receive of an all-zero PCM period
alone cost 28 of the difference.)

With the early-accept pipeline the host-port stall is nearly gone: the
payload transfer happens inside the previous period's boundary wait, so its
DSP-side word handling is counted as work (the rise from 407.59 to 426.76
cycles per frame is that reclassified receive, not new synthesis cost) and
the handoff pays only the event commit and the render. The probe arms at the
boundary catch that every switch passes once, because early-accepted refills
bypass the stream-loop receive it previously counted.

The reduction combines several independent changes:

- unmodulated DSP stages software-pipeline their sine fetch and ring store, and
  feedback accumulation uses both data buses beside the carrier multiply;
- the 68030 writes each zero-padded 24-bit host word with one `move.l` instead
  of three separately wait-stated byte writes, with the short transfer protected
  from a mid-stream MFP interruption;
- the DSP acknowledges an owned PCM payload before committing its staged YM
  burst, overlapping that work with preparation of the following period;
- YM batch coalescing is constant-time rather than a growing linear rescan; and
- silent, single-voice, precached-unity, and overlapping PDX blocks have
  progressively cheaper host mixer paths.

All checksum and perceptual gates remain unchanged. The final three misses
were cleared by exactly the producer lookahead this document called for, built
on both sides of the host port:

- **68030 producer queue.** The player rotates three staging buffers: one
  payload is ANNOUNCED to the DSP (its `19` command word parked in the host
  receive register), one complete payload is QUEUED behind it, and one is
  being prepared. Delivery is decoupled from the loop: `dsp_rt_submit_poll`
  releases the announced block from seams inside the sequencer drain and the
  PDX mixer, and the 1,024 Hz Timer-A handler runs the same delivery poll
  directly, bounding the response to READY to about one tick even while the
  foreground is deep inside a dense preparation. A payload whose preparation
  overruns its period therefore borrows idle time from its neighbours instead
  of pushing an already-finished payload past the DSP's render deadline.
- **DSP early accept (command `1a`).** Opted into once per session by the
  player, the DSP's post-render boundary wait doubles as a host service loop:
  the parked refill is received during the PREVIOUS period's tail, so the
  handoff pays only the event commit and the render. The receive and its
  acknowledgement wait are boundary-aware — every host-word wait also watches
  for the r6 wrap and performs the stereo-safe handoff in place — so a
  transfer may arrive at any phase and freely straddle the boundary. The
  wrap test runs before the data test on every word, because a paced blast
  that runs ahead of the receive would otherwise cross the wrap without a
  single look at r6.
- **One payload per coalesced burst.** `DSP_RT_BATCH_MAX` grew from 64 to
  224 and the burst stages in dedicated external X memory, so even a full
  eight-channel voice load rides a single refill payload. The former
  batch-overflow flush — synchronous command-`02` writes that serialized
  against a busy DSP for whole periods at song start and at dense phrases —
  no longer occurs in any corpus song.

Conformance and capture flows never send command `1a`, so their command
timing against the stream loop is unchanged; a mid-wait stop still completes
the running period's handoff first, keeping the frame count a post-handoff
stop would have produced.

Before these optimizations, two controls separated the original two errors:

| configuration | late handoffs |
| --- | --- |
| calibrated, host-port wait states zeroed (`HATARI_DSP_WS_*=0`) | 22.33 % |
| calibrated, `--cpuclock 32` | 0.00 % |

Zeroing the host port halved the old misses without clearing them, so the DSP
clock and the host port each accounted for roughly half the original deficit. The `--cpuclock 32`
control is not a host-side isolation — the calibrated build derives DSP cycles
from CPU cycles, so doubling the CPU clock doubles the DSP too and reproduces
stock behaviour. It confirms the mechanism rather than apportioning it.

## Eight-track FM songs

Two eight-track, FM-only MDX files from the same composer (`STAGE5.MDX` and
`STAGE6.MDX`, kept outside the corpus) sounded blurry on the physical Falcon
on 2026-09-08, STAGE5 from the first note and STAGE6 after a few seconds.
The calibrated emulator reproduced the first case outright and explained the
second: the DSP, not the host, was the wall. Its per-payload cost was
measured with a variant of `profile_dsp_live.py` that plays any MDX through
`AUTOPLAY.INF`, divides by the number of payloads actually rendered rather
than by boundary catches (a receive that straddles the wrap hands off inside
`rt5_early_wait_host`, never at `command_rt_refill_at_boundary`, so the
profiler's period count undercounts on a busy song), and with a chain of
one-handoff `dp save` snapshots that records every payload on its own.

| song, calibrated 16 MHz | late boundaries | DSP work per payload | note |
| --- | ---: | ---: | --- |
| STAGE5, before | 314 of 846 (37.1%) | 518 cycles/frame, 106% | misses from the first second |
| STAGE6, before | 0 of 1162 | 428 cycles/frame, 87% | no margin left for hardware |
| STAGE5, after | 24 of 1135 (2.1%) | 400–430 typical, 480–517 at peaks | peaks are envelope and event bursts |
| STAGE6, after | 0 of 1161 | 358 cycles/frame, 73% | |
| Xevious `stock-audio`, after | 0 of 1109 | unchanged 1109 × 1024 | |

Where the STAGE5 period went, per payload frame against the 489.40-cycle
budget: carrier passes 152, feedback stages 76, receiving 512 PCM words that
were all zero 46, envelope pass ~40, block AM ~36, per-block dispatch ~26,
emit 9, the SSI interrupt 6. The host was never late: the boundary wait left
through its "payload resident" test on all but one iteration per period.

The changes, each byte-equal to the previous build on the twenty capture
scenarios of the time and leaving the smoke mix checksum unchanged. That
was not the same as bit-identical everywhere: review found two paths the
gate never exercised, both regressed by the stream flags and the AM
rewrite and both fixed and gated since (see below).

- **Silent PCM periods send nothing** (protocol v25). A period with no active
  PDX voice sets bit 2 of its pan word and carries no sample words; the 68030
  skips a 512-word paced blast and the DSP its per-word receive loop, about
  45 cycles per frame on an FM-only song. The DSP marks its planar streams
  unwritten instead of zeroing them (see below) and synthesizes one explicit
  zero block only when the two-tap filter still owes frame 0 half of the
  previous period's last host point.
- **Fused Y-ring carrier loops.** The R:Y class II move `y0,a a,y:(r5)+`
  reloads the next modulation word beside the ring store, one instruction
  per frame per both- or right-panned carrier; the gain rides in `x0`.
- **Feedback stages store through the onward multiply.** The newest history
  product lives in the X slot and ages into Y beside the sum, so the store
  needs no instruction of its own: 11 instructions per frame become 10.
- **AM pass rewritten** with walking pointers and one unrolled apply per
  channel: about 20 cycles per frame less while the LFO is engaged.
- **Write-first planar streams and four emit passes.** Each block seeds a
  written flag per stream from the period's PCM state; the first one-sided
  carrier of an unwritten stream stores, and the emit reads only written
  streams (nine, seven, seven or five cycles per frame).
- **Pitch rebuilds deferred to the end of each drain**, once per marked
  channel. A voice load carries eight pitch-bearing writes; it used to pay
  eight four-operator rebuilds of about 600 cycles each.
- **Algorithms 4 and 5 decode the pan class once per channel**, not once
  per carrier, from the second island.
- **Burst-commit bug fixed.** When a period's batch exceeded the 32-entry
  rolling queue, the full-queue path drained the due entries through the
  decoders, which scratch `r2`, while `rt5_commit_runtime_events` was walking
  `r2` through the staged burst; every write after the 32nd was replaced by
  whatever the stale pointer addressed. STAGE5 batches reach 137 words,
  STAGE6 38, Xevious 43. The walker is now parked across the drain.

The `$17` profile checksum moved from `fe eb ad` to `fe eb 65`: it folds the
packed dispatch word of channel 7, whose entry address moved by exactly 72
words when algorithms 4 and 5 left the main stream, and by nothing else.

Two regressions escaped that gate and were caught in review, against
`8fb77e2`. One-sided channel-7 noise vanished on a silent-PCM period: the
noise substitution accumulated into a planar stream without joining the
write-first contract, so the stream stayed flagged unwritten, the next
one-sided carrier overwrote it and the emit never read it. The rewritten AM
walk cleared `rt5_am_engaged` and never raised it again, so once the AM
depth returned to zero the pass stopped walking and every scaled gain pair
stayed scaled - a sustained note fell from about ±8,192 to ±1. Fixing the
noise path also exposed an older defect: right-only noise had always
accumulated into X memory at the right stream's Y address, i.e. into the
SSI buffers, and never reached the right output. The gate now has 24
scenarios: `noise-left`, `noise-right` and `lfo-am-off` grade the panned
noise level, its leak into the other output, and the amplitude after AM
turns off.

The vibrato depth came last. The kernel's PM had been a global linear
increment offset, index times depth over 64, blind to PMS and to the pitch
it moved, which at PMS 7 barely stirred a tone the oracle sweeps by almost
an octave. It now derives ymfm's `m_lfo_pm` per block and multiplies each
PM channel's base increments by `2^(delta/768)` from a table divided out of
the phase-step table at start (see `dsp56001-notes.md`). The `lfo-pm`
scenario holds the operator's phase advance within 2% of the oracle per
quarter. The pass costs about 45 cycles per PM channel and block: STAGE5,
which drives two channels with the OPM LFO, renders its typical payload at
422 cycles per frame instead of 415 and misses 40 boundaries instead of 25;
STAGE6 still misses none, and the rt5 profile gate rises from 331.69 to
336.60 cycles per frame.

What remains is measured, not guessed: the STAGE5 payloads that still miss
are key-on and voice-load bursts where the envelope walk and gain rebuilds
add 80–100 cycles per frame on top of a 400-cycle base. The envelope pass
lives in internal P RAM, which is full to the last word, so the next step
there is to move cold command-loop code out of that window first. Neither
song has been played on the Falcon since these changes; the hardware verdict
is still owed, and so is the soak.

## What this does not say

The calibrated build fixes the DSP's throughput and the host port's cost. It
does not make Hatari's Falcon audio path authoritative: the SSI receive
substitution, invented DAC starvation, and unmodelled video-shifter bus
contention listed under [What the emulator cannot
decide](architecture.md#what-the-emulator-cannot-decide) are all still in force,
and the 68030 side still loses no bus cycles to the shifter. A real Falcon has
*less* host bandwidth than this build models, not more, so 87.3% occupancy and
the zero-repeat cadence result are optimistic rather than conservative: the
physical-Falcon validation still has to confirm them.

## First measurements from a physical Falcon

`release/dspprobe.tos` run on a real Falcon030 on 2026-09-02, before the
kernel cleared the Bus Control Register:

```
BCR after Dsp_ExecBoot: $ffff
timing with BCR as found (8,000,000 words per run, TOS 200 Hz ticks):
  fetch from internal P : ticks 100  = 2.00 clocks/word
  fetch from external P : ticks 850  = 17.00 clocks/word
  read external X data  : ticks 850  = 17.00 clocks/word
  read external Y data  : ticks 850  = 17.00 clocks/word
BCR after clearing:     $0000
timing with BCR cleared:
  fetch from internal P : ticks 100  = 2.00 clocks/word
  fetch from external P : ticks 100  = 2.00 clocks/word
  read external X data  : ticks 100  = 2.00 clocks/word
  read external Y data  : ticks 100  = 2.00 clocks/word
memory decode (model: Y:$2000 = P:$2000, X:$2000 = P:$6000):
  Y:$2000 <- $a5c3a5  reads Y:$2000=$a5c3a5 P:$2000=$a5c3a5
  X:$2000 <- $3c5a3c  reads X:$2000=$3c5a3c P:$6000=$3c5a3c
  shadows (information only): X:$6000=$3c5a3c Y:$6000=$a5c3a5
  decode matches the model  PASS
```

Three things follow. The reset BCR does reach the kernel through the
`Dsp_ExecBoot` path, and it costs exactly the manual's fifteen wait states:
seventeen clocks per external word against two, so every production build
before the fix ran its externally fetched kernel 8.5 times slower than any
figure in this document and repeated periods continuously - the "robotic"
playback reported from hardware. The Falcon's DSP SRAM is zero-wait once
the register is cleared, on all three external paths, so the one-word fix
at `start:` restores the modeled cost in full. And the external decode is
the one the code islands assume, shadows included, which retires the
aliasing probe from the soak plan. The internal reference also puts this
machine's DSP clock at 32.0 MHz against the 32,084,988 Hz Hatari models, a
0.27% difference. That clock figure is only good to one percent, since it
came from a 100-tick run; separating 32.000 from 32.085 MHz needs a run of
several thousand ticks.

### The SSI rate test found no clock

The same session ran `release/ratetest.tos`, and it failed outright:

```
timebase: TOS 200 Hz tick; 10 s window per prescale
model: rate = 25175000 / 256 / (prescale+1) Hz
prescale 3: no SSI frames in the window (crossbar clock dead)  FAIL
prescale 1: no SSI frames in the window (crossbar clock dead)  FAIL
prescale 2: no SSI frames in the window (crossbar clock dead)  FAIL
RESULT: FAIL (3 of 3 runs failed)
```

The DSP booted, answered the ping and every counter read, so the boot path
and the host port are fine; the transmitter simply never saw a word slot.
Hatari clocks the same configuration without complaint (`make
ratetest-hatari` passes), which makes this the second confirmed instance,
after `PCC`, of [the emulator running a peripheral the hardware leaves
unconfigured](architecture.md#what-the-emulator-cannot-decide). The
production player does play through the same route, and it differs from the
rate test in exactly five steps: `Buffoper(0)`, `Sndstatus(1)`,
`Soundcmd(ADDERIN, matrix)`, `Setmontracks(0)`, and arming the transmitter
only after `Devconnect`. The rate test therefore now bisects: it applies
those steps one at a time, cumulatively, probes each state for one second at
prescale 3, and prints the DSP's word and frame counters, its SSISR and the
crossbar registers as TOS left them, before measuring in the first state
that clocks. Whichever step turns the clock on is a rule Hatari has to
enforce as well: an emulator that clocks the SSI in a state where the Falcon
does not is as wrong as one that refuses to. The bus probe above is
unaffected; it never enables the SSI.

### The bisect run passed, and did not reproduce the failure

`release/ratetest.tos` at `2fd5899`, run on the same Falcon030 on
2026-09-08:

```
inherited regs 8900=0500 8920=0043 8930=0010 8932=2000 8934=0002 8936=0003
phase A bare: frames 24585  words 49170  ssisr $500  clock present
  regs 8900=0500 8920=0043 8930=0090 8932=2000 8934=0003 8936=0003
measuring prescale 3 (10 s) ...
prescale 3: frames 245855  ticks 2000  measured 24585.500 Hz  expected 24584.96
prescale 1: frames 491711  ticks 2000  measured 49171.100 Hz  expected 49169.92
prescale 2: frames 327810  ticks 2000  measured 32781.000 Hz  expected 32779.94
RESULT: PASS (3 runs)
```

Phase A *is* the bare bring-up that found no clock six days earlier, so the
bisect stopped at its first probe and steps B through G never ran: the run
proves the rate model and says nothing about which bring-up step matters.
The three measurements sit 21.9, 24.0 and 32.1 ppm above the model, a
consistent positive bias two orders of magnitude inside the 0.1 % gate, so
the crystal is a hair fast and both the clock source and the divider law are
confirmed at three points. Word slots came to exactly twice the frames with
no underrun line, so the polled loop served every slot it was offered.

The failure is therefore unexplained rather than fixed, and the program is
not the explanation. On the phase A path the two versions issue the same
calls in the same order — `Locksnd`, `Setmode`, `Settracks`,
`Dsptristate(1,0)`, `Devconnect` — and the DSP-side changes are additive: a
word counter, an SSISR read, a re-arm command phase A never sends, and the
boot register writes moved into `rate_ssi_arm` with `CRB`/`CRA`/`CRB` in
their original order. Neither version touches `BCR`. What differed was
outside the program: the machine state the run inherited, which the failing
run did not record and this one does. Treat the 2026-09-02 result as an
intermittent, state-dependent dead clock, not as a rule Hatari has to
enforce, and if it returns, the `inherited regs` line against this one is
the first discriminator to read.

### Playback on hardware, after the bus fix

The same session played `XEVVERB.TOS` and `XEVIOUS.TOS` on the machine, and
both sounded good. That is the first audio this player has produced on real
hardware with the `BCR` clear in the kernel, and it closes the wait-state
explanation for the "robotic" playback above: the register was measured at
fifteen wait states, two clocks per external word once cleared, and the
audible defect is gone with the one-word fix at `start:`.

The listen was not instrumented, so it settles the cause and nothing else.
No repeat or underrun counter was read, no `Sndstatus(0)` clipping value was
taken, the material was not the loudest in the corpus, and it ran in one
video mode for one sitting. Steps 3 to 7 of the hardware soak plan in
[`architecture.md`](architecture.md#what-the-emulator-cannot-decide) still
stand, and production playback still has no measured physical-Falcon
validation or long-duration soak.
