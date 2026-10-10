# Analog Rytm MKII firmware mods.
PY := .venv/bin/python

.PHONY: all setup symbols layout build verify cavescan ghidra disasm clean \
	comp-selftest comp-cal-gen comp-cal-check comp-cal-build cave-selftest \
	build-selftest

all: verify

# The container tool, pinned to the commit the build was verified against.
EFT_URL := https://github.com/mischa85/elektron-firmware-tool
EFT_REV := a5bce9a6af644386d900924082993a805e812874

setup:
	python3 -m venv .venv
	.venv/bin/pip install -r requirements.txt
	test -d vendor/elektron-firmware-tool/.git || git clone $(EFT_URL) vendor/elektron-firmware-tool
	git -C vendor/elektron-firmware-tool checkout --quiet $(EFT_REV)
	$(MAKE) -C vendor/elektron-firmware-tool

symbols:
	$(PY) tools/symbols.py

layout:
	$(PY) tools/layout.py

# Mod 0006's calib.inc must be what its calibration.toml gives before anything
# is assembled from it.
build: symbols layout
	$(PY) tools/comp/calib_tables.py --check
	$(PY) tools/build.py

verify: build
	$(PY) tools/verify.py $(if $(TAG),--tag $(TAG),)

# Candidate code caves in the stock image. The cave pool in
# registry/allocations.toml comes from this scan, not from anyone else's survey.
cavescan: build
	$(PY) tools/cavescan.py

ghidra:
	./re/ghidra/import.sh

# Whole-image disassembly with ColdFire EMAC decoding. objdump takes the ISA
# from the ELF header, so a raw binary is read as plain m68k and every EMAC
# opcode - mac, msac and the movclr that reads an accumulator and clears it -
# comes out as ".short". The .archtag section holds one EMAC instruction purely
# so the assembler stamps the ISA; .text carries the image at its own addresses.
MAINOS_BASE := 0x40000400
disasm: build
	printf '\t.section .archtag,"a"\n\tmovclr.l %%acc0,%%d0\n\t.text\n\t.incbin "build/stock_mainos.bin"\n' \
		> build/mainos_wrap.s
	m68k-elf-as -mcpu=5475 build/mainos_wrap.s -o build/mainos_wrap.o
	m68k-elf-objdump -d -j .text --adjust-vma=$(MAINOS_BASE) build/mainos_wrap.o \
		| sed 's/^ *//' > build/mainos_emac.dis

# Regression tests for the cave analysis. Needs `make build` for the image and
# `make disasm` for the dead-code pass; the tests that need either skip without it.
cave-selftest:
	$(PY) tools/test_cavescan.py

# The build's check on `|` used as an operator, which this assembler reads as a
# comment.
build-selftest:
	$(PY) tools/test_build_lint.py

# The build's check on `|` used as an operator, which this assembler reads as a
# comment.
build-selftest:
	$(PY) tools/test_build_lint.py

# Mod 0006's calibration (re/subsystems/compressor-calibration.md). Every
# calibrated value lives in mods/0006-comp-preview/calibration.toml; the fits
# run from tools/comp/calibrate.py on a calibration's recordings.
# comp-selftest: host checks of the calibration frames' decoding, and of a
# run's preflight, verification and report on synthetic captures.
# comp-cal-gen: write calib.inc from calibration.toml.
# comp-cal-check: calib.inc is current.
comp-selftest:
	$(PY) tools/comp/calframes_selftest.py
	$(PY) tools/comp/verify_selftest.py > /dev/null && echo "verify: PASS"
	$(PY) tools/comp/preflight_selftest.py

comp-cal-gen:
	$(PY) tools/comp/calib_tables.py

comp-cal-check:
	$(PY) tools/comp/calib_tables.py --check

# The calibration image: 0006 alone, cal = 1. Flash
# build/Analog-Rytm_MKII_OS1.73_cal.syx, then calibrate.py.
comp-cal-build: symbols layout
	$(PY) tools/comp/calib_tables.py --check
	$(PY) tools/build.py --tag cal --mods 0006-comp-preview --param 0006-comp-preview:cal=1
	$(PY) tools/verify.py --tag cal

# Everything under build/ is regenerated from the image except build/comp, a
# calibration's recordings off the hardware, and build/comp_rig.json, the rig's
# ports and the calibration project's roles.
clean:
	find build -mindepth 1 -maxdepth 1 ! -name comp ! -name comp_rig.json -exec rm -rf {} +
