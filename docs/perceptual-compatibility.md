# YM2151 perceptual compatibility gate

The real-time Falcon kernel targets perceptual compatibility at the codec's
49,169.921875 Hz frame rate. The exact 62.5 kHz ymfm path remains the oracle,
but codec-rate output is not required to match its individual samples. This
gate turns that relaxed boundary into deterministic data and pass/fail rules.

## Reference corpus

`make check` generates 15 TSV files under
`build/reference/ym2151-perceptual/`:

- sustained pitch, non-aligned key/register-write timing, a complete ADSR
  contour, AM/PM LFO, and channel-7 noise scenarios;
- algorithms 0-7 with operator-1 feedback level 4; and
- algorithm 0 at feedback levels 0 and 7.

The oracle advances exact ymfm native samples with the same 1280:1007
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
has a drift-free 1280:1007 schedule, all required event markers, visible ADSR,
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
algorithm spectral cosine from 0.7229 to 0.9999, normalized log-spectrum RMSE
from 5.09 to 10.61 dB, and RMS energy ratios from 0.967 to 1.028. Its generated
`comparison-report.txt` is a build gate. It is not a substitute for capturing
the eventual DSP implementation, because it deliberately borrows exact
frame-boundary control state.

## Candidate contract

A DSP capture directory must contain the same 15 filenames and columns. Run:

```sh
make compare-realtime REALTIME_CANDIDATE_DIR=path/to/capture
```

## Capture harness

`make capture-realtime` produces and gates that directory automatically. For
each scenario the harness compiles the exact trace into a `CAPTURE.SCN`
(every scenario fits the 32-entry FIFO ring and its 32,767-sample horizon),
which switches the TTP's no-argument launch into capture mode: reset, queue
every write through the real rolling FIFO, then start and refill the
protocol-v19 realtime stream with silent PCM. Hatari debugger breakpoints
dump the rt5 phase accumulators, envelope state and block coefficients,
LFO/noise/timer scalars, and native clock at every 64-frame block entry, and
both SSI buffers after each completed 1024-frame transaction; buffer
completion anchors on each handler's single `jsr send_reply` because Hatari
samples the DSP PC at do-loop-end+1 on every iteration.

Reconstruction refuses to guess: the dumped native clock must match the
1280:1007 DDA at every boundary, consecutive LFSR dumps must be exactly 64
Galois steps apart, and every block's phase advance must equal its dumped
increment times 510 frames-per-mac — modulo one sine-ROM cycle (2^32
accumulator units), because the independent-operator render path masks the
stored accumulator to the ROM index every frame — or the run aborts. Audio
comes from the captured buffers (24-bit 0.23 samples reported in the
16-bit host domain). Phase accumulates the verified per-block increments
into an unwrapped series emitted in ymfm's 2^22 domain, zeroed when a
key-on edge drains at a block boundary exactly as the kernel zeroes the
operator's phase. Envelope levels follow the affine mid-block contract
above with the addend derived from the realized step, per-frame noise
replays the same right-shifting x^17+x^14+1 Galois LFSR, and the schedule
columns replicate the oracle's event policy bit for bit.

One reconstruction limit is documented rather than hidden: an attack that
key-ons and converges inside one block never exposes its true multiplier or
an attack-state boundary, so that block falls back to a linear mid and the
attack state is invisible. The reported `lfo_am` is the kernel's own
published block `m_lfo_am` shifted by the decoded channel sensitivity,
block-held like every other realtime control.

The current report passes pitch (0.009 ppm least-squares drift, at most
7 counts of phase error), timing, the complete LFO gate (range ratio
0.984, dominant-bin error 0, spectral cosine 0.9973 with true block AM),
noise (1.55% rate error, 0.78 spectral cosine), algorithms 0-3 (spectral
cosine 0.72-0.76), and feedback-7, with FM on the correct stereo
channels. The measured open kernel work: feedback runs at one shared
depth — the raw history-pair sum, a level-9 equivalent — so
single-modulator topologies overdrive O1 against the level-4 reference
(algorithms 4-5 at cosine 0.28-0.69, log-RMSE over 12 dB on algorithms
4-7); the all-carrier algorithm 7 drops feedback entirely and pays for it
in log-RMSE; and feedback-0 measures 0.55 where the parametric model
predicts 0.74 at identical semantics, an unexplained kernel discrepancy
worth its own investigation. Envelope tracking is within
one attenuation unit outside the attack block (MAE 4.44, both late
transitions within 64 frames); its correlation shortfall (0.8902 vs 0.95)
is the documented attack-block reconstruction limit above, not measured
kernel behavior.

The realtime engine advances envelope state once per 64-frame block with a
published per-rate affine recurrence, so a capture reconstructs each
operator's mid-block level analytically from the block-boundary dump and the
same recurrence, then interpolates per-frame rows linearly between the
32-frame points; ADSR state columns hold the boundary value. The quantized
block recurrence itself scores mean attenuation error 2.99/1023, correlation
0.977, and 61-frame transition lag against the exact ADSR reference under
this reconstruction, inside every boundary below.

## Feedback-depth impossibility record

M1 produces one product per frame that feeds both the serial-modulation
ring and the two-word feedback history, and the nine-instruction stage
loop has no free data register, so ring and history scales are coupled:
any per-level depth must fold into M1's single gain, shifting its onward
serial modulation by the same factor. The oracle's perceptual model takes
`YM_MODEL_FOLD_MODE`/`YM_MODEL_FOLD_K` to simulate exactly that coupled
fold (exact ymfm when unset), and the comparator scores each variant
offline; the k0 column reproduces the captured DSP scores, validating the
predictor. Across fixed folds 0-3, the full per-level fold, and the half
fold, no variant brings algorithms 4-5 above spectral cosine 0.35 —
serial starvation and feedback overdrive trade against each other without
ever meeting the 0.70 boundary — while the exact-semantics model passes
everything (algorithm 4 at 0.943, 5 at 0.888, 6 at 0.979, 7 at 1.000
with feedback restored). Per-level depth therefore requires decoupled
scales: roughly two more instructions in the feedback stage loop, about
28 cycles/frame at the fixture's seven feedback-active channels against a
present margin of twelve. The block AM pass already early-outs when AM is
idle to preserve that margin. Until the render loop is restructured or
comparable headroom is found, feedback stays at the shared depth and
algorithms 4-7 remain outside the spectral boundaries.

The comparator enforces these boundaries:

| Behavior | Acceptance boundary |
| --- | --- |
| native clock and writes | exact frame/native-sample map and exact ordered event hashes |
| pitch | at most 20 ppm long-term drift between least-squares phase rates and less than one codec frame of phase error |
| envelope | mean attenuation error at most 24/1023, correlation at least 0.95, state transitions within 64 frames |
| LFO | AM range within 25%, dominant-rate error at most one FFT bin, spectral cosine at least 0.90 |
| noise | transition-rate error at most 3%, state-spectrum cosine at least 0.70 |
| feedback and algorithms | spectral cosine at least 0.70, normalized log-spectrum RMSE at most 12 dB, RMS energy within 0.20-5.0x |

The phase, event, and accumulator boundaries are intentionally stricter than
the timbre boundary: long-term pitch and control timing are chip semantics,
whereas the 256-step sine ROM, codec-rate feedback, and YM3012 approximation
are the selected perceptual compromise. The comparator does not replace the
exact command-clocked conformance suite or the later real-MDX/PDX corpus.
