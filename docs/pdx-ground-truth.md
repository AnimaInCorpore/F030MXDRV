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

## Current boundary

`src/m68k/pdx.s` provides validated lookup and one stateful decoder voice. It
does not yet make PDX audible: MDX PCM commands are not parsed, and playback
rate conversion, pan, volume, multiple voices, and mixing with DSP-generated FM
audio remain to be implemented.
