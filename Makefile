VASM_ARCHIVE := third_party/f030dsp3d/tools/vasm.tar.gz
VLINK_ARCHIVE := third_party/f030dsp3d/tools/vlink.tar.gz
DSP_TOOL_SOURCE := third_party/f030dsp3d/tools/asm56k
YMFM_SOURCE := third_party/mame/3rdparty/ymfm/src

TOOLS_DIR := build/tools
VASM_DIR := $(TOOLS_DIR)/vasm
VLINK_DIR := $(TOOLS_DIR)/vlink
VASM := $(VASM_DIR)/vasmm68k_mot
VLINK := $(VLINK_DIR)/vlink

M68K_BUILD := build/m68k
XEVIOUS_M68K_BUILD := build/m68k-xevious
DSP_BUILD := build/dsp
NATIVE_BUILD := build/native
GENERATED_BUILD := build/generated
REFERENCE_BUILD := build/reference
YM2151_PERCEPTUAL_DIR := $(REFERENCE_BUILD)/ym2151-perceptual
YM2151_PERCEPTUAL_MODEL_DIR := $(REFERENCE_BUILD)/ym2151-perceptual-model
YM2151_PERCEPTUAL_REPORT := $(YM2151_PERCEPTUAL_DIR)/reference-report.txt
YM2151_PERCEPTUAL_MODEL_REPORT := $(YM2151_PERCEPTUAL_MODEL_DIR)/comparison-report.txt
YM2151_PERCEPTUAL_STAMP := $(YM2151_PERCEPTUAL_DIR)/.validated
DSP_PROFILE_DIR := build/dsp-profile
DSP_RT_PROFILE_DIR := build/dsp-profile-rt
DSP_RT2_PROFILE_DIR := build/dsp-profile-rt2
DSP_RT3_PROFILE_DIR := build/dsp-profile-rt3
DSP_RT4_PROFILE_DIR := build/dsp-profile-rt4
DSP_RT5_PROFILE_DIR := build/dsp-profile-rt5
DSP_RT_PROFILE_FRAMES := 2048
DSP_RT2_PROFILE_FRAMES := 2048
DSP_RT3_PROFILE_FRAMES := 2048
DSP_RT4_PROFILE_FRAMES := 2048
DSP_RT5_PROFILE_FRAMES := 8192
DSP_RT4_PROFILE_TARGETS := $(addprefix profile-dsp-rt4-alg,1 2 3 4 5 6)
RELEASE_DIR := release

YM2151_ORACLE := $(NATIVE_BUILD)/ym2151_oracle
PDX_ADPCM_ORACLE := $(NATIVE_BUILD)/pdx_adpcm_oracle
YM2151_TABLES := $(GENERATED_BUILD)/ym2151_tables.inc
ENVELOPE_TABLES := $(GENERATED_BUILD)/envelope_tables.inc
YM2151_HOST_TABLES := $(GENERATED_BUILD)/ym2151_host_tables.i
DSP_STAGE2_IMAGE := $(GENERATED_BUILD)/dsp_stage2_image.i
YM2151_REFERENCE := $(GENERATED_BUILD)/ym2151_reference.i
PDX_ADPCM_REFERENCE := $(GENERATED_BUILD)/pdx_adpcm_reference.i
YM2151_VECTORS := $(REFERENCE_BUILD)/attack_all_carriers.tsv

M68K_SOURCES := \
	src/m68k/main.s \
	src/m68k/player.s \
	src/m68k/capture.s \
	src/m68k/dsp_link.s \
	src/m68k/mxdrv_core.s \
	src/m68k/mxdrv_port.s \
	src/m68k/mdx.s \
	src/m68k/mdx_clock.s \
	src/m68k/pdx.s
M68K_OBJECTS := $(patsubst src/m68k/%.s,$(M68K_BUILD)/%.o,$(M68K_SOURCES))
XEVIOUS_M68K_OBJECTS := $(patsubst $(M68K_BUILD)/player.o,$(XEVIOUS_M68K_BUILD)/player.o,$(M68K_OBJECTS))
VERBOSE_M68K_BUILD := build/m68k-xevious-verbose
VERBOSE_M68K_OBJECTS := $(patsubst src/m68k/%.s,$(VERBOSE_M68K_BUILD)/%.o,$(M68K_SOURCES))

DOSBOX ?= $(shell command -v dosbox-staging 2>/dev/null || command -v dosbox 2>/dev/null)
DOSBOX_FLAGS ?= --noprimaryconf --set output=texture

.PHONY: all host xevious dsp reference check capture-realtime compare-realtime smoke stock-audio endurance endurance-batch profile-dsp profile-dsp-rt \
	profile-dsp-rt2 profile-dsp-rt3 profile-dsp-rt4 profile-dsp-rt5 \
	clean run tools xevious-verbose xevious-verbose50

all: host dsp

host: $(RELEASE_DIR)/f030mxdrv.tos $(RELEASE_DIR)/f030mxdrv.ttp \
		$(RELEASE_DIR)/xevious.tos

xevious: $(RELEASE_DIR)/xevious.tos

dsp: $(RELEASE_DIR)/ym2151.lod $(DSP_STAGE2_IMAGE)

reference: $(YM2151_REFERENCE) $(PDX_ADPCM_REFERENCE) $(YM2151_TABLES) \
		$(YM2151_HOST_TABLES) $(YM2151_VECTORS) $(YM2151_PERCEPTUAL_STAMP)

tools: $(VASM) $(VLINK)

$(TOOLS_DIR)/.vasm-unpacked: $(VASM_ARCHIVE)
	@mkdir -p $(TOOLS_DIR)
	tar -xf $< -C $(TOOLS_DIR)
	@touch $@

$(VASM): $(TOOLS_DIR)/.vasm-unpacked
	$(MAKE) -C $(VASM_DIR) CPU=m68k SYNTAX=mot

$(TOOLS_DIR)/.vlink-unpacked: $(VLINK_ARCHIVE)
	@mkdir -p $(TOOLS_DIR)
	tar -xf $< -C $(TOOLS_DIR)
	@touch $@

$(VLINK): $(TOOLS_DIR)/.vlink-unpacked
	$(MAKE) -C $(VLINK_DIR)

$(YM2151_ORACLE): tools/ym2151_oracle.cpp $(YMFM_SOURCE)/ymfm_opm.cpp \
		$(YMFM_SOURCE)/ymfm_opm.h $(YMFM_SOURCE)/ymfm_fm.h \
		$(YMFM_SOURCE)/ymfm_fm.ipp $(YMFM_SOURCE)/ymfm.h
	@mkdir -p $(NATIVE_BUILD)
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) -std=c++17 -O2 -I$(YMFM_SOURCE) \
		tools/ym2151_oracle.cpp $(YMFM_SOURCE)/ymfm_opm.cpp -o $@

$(PDX_ADPCM_ORACLE): tools/pdx_adpcm_oracle.cpp \
		third_party/mame/src/devices/sound/okim6258.cpp
	@mkdir -p $(NATIVE_BUILD)
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) -std=c++17 -O2 $< -o $@

$(YM2151_REFERENCE): $(YM2151_ORACLE) tests/traces/attack_all_carriers.trace \
		tests/traces/noise_channel7.trace tests/traces/timer_csm.trace \
		tests/traces/vibrato_pm.trace
	@mkdir -p $(GENERATED_BUILD)
	$(YM2151_ORACLE) --emit-m68k tests/traces/attack_all_carriers.trace \
		tests/traces/noise_channel7.trace tests/traces/timer_csm.trace \
		tests/traces/vibrato_pm.trace > $@

$(PDX_ADPCM_REFERENCE): $(PDX_ADPCM_ORACLE)
	@mkdir -p $(GENERATED_BUILD)
	$(PDX_ADPCM_ORACLE) --emit-m68k > $@

$(YM2151_TABLES): tools/generate_ym2151_tables.py $(YMFM_SOURCE)/ymfm_fm.ipp
	@mkdir -p $(GENERATED_BUILD)
	python3 tools/generate_ym2151_tables.py $(YMFM_SOURCE)/ymfm_fm.ipp > $@

$(YM2151_HOST_TABLES): tools/generate_ym2151_tables.py $(YMFM_SOURCE)/ymfm_fm.ipp
	@mkdir -p $(GENERATED_BUILD)
	python3 tools/generate_ym2151_tables.py --host $(YMFM_SOURCE)/ymfm_fm.ipp > $@

$(ENVELOPE_TABLES): tools/generate_envelope_tables.py $(YMFM_SOURCE)/ymfm_fm.ipp
	@mkdir -p $(GENERATED_BUILD)
	python3 tools/generate_envelope_tables.py $(YMFM_SOURCE)/ymfm_fm.ipp > $@

$(YM2151_VECTORS): $(YM2151_ORACLE) tests/traces/attack_all_carriers.trace
	@mkdir -p $(REFERENCE_BUILD)
	$(YM2151_ORACLE) --vectors tests/traces/attack_all_carriers.trace 256 > $@

$(YM2151_PERCEPTUAL_STAMP): $(YM2151_ORACLE) \
		tools/compare_ym2151_realtime.py \
		tests/traces/perceptual_topology.trace \
		tests/traces/noise_channel7.trace \
		tests/traces/noise_channel7_slow.trace \
		tests/traces/perceptual_pitch.trace \
		tests/traces/perceptual_detune.trace \
		tests/traces/perceptual_timing.trace \
		tests/traces/perceptual_envelope.trace \
		tests/traces/perceptual_lfo.trace \
		tests/traces/bisect_two_bom_fb7.trace \
		tests/traces/bisect_two_bom_alg5_fb7.trace
	@rm -rf $(YM2151_PERCEPTUAL_DIR) $(YM2151_PERCEPTUAL_MODEL_DIR)
	@mkdir -p $(YM2151_PERCEPTUAL_DIR) $(YM2151_PERCEPTUAL_MODEL_DIR)
	@for mode_and_dir in \
		"--codec-vectors:$(YM2151_PERCEPTUAL_DIR)" \
		"--perceptual-vectors:$(YM2151_PERCEPTUAL_MODEL_DIR)"; do \
		mode=$${mode_and_dir%%:*}; rest=$${mode_and_dir#*:}; \
		output_dir=$${rest%%:*}; \
		$(YM2151_ORACLE) $$mode tests/traces/perceptual_pitch.trace 8192 \
			> $$output_dir/pitch.tsv || exit 1; \
		$(YM2151_ORACLE) $$mode tests/traces/perceptual_detune.trace 8192 \
			> $$output_dir/detune.tsv || exit 1; \
		$(YM2151_ORACLE) $$mode tests/traces/perceptual_timing.trace 2048 \
			> $$output_dir/timing.tsv || exit 1; \
		$(YM2151_ORACLE) $$mode tests/traces/perceptual_envelope.trace 8192 \
			> $$output_dir/envelope.tsv || exit 1; \
		$(YM2151_ORACLE) $$mode tests/traces/perceptual_lfo.trace 8192 \
			> $$output_dir/lfo.tsv || exit 1; \
		$(YM2151_ORACLE) $$mode tests/traces/noise_channel7.trace 8192 \
			> $$output_dir/noise.tsv || exit 1; \
		$(YM2151_ORACLE) $$mode tests/traces/noise_channel7_slow.trace 8192 \
			> $$output_dir/noise-slow.tsv || exit 1; \
		for algorithm in 0 1 2 3 4 5 6 7; do \
			$(YM2151_ORACLE) $$mode tests/traces/perceptual_topology.trace 4096 \
				--algorithm $$algorithm --feedback 4 \
				> $$output_dir/algorithm-$$algorithm.tsv || exit 1; \
		done; \
		for feedback in 0 7; do \
			$(YM2151_ORACLE) $$mode tests/traces/perceptual_topology.trace 4096 \
				--algorithm 0 --feedback $$feedback \
				> $$output_dir/feedback-$$feedback.tsv || exit 1; \
		done; \
		$(YM2151_ORACLE) $$mode tests/traces/bisect_two_bom_fb7.trace 40960 \
			> $$output_dir/feedback-7-long.tsv || exit 1; \
		$(YM2151_ORACLE) $$mode tests/traces/bisect_two_bom_alg5_fb7.trace 40960 \
			> $$output_dir/feedback-7-long-algorithm-5.tsv || exit 1; \
	done
	python3 tools/compare_ym2151_realtime.py validate \
		--reference $(YM2151_PERCEPTUAL_DIR) \
		--output $(YM2151_PERCEPTUAL_REPORT)
	python3 tools/compare_ym2151_realtime.py compare \
		--reference $(YM2151_PERCEPTUAL_DIR) \
		--candidate $(YM2151_PERCEPTUAL_MODEL_DIR) \
		--output $(YM2151_PERCEPTUAL_MODEL_REPORT)
	@touch $@

$(M68K_BUILD)/%.o: src/m68k/%.s src/m68k/xbios.i src/m68k/protocol.i \
		$(YM2151_REFERENCE) $(PDX_ADPCM_REFERENCE) $(YM2151_HOST_TABLES) \
		$(DSP_STAGE2_IMAGE) $(VASM)
	@mkdir -p $(M68K_BUILD)
	$(VASM) $< -quiet -Felf -m68030 -Isrc/m68k -I$(GENERATED_BUILD) \
		-o $@ -L $(M68K_BUILD)/$*.lst

$(XEVIOUS_M68K_BUILD)/player.o: src/m68k/player.s src/m68k/xbios.i \
		src/m68k/protocol.i $(VASM)
	@mkdir -p $(XEVIOUS_M68K_BUILD)
	$(VASM) $< -quiet -Felf -m68030 -DPLAYER_DEFAULT_XEVIOUS \
		-Isrc/m68k -I$(GENERATED_BUILD) -o $@ \
		-L $(XEVIOUS_M68K_BUILD)/player.lst

$(RELEASE_DIR)/f030mxdrv.tos: $(M68K_OBJECTS) $(VLINK)
	@mkdir -p $(RELEASE_DIR)
	# no -tos-fastload: the loader must clear the TPA, since driver and
	# player state assumes zero-initialized BSS
	$(VLINK) $(M68K_OBJECTS) -b ataritos -s -e start -o $@

$(RELEASE_DIR)/f030mxdrv.ttp: $(RELEASE_DIR)/f030mxdrv.tos
	cp $< $@

$(RELEASE_DIR)/xevious.tos: $(XEVIOUS_M68K_OBJECTS) $(VLINK)
	@mkdir -p $(RELEASE_DIR)
	$(VLINK) $(XEVIOUS_M68K_OBJECTS) -b ataritos -s -e start -o $@

# Real-hardware bring-up build: the Xevious player with every XBIOS/DSP
# handshake traced to the console. Each step prints its label before the
# call and its result after, so a hang leaves a dangling label naming the
# call that never returned. Not built by `all`; see `make xevious-verbose`.
$(VERBOSE_M68K_BUILD)/%.o: src/m68k/%.s src/m68k/xbios.i src/m68k/verbose.i \
		src/m68k/protocol.i $(YM2151_REFERENCE) $(PDX_ADPCM_REFERENCE) \
		$(YM2151_HOST_TABLES) $(DSP_STAGE2_IMAGE) $(VASM)
	@mkdir -p $(VERBOSE_M68K_BUILD)
	$(VASM) $< -quiet -Felf -m68030 -DVERBOSE_BOOT -DPLAYER_DEFAULT_XEVIOUS \
		-Isrc/m68k -I$(GENERATED_BUILD) -o $@ \
		-L $(VERBOSE_M68K_BUILD)/$*.lst

$(RELEASE_DIR)/xevverb.tos: $(VERBOSE_M68K_OBJECTS) $(VLINK)
	@mkdir -p $(RELEASE_DIR)
	$(VLINK) $(VERBOSE_M68K_OBJECTS) -b ataritos -s -e start -o $@

xevious-verbose: $(RELEASE_DIR)/xevverb.tos
	@file $(RELEASE_DIR)/xevverb.tos

# Same verbose player, but reconnecting the codec at the pre-rework 49.17 kHz
# prescaler. Only useful for isolating whether prescaler 3 is what stops the
# SSI on real hardware; the rest of the kernel still assumes 24.585 kHz.
VERBOSE50_M68K_BUILD := build/m68k-xevious-verbose50
VERBOSE50_M68K_OBJECTS := $(patsubst src/m68k/%.s,$(VERBOSE50_M68K_BUILD)/%.o,$(M68K_SOURCES))

$(VERBOSE50_M68K_BUILD)/%.o: src/m68k/%.s src/m68k/xbios.i src/m68k/verbose.i \
		src/m68k/protocol.i $(YM2151_REFERENCE) $(PDX_ADPCM_REFERENCE) \
		$(YM2151_HOST_TABLES) $(DSP_STAGE2_IMAGE) $(VASM)
	@mkdir -p $(VERBOSE50_M68K_BUILD)
	$(VASM) $< -quiet -Felf -m68030 -DVERBOSE_BOOT -DPLAYER_DEFAULT_XEVIOUS \
		-DFORCE_CLK50K -Isrc/m68k -I$(GENERATED_BUILD) -o $@ \
		-L $(VERBOSE50_M68K_BUILD)/$*.lst

$(RELEASE_DIR)/xevv50.tos: $(VERBOSE50_M68K_OBJECTS) $(VLINK)
	@mkdir -p $(RELEASE_DIR)
	$(VLINK) $(VERBOSE50_M68K_OBJECTS) -b ataritos -s -e start -o $@

xevious-verbose50: $(RELEASE_DIR)/xevv50.tos
	@file $(RELEASE_DIR)/xevv50.tos

$(DSP_BUILD)/BUILD.BAT: tools/BUILD_DSP.BAT src/dsp/ym2151.asm \
		src/dsp/stage2_loader.asm src/dsp/protocol.inc $(YM2151_TABLES) \
		$(ENVELOPE_TABLES)
	@mkdir -p $(DSP_BUILD)
	cp tools/BUILD_DSP.BAT $(DSP_BUILD)/BUILD.BAT
	cp src/dsp/ym2151.asm src/dsp/protocol.inc $(DSP_BUILD)/
	cp src/dsp/stage2_loader.asm $(DSP_BUILD)/YMBOOT.ASM
	cp $(YM2151_TABLES) $(DSP_BUILD)/ymtables.inc
	cp $(ENVELOPE_TABLES) $(DSP_BUILD)/envtabs.inc
	cp $(DSP_TOOL_SOURCE)/ASM56000.EXE $(DSP_TOOL_SOURCE)/CLDLOD.EXE \
		$(DSP_TOOL_SOURCE)/DOS4GW.EXE $(DSP_TOOL_SOURCE)/ioequ.inc $(DSP_BUILD)/
	@touch $@

$(DSP_BUILD)/.assembled: $(DSP_BUILD)/BUILD.BAT
	@if [ -z "$(DOSBOX)" ]; then \
		echo "error: DSP build needs dosbox-staging or dosbox" >&2; \
		exit 1; \
	fi
	@rm -f $(DSP_BUILD)/YM2151.CLD $(DSP_BUILD)/YM2151.LOD $(DSP_BUILD)/YM2151.LST \
		$(DSP_BUILD)/YMBOOT.CLD $(DSP_BUILD)/YMBOOT.LOD $(DSP_BUILD)/YMBOOT.LST
	$(DOSBOX) $(DOSBOX_FLAGS) $(abspath $(DSP_BUILD)/BUILD.BAT)
	@test -s $(DSP_BUILD)/YM2151.LOD
	@test -s $(DSP_BUILD)/YMBOOT.LOD
	@touch $@

$(RELEASE_DIR)/ym2151.lod: $(DSP_BUILD)/.assembled
	@mkdir -p $(RELEASE_DIR)
	cp $(DSP_BUILD)/YM2151.LOD $@

$(DSP_STAGE2_IMAGE): tools/generate_dsp_stage2.py $(DSP_BUILD)/.assembled
	@mkdir -p $(GENERATED_BUILD)
	python3 tools/generate_dsp_stage2.py \
		--bootstrap $(DSP_BUILD)/YMBOOT.LOD \
		--program $(DSP_BUILD)/YM2151.LOD \
		--program-limit 0x1400 \
		--island 0x2000 0x2b00 \
		--island 0x2b20 0x3400 > $@

check: all reference
	@test -s $(RELEASE_DIR)/f030mxdrv.tos
	@test -s $(RELEASE_DIR)/f030mxdrv.ttp
	@test -s $(RELEASE_DIR)/xevious.tos
	@test -s $(RELEASE_DIR)/ym2151.lod
	@test -s $(DSP_STAGE2_IMAGE)
	@test -s $(YM2151_VECTORS)
	@test -s $(YM2151_PERCEPTUAL_REPORT)
	@test -s $(YM2151_PERCEPTUAL_MODEL_REPORT)
	@rg -q "^0 +Errors" $(DSP_BUILD)/YM2151.LST
	@rg -q "^0 +Warnings" $(DSP_BUILD)/YM2151.LST
	@rg -q "^0 +Errors" $(DSP_BUILD)/YMBOOT.LST
	@rg -q "^0 +Warnings" $(DSP_BUILD)/YMBOOT.LST
	@rg -q "^DSP_BOOT_WORDS equ " $(DSP_STAGE2_IMAGE)
	@rg -q "^DSP_STAGE2_PROGRAM_WORDS equ " $(DSP_STAGE2_IMAGE)
	@file $(RELEASE_DIR)/f030mxdrv.tos $(RELEASE_DIR)/ym2151.lod

# Replay every perceptual scenario through the protocol-v23 realtime stream
# in Hatari, reconstruct per-frame vectors from the block-boundary dumps, and
# feed them through the exact-to-perceptual comparator.
capture-realtime: check
	@if ! command -v hatari >/dev/null 2>&1; then \
		echo "error: capture-realtime target needs Hatari" >&2; \
		exit 1; \
	fi
	python3 tools/capture_ym2151_realtime.py --output build/capture/vectors
	$(MAKE) compare-realtime REALTIME_CANDIDATE_DIR=build/capture/vectors

compare-realtime: $(YM2151_PERCEPTUAL_STAMP)
	@if [ -z "$(REALTIME_CANDIDATE_DIR)" ]; then \
		echo "error: set REALTIME_CANDIDATE_DIR to a codec-vector capture directory" >&2; \
		exit 1; \
	fi
	python3 tools/compare_ym2151_realtime.py compare \
		--reference $(YM2151_PERCEPTUAL_DIR) \
		--candidate "$(REALTIME_CANDIDATE_DIR)" \
		--implementation-model $(YM2151_PERCEPTUAL_MODEL_DIR) \
		--output $(REFERENCE_BUILD)/ym2151-realtime-comparison.txt

smoke: check
	@if ! command -v hatari >/dev/null 2>&1; then \
		echo "error: smoke target needs Hatari" >&2; \
		exit 1; \
	fi
	@rm -f build/hatari-smoke.log build/hatari-smoke.trace
	@SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy hatari \
		--machine falcon --dsp emu \
		--tos third_party/f030dsp3d/tools/tos402.rom --patch-tos true \
		--fast-boot true --fast-forward true --sound off \
		--confirm-quit false --run-vbls 1700 \
		--log-file build/hatari-smoke.log \
		--trace-file build/hatari-smoke.trace \
		--trace gemdos,dsp_host_interface,xbios \
		$(RELEASE_DIR)/f030mxdrv.tos
	@rg -q "XBIOS 0x6E Dsp_ExecBoot" build/hatari-smoke.trace
	@rg -q "Direct Transfer 0x4d584c" build/hatari-smoke.trace
	@rg -q "Transfer 0x4c4f41" build/hatari-smoke.trace
	@rg -q "Transfer 0x4d5817" build/hatari-smoke.trace
	@rg -q "Transfer 0x01dc19" build/hatari-smoke.trace
	@rg -q "Transfer 0x524459" build/hatari-smoke.trace
	@rg -q "GEMDOS 0x42 Fseek\\(0, [0-9]+, 2\\)" build/hatari-smoke.trace
	@rg -q "GEMDOS 0x42 Fseek\\(0, [0-9]+, 0\\)" build/hatari-smoke.trace
	@rg -q "Transfer 0x000080" build/hatari-smoke.trace
	@rg -q "Transfer 0x01fc00" build/hatari-smoke.trace
	@rg -q "Direct Transfer 0x021b00" build/hatari-smoke.trace
	@rg -q "Direct Transfer 0x01ad0c" build/hatari-smoke.trace
	@rg -q "Direct Transfer 0x01ad18" build/hatari-smoke.trace
	@rg -q "Direct Transfer 0x050000" build/hatari-smoke.trace
	@phase=$$($(YM2151_ORACLE) --phase-hex); \
		rg -q "Transfer $$phase" build/hatari-smoke.trace
	@rg -q "Direct Transfer 0x070000" build/hatari-smoke.trace
	@rg -q "Transfer 0x0001ff" build/hatari-smoke.trace
	@rg -q "Transfer 0x000014" build/hatari-smoke.trace
	@rg -q "Transfer 0x0029e0" build/hatari-smoke.trace
	@rg -q "Transfer 0x006b40" build/hatari-smoke.trace
	@rg -q "Transfer 0xffe520" build/hatari-smoke.trace
	@rg -q "Transfer 0x000001" build/hatari-smoke.trace
	@rg -q "Transfer 0x000002" build/hatari-smoke.trace
	@rg -q "Transfer 0x0001aa" build/hatari-smoke.trace
	@rg -q "Direct Transfer 0x01c1c0" build/hatari-smoke.trace
	@rg -q "Direct Transfer 0x01c2c0" build/hatari-smoke.trace
	@rg -q "Direct Transfer 0x100000" build/hatari-smoke.trace
	@rg -q "Transfer 0x6c679b" build/hatari-smoke.trace
	@rg -q "Direct Transfer 0x01c0de" build/hatari-smoke.trace
	@rg -q "Direct Transfer 0x01c3c0" build/hatari-smoke.trace
	@rg -q "Direct Transfer 0x140000" build/hatari-smoke.trace
	@rg -q "Transfer 0x0f2666" build/hatari-smoke.trace
	@rg -q "Direct Transfer 0x01c3de" build/hatari-smoke.trace
	@rg -q "Direct Transfer 0x01c4c0" build/hatari-smoke.trace
	@rg -q "Direct Transfer 0x150000" build/hatari-smoke.trace
	@rg -q "Transfer 0x89eb00" build/hatari-smoke.trace
	@! rg -q "Modulo addressing result unpredictable|Illegal instruction" build/hatari-smoke.log
	@rg -q "Direct Transfer 0x01c4de" build/hatari-smoke.trace
	@rg -q "Direct Transfer 0x01c501" build/hatari-smoke.trace
	@rg -q "Direct Transfer 0x160001" build/hatari-smoke.trace
	@rg -q "Transfer 0x1e3626" build/hatari-smoke.trace
	@rg -q "Direct Transfer 0x01c502" build/hatari-smoke.trace
	@rg -q "Direct Transfer 0x160002" build/hatari-smoke.trace
	@rg -q "Transfer 0x50e718" build/hatari-smoke.trace
	@rg -q "Direct Transfer 0x01c503" build/hatari-smoke.trace
	@rg -q "Direct Transfer 0x160003" build/hatari-smoke.trace
	@rg -q "Transfer 0x184eaf" build/hatari-smoke.trace
	@rg -q "Direct Transfer 0x01c504" build/hatari-smoke.trace
	@rg -q "Direct Transfer 0x160004" build/hatari-smoke.trace
	@rg -q "Transfer 0x19054b" build/hatari-smoke.trace
	@rg -q "Direct Transfer 0x01c505" build/hatari-smoke.trace
	@rg -q "Direct Transfer 0x160005" build/hatari-smoke.trace
	@rg -q "Transfer 0xffc6a7" build/hatari-smoke.trace
	@rg -q "Direct Transfer 0x01c506" build/hatari-smoke.trace
	@rg -q "Direct Transfer 0x160006" build/hatari-smoke.trace
	@rg -q "Transfer 0x662549" build/hatari-smoke.trace
	@rg -q "Direct Transfer 0x01c5de" build/hatari-smoke.trace
	@rg -q "Direct Transfer 0x01c6c0" build/hatari-smoke.trace
	@rg -q "Direct Transfer 0x170000" build/hatari-smoke.trace
	@rg -q "Transfer 0x1ce7a1" build/hatari-smoke.trace
	@rg -q "Direct Transfer 0x01c6de" build/hatari-smoke.trace
	@rg -q "XBIOS 0x80 Locksnd" build/hatari-smoke.trace
	@rg -q "XBIOS 0x89 Dsptristate\\(0x1, 0x0\\)" build/hatari-smoke.trace
	@rg -q "XBIOS 0x8B Devconnect\\(1, 0x8, 0, 3, 1\\)" build/hatari-smoke.trace
	@rg -q "Direct Transfer 0x110000" build/hatari-smoke.trace
	@rg -q "Direct Transfer 0x120000" build/hatari-smoke.trace
	@rg -q "Transfer 0x0003c0" build/hatari-smoke.trace
	@rg -q "Direct Transfer 0x01cd09" build/hatari-smoke.trace
	@rg -q "Direct Transfer 0x01d009" build/hatari-smoke.trace
	@rg -q "Direct Transfer 0x01d10c" build/hatari-smoke.trace
	@rg -q "Direct Transfer 0x021a22" build/hatari-smoke.trace
	@rg -q "Direct Transfer 0x021a33" build/hatari-smoke.trace
	@rg -q "Direct Transfer 0x0b0000" build/hatari-smoke.trace
	@rg -q "Direct Transfer 0x0e0000" build/hatari-smoke.trace
	@rg -q "Direct Transfer 0x02284b" build/hatari-smoke.trace
	@rg -q "Direct Transfer 0x0e0040" build/hatari-smoke.trace
	@rg -q "Direct Transfer 0x02284c" build/hatari-smoke.trace
	@rg -q "Direct Transfer 0x027e5a" build/hatari-smoke.trace
	@rg -q "Direct Transfer 0x0f0000" build/hatari-smoke.trace
	@rg -q "Transfer 0x000500" build/hatari-smoke.trace
	@rg -q "Direct Transfer 0x0e0500" build/hatari-smoke.trace
	@rg -q "Direct Transfer 0x02284a" build/hatari-smoke.trace
	@rg -q "Direct Transfer 0x0e0540" build/hatari-smoke.trace
	@rg -q "Transfer 0x000a00" build/hatari-smoke.trace
	@rg -q "Direct Transfer 0x130000" build/hatari-smoke.trace
	@rg -q "Direct Transfer 0x0e0a00" build/hatari-smoke.trace
	@rg -q "Direct Transfer 0x0e0a40" build/hatari-smoke.trace
	@rg -q "Transfer 0x000f40" build/hatari-smoke.trace
	@rg -q "Transfer 0x000600" build/hatari-smoke.trace
	@rg -q "Transfer 0x98e818" build/hatari-smoke.trace
	@rg -q "Direct Transfer 0x01db10" build/hatari-smoke.trace
	@rg -q "Direct Transfer 0x0c0000" build/hatari-smoke.trace
	@rg -q "XBIOS 0x89 Dsptristate\\(0x0, 0x0\\)" build/hatari-smoke.trace
	@rg -q "XBIOS 0x81 Unlocksnd" build/hatari-smoke.trace
	@echo "Hatari MXDRV MDX/PDX + DSP YM2151 interrupt-buffered smoke test: OK"

# Exercise the dedicated player at the stock 16 MHz 68030 clock and prove from
# the SSI trace that every prepared 512-frame block replaces the active block
# at the next 20.83 ms stereo boundary without sustained output clipping. The
# 600-handoff floor runs past both former stalls and requires a >32-write burst
# to exercise the expanded stage.
stock-audio: xevious
	@python3 tools/stock_audio_timing.py

profile-dsp: check tools/profile_dsp.py
	@if ! command -v hatari >/dev/null 2>&1; then \
		echo "error: profile-dsp target needs Hatari" >&2; \
		exit 1; \
	fi
	@rm -rf $(DSP_PROFILE_DIR)
	@python3 tools/profile_dsp.py prepare \
		--listing $(DSP_BUILD)/YM2151.LST \
		--output-dir $(DSP_PROFILE_DIR) \
		--marker 0x01c1c0
	@SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy hatari \
		--machine falcon --dsp emu \
		--tos third_party/f030dsp3d/tools/tos402.rom --patch-tos true \
		--fast-boot true --fast-forward true --sound off \
		--confirm-quit false --run-vbls 1200 \
		--parse $(DSP_PROFILE_DIR)/start.ini \
		$(RELEASE_DIR)/f030mxdrv.tos \
		> $(DSP_PROFILE_DIR)/debug.log 2>&1 || { \
			tail -n 100 $(DSP_PROFILE_DIR)/debug.log >&2; \
			exit 1; \
		}
	@test -s $(DSP_PROFILE_DIR)/profile.txt || { \
		echo "error: Hatari did not capture the DSP render profile" >&2; \
		tail -n 100 $(DSP_PROFILE_DIR)/debug.log >&2; \
		exit 1; \
	}
	@python3 tools/profile_dsp.py report \
		--listing $(DSP_BUILD)/YM2151.LST \
		--profile $(DSP_PROFILE_DIR)/profile.txt \
		--output $(DSP_PROFILE_DIR)/report.txt

profile-dsp-rt: check tools/profile_dsp.py
	@if ! command -v hatari >/dev/null 2>&1; then \
		echo "error: profile-dsp-rt target needs Hatari" >&2; \
		exit 1; \
	fi
	@rm -rf $(DSP_RT_PROFILE_DIR)
	@python3 tools/profile_dsp.py prepare \
		--listing $(DSP_BUILD)/YM2151.LST \
		--output-dir $(DSP_RT_PROFILE_DIR) \
		--marker 0x01c2c0 \
		--start-symbol rt_profile_loop_start \
		--end-symbol rt_profile_loop_done
	@SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy hatari \
		--machine falcon --dsp emu \
		--tos third_party/f030dsp3d/tools/tos402.rom --patch-tos true \
		--fast-boot true --fast-forward true --sound off \
		--confirm-quit false --run-vbls 1200 \
		--parse $(DSP_RT_PROFILE_DIR)/start.ini \
		$(RELEASE_DIR)/f030mxdrv.tos \
		> $(DSP_RT_PROFILE_DIR)/debug.log 2>&1 || { \
			tail -n 100 $(DSP_RT_PROFILE_DIR)/debug.log >&2; \
			exit 1; \
		}
	@test -s $(DSP_RT_PROFILE_DIR)/profile.txt || { \
		echo "error: Hatari did not capture the codec-rate DSP profile" >&2; \
		tail -n 100 $(DSP_RT_PROFILE_DIR)/debug.log >&2; \
		exit 1; \
	}
	@python3 tools/profile_dsp.py report \
		--listing $(DSP_BUILD)/YM2151.LST \
		--profile $(DSP_RT_PROFILE_DIR)/profile.txt \
		--output $(DSP_RT_PROFILE_DIR)/report.txt \
		--samples $(DSP_RT_PROFILE_FRAMES) \
		--sample-rate 49169.921875 \
		--unit-label "codec frame" \
		--projection-factor 8 \
		--projection-label "linear eight-channel projection" \
		--title "DSP56001 codec-rate four-operator lower-bound profile"

profile-dsp-rt2: check tools/profile_dsp.py
	@if ! command -v hatari >/dev/null 2>&1; then \
		echo "error: profile-dsp-rt2 target needs Hatari" >&2; \
		exit 1; \
	fi
	@rm -rf $(DSP_RT2_PROFILE_DIR)
	@python3 tools/profile_dsp.py prepare \
		--listing $(DSP_BUILD)/YM2151.LST \
		--output-dir $(DSP_RT2_PROFILE_DIR) \
		--marker 0x01c3c0 \
		--start-symbol rt2_profile_loop_start \
		--end-symbol rt2_profile_loop_done
	@SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy hatari \
		--machine falcon --dsp emu \
		--tos third_party/f030dsp3d/tools/tos402.rom --patch-tos true \
		--fast-boot true --fast-forward true --sound off \
		--confirm-quit false --run-vbls 1200 \
		--parse $(DSP_RT2_PROFILE_DIR)/start.ini \
		$(RELEASE_DIR)/f030mxdrv.tos \
		> $(DSP_RT2_PROFILE_DIR)/debug.log 2>&1 || { \
			tail -n 100 $(DSP_RT2_PROFILE_DIR)/debug.log >&2; \
			exit 1; \
		}
	@test -s $(DSP_RT2_PROFILE_DIR)/profile.txt || { \
		echo "error: Hatari did not capture the block-spike DSP profile" >&2; \
		tail -n 100 $(DSP_RT2_PROFILE_DIR)/debug.log >&2; \
		exit 1; \
	}
	@python3 tools/profile_dsp.py report \
		--listing $(DSP_BUILD)/YM2151.LST \
		--profile $(DSP_RT2_PROFILE_DIR)/profile.txt \
		--output $(DSP_RT2_PROFILE_DIR)/report.txt \
		--samples $(DSP_RT2_PROFILE_FRAMES) \
		--sample-rate 49169.921875 \
		--unit-label "codec frame" \
		--projection-factor 8 \
		--projection-label "linear eight-channel projection" \
		--title "DSP56001 codec-rate algorithm-0 block-spike profile"

profile-dsp-rt3: check tools/profile_dsp.py
	@if ! command -v hatari >/dev/null 2>&1; then \
		echo "error: profile-dsp-rt3 target needs Hatari" >&2; \
		exit 1; \
	fi
	@rm -rf $(DSP_RT3_PROFILE_DIR)
	@python3 tools/profile_dsp.py prepare \
		--listing $(DSP_BUILD)/YM2151.LST \
		--output-dir $(DSP_RT3_PROFILE_DIR) \
		--marker 0x01c4c0 \
		--start-symbol rt3_profile_loop_start \
		--end-symbol rt3_profile_loop_done
	@SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy hatari \
		--machine falcon --dsp emu \
		--tos third_party/f030dsp3d/tools/tos402.rom --patch-tos true \
		--fast-boot true --fast-forward true --sound off \
		--confirm-quit false --run-vbls 1200 \
		--parse $(DSP_RT3_PROFILE_DIR)/start.ini \
		$(RELEASE_DIR)/f030mxdrv.tos \
		> $(DSP_RT3_PROFILE_DIR)/debug.log 2>&1 || { \
			tail -n 100 $(DSP_RT3_PROFILE_DIR)/debug.log >&2; \
			exit 1; \
		}
	@test -s $(DSP_RT3_PROFILE_DIR)/profile.txt || { \
		echo "error: Hatari did not capture the carrier block profile" >&2; \
		tail -n 100 $(DSP_RT3_PROFILE_DIR)/debug.log >&2; \
		exit 1; \
	}
	@python3 tools/profile_dsp.py report \
		--listing $(DSP_BUILD)/YM2151.LST \
		--profile $(DSP_RT3_PROFILE_DIR)/profile.txt \
		--output $(DSP_RT3_PROFILE_DIR)/report.txt \
		--samples $(DSP_RT3_PROFILE_FRAMES) \
		--sample-rate 49169.921875 \
		--unit-label "codec frame" \
		--projection-factor 8 \
		--projection-label "linear eight-channel projection" \
		--title "DSP56001 codec-rate algorithm-7 carrier block profile"

profile-dsp-rt4: $(DSP_RT4_PROFILE_TARGETS)

profile-dsp-rt4-alg%: check tools/profile_dsp.py
	@case "$*" in 1|2|3|4|5|6) ;; \
		*) echo "error: algorithm must be 1-6" >&2; exit 1 ;; \
	esac
	@if ! command -v hatari >/dev/null 2>&1; then \
		echo "error: profile-dsp-rt4-alg$* target needs Hatari" >&2; \
		exit 1; \
	fi
	@rm -rf $(DSP_RT4_PROFILE_DIR)/algorithm-$*
	@python3 tools/profile_dsp.py prepare \
		--listing $(DSP_BUILD)/YM2151.LST \
		--output-dir $(DSP_RT4_PROFILE_DIR)/algorithm-$* \
		--marker 0x01c50$* \
		--start-symbol rt4_algorithm$*_loop_start \
		--end-symbol rt4_profile_loop_done
	@SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy hatari \
		--machine falcon --dsp emu \
		--tos third_party/f030dsp3d/tools/tos402.rom --patch-tos true \
		--fast-boot true --fast-forward true --sound off \
		--confirm-quit false --run-vbls 1200 \
		--parse $(DSP_RT4_PROFILE_DIR)/algorithm-$*/start.ini \
		$(RELEASE_DIR)/f030mxdrv.tos \
		> $(DSP_RT4_PROFILE_DIR)/algorithm-$*/debug.log 2>&1 || { \
			tail -n 100 $(DSP_RT4_PROFILE_DIR)/algorithm-$*/debug.log >&2; \
			exit 1; \
		}
	@test -s $(DSP_RT4_PROFILE_DIR)/algorithm-$*/profile.txt || { \
		echo "error: Hatari did not capture algorithm-$* profile" >&2; \
		tail -n 100 $(DSP_RT4_PROFILE_DIR)/algorithm-$*/debug.log >&2; \
		exit 1; \
	}
	@python3 tools/profile_dsp.py report \
		--listing $(DSP_BUILD)/YM2151.LST \
		--profile $(DSP_RT4_PROFILE_DIR)/algorithm-$*/profile.txt \
		--output $(DSP_RT4_PROFILE_DIR)/algorithm-$*/report.txt \
		--samples $(DSP_RT4_PROFILE_FRAMES) \
		--sample-rate 49169.921875 \
		--unit-label "codec frame" \
		--projection-factor 8 \
		--projection-label "linear eight-channel projection" \
		--title "DSP56001 codec-rate algorithm-$* mixed-topology profile"

# Play a real corpus song end to end through the argument-less AUTOPLAY.INF
# path: two full loops, the automatic fade, and the clean shutdown, with the
# blocking refill as the only cadence. Proves sustained mixed FM/PDX
# scheduling under Hatari ahead of the real-hardware soak.
endurance: check
	@if ! command -v hatari >/dev/null 2>&1; then \
		echo "error: endurance target needs Hatari" >&2; \
		exit 1; \
	fi
	@rm -rf build/endurance build/hatari-endurance.trace build/hatari-endurance.log
	@mkdir -p build/endurance
	@cp $(RELEASE_DIR)/f030mxdrv.tos build/endurance/
	@cp $(RELEASE_DIR)/XEVIOUS.MDX $(RELEASE_DIR)/XEVIOUS.PDX build/endurance/
	@printf 'XEVIOUS.MDX\r\n' > build/endurance/AUTOPLAY.INF
	@SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy hatari \
		--machine falcon --dsp emu \
		--tos third_party/f030dsp3d/tools/tos402.rom --patch-tos true \
		--fast-boot true --fast-forward true --sound off \
		--confirm-quit false --run-vbls $(ENDURANCE_VBLS) \
		--log-file build/hatari-endurance.log \
		--trace-file build/hatari-endurance.trace \
		--trace gemdos,dsp_host_interface,xbios \
		build/endurance/f030mxdrv.tos
	@test $$(rg -c "Direct Transfer 0x190000" build/hatari-endurance.trace) -ge $(ENDURANCE_MIN_REFILLS)
	@rg -q "Dsp_Unlock" build/hatari-endurance.trace
	@if rg -q "DSP->Host.: Transfer 0xffffff" build/hatari-endurance.trace; then \
		echo "error: protocol error reply during playback" >&2; exit 1; \
	fi
	@echo "Hatari MDX/PDX endurance playback: OK"

ENDURANCE_VBLS := 9000
ENDURANCE_MIN_REFILLS := 200

# The same end-to-end gate over every corpus song in release/. The driver
# streams each Hatari trace through a FIFO and scores it in flight (refill
# volume, clean Dsp_Unlock shutdown, no protocol error replies), so no
# trace file lands on disk; failing songs keep a rolling trace tail in
# build/endurance-batch/.
endurance-batch: check
	@python3 tools/endurance_batch.py

profile-dsp-rt5: check tools/profile_dsp.py
	@if ! command -v hatari >/dev/null 2>&1; then \
		echo "error: profile-dsp-rt5 target needs Hatari" >&2; \
		exit 1; \
	fi
	@rm -rf $(DSP_RT5_PROFILE_DIR)
	@python3 tools/profile_dsp.py prepare \
		--listing $(DSP_BUILD)/YM2151.LST \
		--output-dir $(DSP_RT5_PROFILE_DIR) \
		--marker 0x01c6c0 \
		--start-symbol rt5_profile_loop_start \
		--end-symbol rt5_profile_loop_done
	@SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy hatari \
		--machine falcon --dsp emu \
		--tos third_party/f030dsp3d/tools/tos402.rom --patch-tos true \
		--fast-boot true --fast-forward true --sound off \
		--confirm-quit false --run-vbls 1200 \
		--parse $(DSP_RT5_PROFILE_DIR)/start.ini \
		$(RELEASE_DIR)/f030mxdrv.tos \
		> $(DSP_RT5_PROFILE_DIR)/debug.log 2>&1 || { \
			tail -n 100 $(DSP_RT5_PROFILE_DIR)/debug.log >&2; \
			exit 1; \
		}
	@test -s $(DSP_RT5_PROFILE_DIR)/profile.txt || { \
		echo "error: Hatari did not capture the integrated support profile" >&2; \
		tail -n 100 $(DSP_RT5_PROFILE_DIR)/debug.log >&2; \
		exit 1; \
	}
	@python3 tools/profile_dsp.py report \
		--listing $(DSP_BUILD)/YM2151.LST \
		--profile $(DSP_RT5_PROFILE_DIR)/profile.txt \
		--output $(DSP_RT5_PROFILE_DIR)/report.txt \
		--samples $(DSP_RT5_PROFILE_FRAMES) \
		--sample-rate 24584.9609375 \
		--unit-label "codec frame" \
		--title "DSP56001 live-SSI eight-channel decoded ALG/PAN/AM/PM/TL profile"

run: all
	@if ! command -v hatari >/dev/null 2>&1; then \
		echo "error: run target needs Hatari" >&2; \
		exit 1; \
	fi
	hatari --machine falcon --dsp emu --tos \
		third_party/f030dsp3d/tools/tos402.rom $(RELEASE_DIR)/f030mxdrv.tos

clean:
	rm -rf build release
