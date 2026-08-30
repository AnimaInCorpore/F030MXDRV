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
| `profile-dsp-rt5` | 346.21 per codec frame | 489.40 | 0.71x |

This is the expected result and it is worth stating plainly: the static budget
analysis in [`dsp56001-notes.md`](dsp56001-notes.md) was never inflated by the
emulator. `489.40 = 32,084,988 / 2 / 32,779.95` is the hardware's 16 MIPS, so
the rt5 figure of 346.21 cycles per frame with 29.3% spare is a
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
| `capture-realtime` | pass | pass, 19/19 scenarios |
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
    synthesis and transport:    426.76     87.2% of budget
    stalled on the host port:     0.45      0.1% of budget
    idle at the SSI boundary:    66.00     13.5% of budget

  DSP occupancy:              87.3% of real time
  margin:                     62.18 cycles per frame
```

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
