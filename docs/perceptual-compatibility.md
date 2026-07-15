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

The comparator enforces these boundaries:

| Behavior | Acceptance boundary |
| --- | --- |
| native clock and writes | exact frame/native-sample map and exact ordered event hashes |
| pitch | at most 20 ppm long-term phase drift and less than one codec frame of phase error |
| envelope | mean attenuation error at most 24/1023, correlation at least 0.95, state transitions within 64 frames |
| LFO | AM range within 25%, dominant-rate error at most one FFT bin, spectral cosine at least 0.90 |
| noise | transition-rate error at most 3%, state-spectrum cosine at least 0.70 |
| feedback and algorithms | spectral cosine at least 0.70, normalized log-spectrum RMSE at most 12 dB, RMS energy within 0.20-5.0x |

The phase, event, and accumulator boundaries are intentionally stricter than
the timbre boundary: long-term pitch and control timing are chip semantics,
whereas the 256-step sine ROM, codec-rate feedback, and YM3012 approximation
are the selected perceptual compromise. The comparator does not replace the
exact command-clocked conformance suite or the later real-MDX/PDX corpus.
