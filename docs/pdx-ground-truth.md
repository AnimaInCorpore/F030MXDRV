# PDX and X68000 ADPCM ground truth

The standard PDX sample bank begins with 96 big-endian records. Each record is
an unsigned 32-bit offset from the beginning of the raw bank followed by an
unsigned 32-bit encoded byte length. The original MXDRV derives sample numbers
0-95 from its PCM note range, multiplies the number by eight, adds the selected
entry's offset to the PDX base, and passes its length to the ADPCM driver.

The port accepts the raw table-and-data bank rather than MXDRV's historical
resident-memory link wrapper. Lookup rejects banks shorter than the 768-byte
table, sample numbers above 95, nonempty offsets inside the table, and ranges
that exceed the copied bank. Empty entries return no sample.

## MSM6258 decoding

The X68000 configuration in the vendored MAME tree uses an OKI MSM6258 in
4-bit, 10-bit-output mode. Playback starts with predictor `-2` and step index
zero. Each encoded byte is consumed low nibble first and then high nibble.

For each nibble, MAME computes `stepval = floor(16 * 1.1^step)`. The magnitude
starts at `stepval/8` and adds `stepval/4`, `stepval/2`, and `stepval` for bits
0, 1, and 2. Bit 3 selects subtraction instead of addition. The predictor is
clamped to `-512..511`, then shifted left four bits for the signed output. The
step index changes by `{-1,-1,-1,-1,2,4,6,8}` selected by the low three bits
and is clamped to `0..48`.

`tools/pdx_adpcm_oracle.cpp` reproduces those operations for a fixed encoded
trace. The Falcon smoke harness copies a synthetic raw PDX through MXDRV call
`$03`, exercises valid, empty, overlapping, overrun, out-of-range, and
undersized cases, then compares all decoded samples with the generated vector.

## PCM8 voice conversion

The PCM8-facing layer has eight independent decoder states and the five MSM6258
clock selections used by MXDRV: 3.90625, 5.20833, 7.8125, 10.4167, and 15.625
kHz. Relative to the Falcon codec clock of `25.175 MHz / 4 / 128`, those rates
are represented exactly by phase increments `240, 320, 480, 640, 960` over the
common denominator `3021`. The current zero-order converter therefore has no
long-term clock drift.

PCM8 volume codes 0 through 15 map from -16 dB through +14 dB in 2 dB steps;
code 8 is unity. The mixer uses signed Q12 gains, sums all eight voices, and
saturates the result to 16 bits. PCM8 pan is common hardware state rather than
per-voice state: 1 selects left, 2 right, and 3 both. Pan value 0 denotes stop
in the original interface and is not accepted as a routing position.

The generated oracle also runs two voices over the same encoded sample at the
lowest and highest rates and at -16 dB and unity gain. Hatari checks 20 stereo
frames, global left-only pan, active masks, explicit stops, and parameter
bounds against that vector.

## Current boundary

`src/m68k/pdx.s` provides validated lookup plus the eight-voice host mixer. It
renders 1024 Falcon codec frames for each protocol-v19 realtime transaction.
The DSP expands the interleaved signed 16-bit host mix into planar 24-bit
accumulators, adds 16 64-frame FM blocks, saturates to the inactive interleaved
SSI buffer, and switches A/B buffers at a stereo boundary. MDX tracks 8-15
start and stop the eight voices, and the TTP player uses this realtime start and
refill path. The older 1007-frame exact FM/PCM stream remains as a conformance
gate. Real MDX/PDX corpus comparison and Falcon hardware underrun/contention
measurements are still required before calling playback complete.
