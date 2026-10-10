Public copy of MrScruff's firmware modifications for the Analog Rytm MKII, redistributed with permission. Released as-is, responses to issues should not be expected.

# rytm-mods

Firmware modifications for the Elektron Analog Rytm MKII, OS 1.73.

Every build starts from the pinned stock image and rebuilds from source. The
`.syx` is an artifact; the patch sources, the symbol map and the allocation
registry are the project.

Same conventions as `octatrack-mods`, same registry and verification discipline,
different device. Nothing is shared between the two trees.

## Layout

| path | what |
|---|---|
| `stock/` | checksum of the pinned stock firmware, which you supply. Never written to. |
| `re/` | cumulative reverse-engineering knowledge: `symbols.toml`, subsystem notes, Ghidra bootstrap |
| `mods/NNNN-slug/` | one modification: manifest, stub source, design rationale |
| `requirements.txt` | Python packages for the mod 0006 and 0013 calibration and measurement tools |
| `registry/` | `allocations.toml` - every claim on cave space and detour sites |
| `tools/` | build, layout validation, verification, symbol generation, cave scan; capture off the device (`mix_capture.py`); mod 0013 measurement (`voice_dac_*.py`) |
| `vendor/` | third-party code that is **executed** (elektron-firmware-tool), fetched by `make setup` |
| `docs/` | user manual, flashing, hazards, calibration |
| `build/` | artifacts, gitignored |

## Build

Prerequisites:

- Python 3.11 or newer (build and verify use only the standard library)
- `git`, `make` and a C compiler, for the vendored container tool
- `m68k-elf-binutils` (`brew install m68k-elf-binutils` on macOS)
- a Ghidra install, only for `make ghidra`

The stock firmware is not included. Download Analog Rytm MKII OS 1.73 from
Elektron's support site and place the `.syx` at
`stock/Analog-Rytm_MKII_OS1.73.syx`. The build refuses any file whose checksum
differs from `stock/SHA256SUMS`.

    make setup     # venv + Python deps, clone and build the vendor tool at its pinned commit
    make verify    # build + assert the result

Produces `build/Analog-Rytm_MKII_OS1.73_<tag>.syx`, the only delivery format this
device has - there is no CF-card `.bin` equivalent. The default build's tag is
`0000_0002_0003_0004_0006_0008_0009_0010_0012_0013_0014_0015`. See `docs/FLASHING.md` to install it.

Build a subset for hardware bisection:

    .venv/bin/python tools/build.py --mods 0000-shared 0002-euclid-accents

## The container

Unpacks and repacks with the vendored tool, all checksums verified, five sections:

| id | name | size | load base | we touch it |
|---|---|---|---|---|
| 5 | meta | 15 B raw | - | no |
| 2 | bootstrap | 42,302 | 0x07020000 | **no** - see `docs/HAZARDS.md` |
| 1 | FPGA | 149,516 | 0x00000000 | no |
| 3 | MAIN OS | 3,005,432 | 0x40000400 | yes, this is the whole project |
| 8 | ? | 159,948 | 0x00000000 | no |

MAIN OS is ColdFire big-endian, as on the Octatrack, but it is a C++ build with its
Itanium-ABI symbol names left in (`ParameterPageView::changeParameterLockValue`,
`AnalogRytm::logicalParamID_t`, `Kit::updateMirror`). Most of the map can be recovered
by demangling rather than by guessing.

Section 8 is new in 1.73, little-endian ARM Thumb rather than ColdFire, and carries
`{"version": "1.00E", "release": "0018"}`. 1.73's only listed improvement is
"[MKII] Added Outbox 8 configuration support", so it is almost certainly the Outbox 8's
own firmware riding along - inferred, not proven.

`make verify` asserts that sections 5, 2, 1 and 8 come back out of our rebuilt `.syx`
byte-identical to stock, so a mistake can only ever reach MAIN OS.

## Mods

The default build enables all of these. Retracted mods and one-off hardware
probes are not part of this package; the pool notes in `registry/allocations.toml`
still record what those probes established.

| id | title | status |
|---|---|---|
| 0000 | The shared runtime other mods call into | built |
| 0002 | Euclidean generator places accents instead of trigs | hardware-verified |
| 0003 | Per-track random velocity offset | built |
| 0004 | Two per-sound random modifiers on a second LFO page | built |
| 0006 | Scrolling compressor gain-reduction estimate | hardware-verified |
| 0008 | Filter frequency shown in Hz | hardware-verified |
| 0009 | Main output RMS indicator on the compressor VOL label | built |
| 0010 | NO + PLAY toggles between the edited kit and the saved one | hardware-verified |
| 0012 | SLICE LOOP in the track menu: sixteen trigs slicing a one-bar loop | hardware-verified |
| 0013 | Voices to MAIN through the DAC, with a per-sound filter | hardware-verified |
| 0014 | CTRL ALL: TRK + knob turns that parameter on every sound track | hardware-verified |
| 0015 | ENV RESET reaches AMP and AMP+FILT | hardware-verified |

Status ladder: `re-only` -> `built` -> `hardware-verified`, plus `retracted`.
Only `hardware-verified` counts.

## Adding a mod

1. Add any new addresses to `re/symbols.toml` with an honest `status`.
2. Claim cave space and detour sites in `registry/allocations.toml`, recording the
   stock bytes at each detour host in `expect`. A mod may hold several cave claims,
   each naming the `section` it holds (`.text` by default): the pools are separate
   regions of the image and can never merge, so anything larger than the biggest
   free run has to be split, and the split belongs in the registry rather than
   being implied by sizes.
3. Write `mods/NNNN-slug/{mod.toml,stub.s,design.md}`.
4. `make verify`, then flash that mod alone.

The `expect` bytes are the load-bearing guard: if an address is wrong or two mods
collide, the build aborts instead of quietly patching the wrong place.

Before the first mod ships, the cave pool has to be earned: `make cavescan` reports
the candidates, `registry/allocations.toml` explains why the current one was chosen,
and it stays `status = "candidate"` until it has been proven untouched at runtime on
hardware. octatrack-mods inherited a pool it had not checked and lost a round trip to
it.
