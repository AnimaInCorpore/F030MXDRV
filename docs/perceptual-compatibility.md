# YM2151 perceptual compatibility gate

The real-time Falcon kernel targets perceptual compatibility at the quality
clock's 24,584.9609375 Hz frame rate. The exact 62.5 kHz ymfm path remains the oracle,
but codec-rate output is not required to match its individual samples. This
gate turns that relaxed boundary into deterministic data and pass/fail rules.

## Reference corpus

`make check` generates 19 TSV files under
`build/reference/ym2151-perceptual/`:

- sustained pitch, non-aligned key/register-write timing, a complete ADSR
  contour, AM/PM LFO, channel-7 noise at the fastest and a slow latch
  rate, and per-operator DT1/DT2 detune scenarios;
- algorithms 0-7 with operator-1 feedback level 4;
- algorithm 0 at feedback levels 0 and 7; and
- two real voices sustained at feedback level 7 for eighty 512-frame periods
  (40,960 frames), the long-run stability scenarios gated on their
  output-splice count: `feedback-7-long` on algorithm 4 (O1 feeds two
  independent carrier pairs) and `feedback-7-long-algorithm-5` on algorithm 5
  (O1 fans out to three carriers), the topology the coupled fold found hardest.

The algorithm and feedback scenarios drive `perceptual_topology.trace`,
whose modulators sit 6-9 dB below full volume. The earlier all-carrier
fixture ran every operator at total level zero, and at that maximal
modulation depth a four-stage cascade is chaotic: instrumented model
intermediates agree with independent recomputation within table
quantization on early stages and then diverge by dozens of sine-index
steps from a fraction of a percent of difference, so two correct
implementations with different table quantization (ymfm's 13-bit log
tables against the DSP's 24-bit linear ROM) separate trajectory-wise and
the spectral comparison graded chaos flavor. At moderate depth the
cascades stay in the regime where quantization differences remain small,
and the gate discriminates real pitch, depth, routing, and envelope
errors — which is its purpose. No requantized implementation can track
the maximal-depth trajectories.

The oracle advances exact ymfm native samples with the same 2560:1007
zero-order schedule as `ssi_render_frame`. Writes are applied before their
exact native sample. Each output row therefore describes the first codec frame
that can contain the effect of every ordered write.

Every row contains:

| Field | Meaning |
| --- | --- |
| `frame` | zero-based Falcon codec frame |
| `native_sample` | last exact 62.5 kHz sample consumed for this frame |
| `event_count`, `event_hash` | ordered writes consumed in this frame and an FNV-1a hash of timestamp/register/data |
| `left`, `right` | exact YM3012-rounded output selected by zero-order conversion |
| `lfo_am`, `noise_state` | exact control state at the frame boundary |
| `opN_phase`, `opN_step` | exact logical-operator phase and cached step |
| `opN_env`, `opN_state` | exact logical-operator attenuation and ADSR state |

`tools/compare_ym2151_realtime.py validate` also proves that the corpus itself
has a drift-free 2560:1007 schedule, all required event markers, visible ADSR,
AM/PM and noise activity, eight distinct algorithm fingerprints, and distinct
feedback spectra. This prevents an accidentally silent or ineffective fixture
from weakening the later candidate comparison.

## Native perceptual projection

The oracle also emits an independent projection under
`build/reference/ym2151-perceptual-model/`. It keeps the exact frame-boundary
phase, ADSR, LFO, noise, and ordered-write state, but renders operator topology
only once per codec frame, quantizes the logical 1024-step waveform phase onto
the DSP56001's 256-step sine ROM, and advances its own feedback history at the
codec rate. It then applies the channel algorithms, panning, noise substitution,
and YM3012 round trip independently of ymfm's native-rate channel output.

This isolates the chosen synthesis-rate/timbre compromise from control-state
implementation errors. The checked projection has zero pitch/control drift,
algorithm spectral cosine from 0.7731 to 0.9999, normalized log-spectrum RMSE
from 2.58 to 9.30 dB, and RMS energy ratios from 0.974 to 1.032. Its generated
`comparison-report.txt` is a build gate. It is not a substitute for capturing
the eventual DSP implementation, because it deliberately borrows exact
frame-boundary control state.

## Candidate contract

A DSP capture directory must contain the same 19 filenames and columns. Run:

```sh
make compare-realtime REALTIME_CANDIDATE_DIR=path/to/capture
```

## Capture harness

`make capture-realtime` produces and gates that directory automatically. For
each scenario the harness compiles the exact trace into a `CAPTURE.SCN`
(every scenario fits the 32-entry FIFO ring and its 32,767-sample horizon),
which switches the TTP's no-argument launch into capture mode: reset, queue
every write through the real rolling FIFO, then start and refill the
protocol-v23 realtime stream with silent PCM. Hatari debugger breakpoints
dump the rt5 phase accumulators, envelope state and block coefficients,
LFO/noise/timer scalars, and native clock at every 32-frame block entry, and
both SSI buffers after each completed 512-frame transaction; explicit
post-render symbols anchor buffer completion because protocol v23 acknowledges
host-buffer ownership before the DSP finishes rendering.

Reconstruction refuses to guess: the dumped native clock must match the
2560:1007 DDA at every boundary, consecutive LFSR dumps must be exactly 32
Galois steps apart, and every block's phase advance must equal its
per-segment increments at 510 accumulator units per frame — modulo one sine-ROM cycle
(2^32 accumulator units), because the independent-operator render path masks
the stored accumulator to the ROM index every frame — or the run aborts.
Because the kernel splits blocks at each write's landing frame, the
reconstruction carries a bit-exact Python mirror of the channel pitch
rebuild (positions, DT1/DT2, multipliers, and the block-DDA scale from the
same vendored ymfm tables); the mirror supplies the increments for segment
spans no boundary dump exposes, and every dump's increments must equal the
mirror's final segment or the run aborts, so the mirror can never drift
from the kernel unnoticed. Audio
comes from the captured buffers (24-bit 0.23 samples reported in the
16-bit host domain). Phase accumulates the verified per-block increments
into an unwrapped series emitted in ymfm's 2^22 domain, zeroed when a
key-on edge drains at a block boundary exactly as the kernel zeroes the
operator's phase. Envelope levels follow the affine mid-block contract
above with the addend derived from the realized step, per-frame noise
replays the same right-shifting x^17+x^14+1 Galois LFSR, and the schedule
columns replicate the oracle's event policy bit for bit.

An attack that key-ons and converges inside one block never exposes its
multiplier or an attack state at any boundary — the boundary pass consumes
and reloads both — so the reconstruction rebuilds that block from the
published per-rate attack table and the same effective-rate decode the
kernel runs (attack rate doubled plus the KSR-shifted key code), emitting
ymfm's overshooting exponential toward -1024 for the first half-block,
anchoring the second half to the verified dumped exit, and reporting a
genuine attack state whose decay transition lands at the block boundary.
The reported `lfo_am` is the kernel's own published block `m_lfo_am`
shifted by the decoded channel sensitivity, block-held like every other
realtime control.

The checked report is regenerated at 24.585 kHz. Pitch, detune, ordered-write
timing, LFO, noise, envelope state, all eight algorithms, feedback 0/7, and
the sustained-feedback splice fixture are graded in two explicit tiers. The
independent codec-rate model must first pass absolute exact-reference bounds.
The captured DSP is then checked against that same exact-feedback model for
the residual caused by its linear 256-step ROM and block-quantized state. No
folded-feedback model or per-algorithm feedback bias is accepted.

The realtime engine advances envelope state once per 32-frame block with a
published per-rate affine recurrence, so a capture reconstructs each
operator's mid-block level analytically from the block-boundary dump and the
same recurrence, then interpolates per-frame rows linearly between the
32-frame points; ADSR state columns hold the boundary value. The checked DSP
capture scores mean attenuation error 1.62/1023, correlation 0.9996, and a
four-frame transition lag against the exact ADSR reference.

## Feedback-depth record

The 24.585 kHz budget allows M1 to produce two products per frame. One uses
the normal serial gain for audible onward modulation; the other uses the
feedback-level history gain, matching ymfm's
`(out0 + out1) >> (10 - FB)` law independently for levels 1–7. Feedback zero
still dispatches to the no-history bypass. Algorithm 7 alternates its carrier
and history gains through the same modulo-2 gain ring, so its audible carrier
is not attenuated to obtain the requested history depth.

This removes the former coupled fold, its per-algorithm bias table, and the
special level-7 repair class. The integrated worst-case profile measures
364.14 cycles per quality frame against a 652.53-cycle budget. Sustained FB7
remains separately splice-gated because feedback trajectories are sensitive
to waveform-table quantization even when their depth law is correct — the
exact-arithmetic implementation model already carries the ROM/block
quantization the DSP capture must additionally survive, and its own
splice count is now printed alongside the candidate's (`model_splices` in
the comparator report) so a future failure can tell which layer diverged.

`feedback-7-long` only ever exercised algorithm 4, where O1 drives two
independent carrier pairs. Algorithm 5 routes O1's output to three carriers
in parallel instead of two, the single-operator depth split the coupled
fold's per-algorithm bias table struggled hardest to tune (see the removed
per-algorithm bias history above). `feedback-7-long-algorithm-5` replays the
same two voices and levels recabled to CON5 to fence that topology
independently.

Its exact reference legitimately swings harder than CON4's: a shared O1
discontinuity now combines across three summed carriers instead of two,
peaking at 12,312 with no growth over the run (steady-state, spread evenly
across all ten deciles of the 40,960 frames — not a limit cycle). This
scenario alone therefore uses a 13,000-count splice threshold
(`SPLICE_THRESHOLDS` in `compare_ym2151_realtime.py`) instead of the shared
8,000 bound tuned against algorithm 4's smoother topology; the 25-splice
count margin, the part of the gate that actually catches instability, is
unchanged. The quantized model already comes in clean at either threshold
(max step 7,708) — its 256-step ROM rounds off exactly the sharp edges that
push the exact reference past 8,000.

The comparator enforces these boundaries:

| Behavior | Acceptance boundary |
| --- | --- |
| native clock and writes | exact frame/native-sample map and exact ordered event hashes |
| pitch | at most 20 ppm long-term drift between least-squares phase rates and less than one codec frame of phase error |
| envelope | mean attenuation error at most 24/1023, correlation at least 0.95, state transitions within 32 frames |
| LFO | AM range within 25%, dominant-rate error at most one FFT bin, spectral cosine at least 0.90 |
| noise | transition-rate error at most 3%, state-spectrum cosine at least 0.70 |
| model feedback and algorithms vs exact | spectral cosine at least 0.70, log-spectrum RMSE at most 12 dB, RMS energy within 0.20-5.0x |
| DSP feedback and algorithms vs model | spectral cosine at least 0.60, log-spectrum RMSE at most 14 dB, RMS energy vs exact within 0.20-5.0x |

For a DSP/model pair with cosine at least 0.95, the log-RMSE ceiling is not
applied. This handles sparse carrier spectra where both signals put virtually
all power in the same bins but one linear-ROM harmonic lands exactly on the
numeric zero floor; cosine and the independent energy bound still gate the
audible result. The exact-reference cosine and log-RMSE remain printed for
every captured topology even when the implementation tier is decisive.

The phase, event, and accumulator boundaries are intentionally stricter than
the timbre boundary: long-term pitch and control timing are chip semantics,
whereas the 256-step sine ROM, codec-rate feedback, and YM3012 approximation
are the selected perceptual compromise. The comparator does not replace the
exact command-clocked conformance suite or the later real-MDX/PDX corpus.
