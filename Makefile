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
DSP_BUILD := build/dsp
NATIVE_BUILD := build/native
GENERATED_BUILD := build/generated
REFERENCE_BUILD := build/reference
RELEASE_DIR := release

YM2151_ORACLE := $(NATIVE_BUILD)/ym2151_oracle
YM2151_TABLES := $(GENERATED_BUILD)/ym2151_tables.inc
YM2151_REFERENCE := $(GENERATED_BUILD)/ym2151_reference.i
YM2151_VECTORS := $(REFERENCE_BUILD)/attack_all_carriers.tsv

M68K_SOURCES := \
	src/m68k/main.s \
	src/m68k/dsp_link.s \
	src/m68k/mxdrv_core.s \
	src/m68k/mxdrv_port.s
M68K_OBJECTS := $(patsubst src/m68k/%.s,$(M68K_BUILD)/%.o,$(M68K_SOURCES))

DOSBOX ?= $(shell command -v dosbox-staging 2>/dev/null || command -v dosbox 2>/dev/null)
DOSBOX_FLAGS ?= --noprimaryconf --set output=texture

.PHONY: all host dsp reference check smoke clean run tools

all: host dsp

host: $(RELEASE_DIR)/f030mxdrv.tos

dsp: $(RELEASE_DIR)/ym2151.lod

reference: $(YM2151_REFERENCE) $(YM2151_TABLES) $(YM2151_VECTORS)

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

$(YM2151_REFERENCE): $(YM2151_ORACLE) tests/traces/attack_all_carriers.trace
	@mkdir -p $(GENERATED_BUILD)
	$(YM2151_ORACLE) --emit-m68k tests/traces/attack_all_carriers.trace > $@

$(YM2151_TABLES): tools/generate_ym2151_tables.py $(YMFM_SOURCE)/ymfm_fm.ipp
	@mkdir -p $(GENERATED_BUILD)
	python3 tools/generate_ym2151_tables.py $(YMFM_SOURCE)/ymfm_fm.ipp > $@

$(YM2151_VECTORS): $(YM2151_ORACLE) tests/traces/attack_all_carriers.trace
	@mkdir -p $(REFERENCE_BUILD)
	$(YM2151_ORACLE) --vectors tests/traces/attack_all_carriers.trace 256 > $@

$(M68K_BUILD)/%.o: src/m68k/%.s src/m68k/xbios.i src/m68k/protocol.i \
		$(YM2151_REFERENCE) $(VASM)
	@mkdir -p $(M68K_BUILD)
	$(VASM) $< -quiet -Felf -m68030 -Isrc/m68k -I$(GENERATED_BUILD) \
		-o $@ -L $(M68K_BUILD)/$*.lst

$(RELEASE_DIR)/f030mxdrv.tos: $(M68K_OBJECTS) $(VLINK)
	@mkdir -p $(RELEASE_DIR)
	$(VLINK) $(M68K_OBJECTS) -tos-fastload -b ataritos -s -e start -o $@

$(DSP_BUILD)/BUILD.BAT: tools/BUILD_DSP.BAT src/dsp/ym2151.asm \
		src/dsp/protocol.inc $(YM2151_TABLES)
	@mkdir -p $(DSP_BUILD)
	cp tools/BUILD_DSP.BAT $(DSP_BUILD)/BUILD.BAT
	cp src/dsp/ym2151.asm src/dsp/protocol.inc $(DSP_BUILD)/
	cp $(YM2151_TABLES) $(DSP_BUILD)/ymtables.inc
	cp $(DSP_TOOL_SOURCE)/ASM56000.EXE $(DSP_TOOL_SOURCE)/CLDLOD.EXE \
		$(DSP_TOOL_SOURCE)/DOS4GW.EXE $(DSP_TOOL_SOURCE)/ioequ.inc $(DSP_BUILD)/
	@touch $@

$(RELEASE_DIR)/ym2151.lod: $(DSP_BUILD)/BUILD.BAT
	@if [ -z "$(DOSBOX)" ]; then \
		echo "error: DSP build needs dosbox-staging or dosbox" >&2; \
		exit 1; \
	fi
	@rm -f $(DSP_BUILD)/YM2151.CLD $(DSP_BUILD)/YM2151.LOD $(DSP_BUILD)/YM2151.LST
	$(DOSBOX) $(DOSBOX_FLAGS) $(abspath $(DSP_BUILD)/BUILD.BAT)
	@test -s $(DSP_BUILD)/YM2151.LOD
	@mkdir -p $(RELEASE_DIR)
	cp $(DSP_BUILD)/YM2151.LOD $@

check: all reference
	@test -s $(RELEASE_DIR)/f030mxdrv.tos
	@test -s $(RELEASE_DIR)/ym2151.lod
	@test -s $(YM2151_VECTORS)
	@rg -q "^0 +Errors" $(DSP_BUILD)/YM2151.LST
	@rg -q "^0 +Warnings" $(DSP_BUILD)/YM2151.LST
	@file $(RELEASE_DIR)/f030mxdrv.tos $(RELEASE_DIR)/ym2151.lod

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
		--confirm-quit false --run-vbls 800 \
		--log-file build/hatari-smoke.log \
		--trace-file build/hatari-smoke.trace \
		--trace gemdos,dsp_host_interface,xbios \
		$(RELEASE_DIR)/f030mxdrv.tos
	@rg -q "Transfer 0x4d5803" build/hatari-smoke.trace
	@rg -q "Direct Transfer 0x021b00" build/hatari-smoke.trace
	@rg -q "Direct Transfer 0x050000" build/hatari-smoke.trace
	@phase=$$($(YM2151_ORACLE) --phase-hex); \
		rg -q "Transfer $$phase" build/hatari-smoke.trace
	@rg -q "Direct Transfer 0x070000" build/hatari-smoke.trace
	@rg -q "Transfer 0x0001ff" build/hatari-smoke.trace
	@rg -q "Transfer 0x000014" build/hatari-smoke.trace
	@rg -q "Transfer 0x0029e0" build/hatari-smoke.trace
	@rg -q "Transfer 0x006b40" build/hatari-smoke.trace
	@rg -q "Transfer 0xffe520" build/hatari-smoke.trace
	@rg -q "Direct Transfer 0x01c0de" build/hatari-smoke.trace
	@echo "Hatari MXDRV/DSP ymfm sample-oracle smoke test: OK"

run: all
	@if ! command -v hatari >/dev/null 2>&1; then \
		echo "error: run target needs Hatari" >&2; \
		exit 1; \
	fi
	hatari --machine falcon --dsp emu --tos \
		third_party/f030dsp3d/tools/tos402.rom $(RELEASE_DIR)/f030mxdrv.tos

clean:
	rm -rf build release
