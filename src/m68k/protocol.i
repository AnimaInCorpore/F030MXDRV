; Host/DSP protocol. Keep in sync with src/dsp/protocol.inc.

DSP_PROTOCOL_VERSION equ     3

DSP_CMD_PING        equ     $010000
DSP_CMD_WRITE_REG   equ     $020000
DSP_CMD_RESET       equ     $030000
DSP_CMD_CLOCK       equ     $040000
DSP_CMD_QUERY_PHASE equ     $050000
DSP_CMD_QUERY_RIGHT equ     $060000
DSP_CMD_QUERY_ENV   equ     $070000

DSP_REPLY_HELLO     equ     $4d5803
DSP_REPLY_OK        equ     $000000
DSP_REPLY_ERROR     equ     $ffffff
