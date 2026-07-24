# MXDRV API compatibility

`src/m68k/mxdrv_core.s` provides a resident-independent dispatcher with the
same 32 call numbers and register-preservation convention as MXDRV 2.06+17.
The executable calls `mxdrv_call` directly; it does not install a resident
Trap #4 handler.

The dispatcher owns fixed-capacity copies of the active MDX and PDX data,
preserves every register except `d0`, and returns `-1` for an invalid or
unsupported call. This table describes the current implementation rather than
the full historical MXDRV ABI.

| Call | Current behavior |
| ---: | --- |
| `$00` | stop/reset the timer, driver, MDX, PDX, and YM state |
| `$01` | unsupported (`-1`) |
| `$02` | copy MDX data from `a1`, length `d1`; maximum 65,536 bytes |
| `$03` | copy and precache raw PDX data from `a1`, length `d1`; maximum 319,488 bytes |
| `$04` | stop the current song, parse the owned MDX, start playback, and claim MFP Timer A |
| `$05` | stop playback, release MFP Timer A, reset PDX, and key off all FM channels |
| `$06` | pause sequencer advancement |
| `$07` | clear the pause flag on a playing song; return `-1` when stopped |
| `$08` | return the owned MDX-buffer pointer when its size is at least four bytes; otherwise zero |
| `$09` | return the pointer after the first bounded CR/LF/`$1a` title terminator; otherwise zero |
| `$0a` | set the fade attenuation offset from `d1.b` |
| `$0b` | set the fade wait value from `d1.b` |
| `$0c` | arm fadeout using `d1.b` as the wait reload |
| `$0d` | unsupported (`-1`) |
| `$0e` | set the 16-bit channel mask from `d1.w` |
| `$0f` | set the channel mask and start playback |
| `$10` | return the 256-byte `OPMBuf`-compatible register mirror |
| `$11` | set an option byte, or return it when `d1` is negative; state only |
| `$12` | return playing/paused flags in the low word and completed loop count in the high word |
| `$13` | set the ignore-keys option and return its previous byte; state only |
| `$14` | return active MDX tracks after applying the channel mask |
| `$15` | set an option byte and return its previous value; state only |
| `$16` | set the stop-mode byte, stop playback, and return its previous value |
| `$17` | unsupported (`-1`) |
| `$18` | return the owned PDX/PCM buffer |
| `$19` | return the 16-byte PCM work area |
| `$1a`–`$1f` | unsupported (`-1`) |

Calls `$11`, `$13`, `$15`, and `$16` preserve the option state expected by the
current player and tests, but do not claim complete compatibility with every
side effect of the resident X68000 driver. Completing those edge semantics and
the nine unsupported entries remains release work.

## Playback timing

Call `$04` claims MFP Timer A only if its control, interrupt-enable, and
interrupt-mask bits show that it is unused. The level-6 interrupt accumulates
exact 16.16 timing and pending ticks but never calls XBIOS or writes to the DSP.
`mxdrv_mdx_clock_pump` must run in foreground context to drain those ticks and
perform synchronous DSP work. The bundled player does this once per realtime
audio refill.

Call `$05`, call `$00`, a natural song end, and every player error path release
the timer and reset the active decoder state. If Timer A is already owned,
play returns `-1` rather than replacing the existing user.

## Data ownership

Calls `$02` and `$03` copy their input. The MDX executor may therefore update
the in-stream repeat work bytes without modifying the caller's buffer. Every
header, table, track, voice, operand, repeat target, and PDX sample range is
checked against the copied size before it is used.

The `$08` and `$09` accessors are deliberately lighter-weight than playback
parsing: they do not validate a complete MDX header or prove that the returned
PDX pointer names a NUL-terminated string. Call `$04` to run the full bounded
MDX validation before using the copied data for playback.

The raw PDX contract is documented in
[`pdx-ground-truth.md`](pdx-ground-truth.md); command coverage and malformed
MDX behavior are documented in [`mdx-ground-truth.md`](mdx-ground-truth.md).
