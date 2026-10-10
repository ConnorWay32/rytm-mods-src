# OS upgrade and recovery

Established 2026-09-16 from OS 1.73, by string extraction from the decompressed
sections. Offsets are into the decompressed section, not the `.syx`.

## Two independent upgrade paths

**In-OS, over USB.** MAIN OS around `0x240141`: `OsUpgradeMenuView`,
`OsUpgradeDelegate`, "OS UPGRADE", "Waiting for SysEx", "ERASING FLASH...",
"PREPARING...", "Missing data!", "Checksum error!", "Downgrade not possible",
"No power adapter", "UPGRADE OS NOW?", "CANCEL OS UPGRADE?". Completion strings sit
separately at `0x25c7d1`: "OS UPGRADE COMPLETE", "INVALID FILE", "OS UPGRADE FAILED",
"PLEASE REBOOT". Needs a MAIN OS that boots.

**Bootstrap, over DIN MIDI.** Section 2 at `0x9302`:

    STARTUP MENU
      ... TEST MODE
    2 ... EMPTY RESET
    3 ... FACTORY RESET
    4 ... OS UPGRADE
    5 ... EXIT

with "BOOTSTRAP UPGRADE", "DO NOT TURN OFF!", "UPGRADE FAILED", "CRC CHECK",
"VERSION CHECK", "LENGTH ERROR", "COMPLETE", "PLEASE RESTART ME" at `0x9208`, and the
factory key/encoder/pad test vocabulary either side of it. Matches the readme's
"hold [FUNC] at power-on, [TRIG 4]", which also says USB cannot be used for this -
consistent with a minimal loader that has no USB stack.

Measured, not inferred: none of `STARTUP`, `EMPTY RESET` or `PREPARING FLASH` occurs
anywhere in MAIN OS, and all of them occur in the bootstrap. The recovery menu is
therefore below MAIN OS.

Contrast with the Octatrack, where the whole startup menu (`1..TESTMODE` /
`2..EMPTY RESET` / `3..MIDI UPGRADE` / `4..SEND UPGRADE` / `5..EXIT`) is inside
MAIN OS at `0x0e16a6`, along with the CF-card route
(`/octatrack_factory_os.bin`, `0x0b7264`). Both documented OT recovery paths run out
of MAIN OS; the OT bootstrap has never been dumped. The Rytm's is in the `.syx`.

## Factory maintenance protocol

MAIN OS, `0x25b960` onward. A line-oriented command set, each command a `#`-prefixed
word, with `ELE3` and "READY FOR OS" alongside it:

    #HELLO -> "HOW DO YOU DO?"   #BREAK   #UPGRADE -> "READY FOR BOOTSTRAP"
    #FULL_UPGRADE   #ENTER_TEST_MODE   #EXIT_TEST_MODE
    #READ   #WRITE   #CONTROL   #ECHO   #STATUS
    #READ_TEMP   #READ_TEMP_RAW   #READ_ADC   #WRITE_ADC_REF   #READ_ADC_REF
    #DUMP_AUDIO   #RECEIVE_AUDIO   #PLAY_STEREO   #PLAY_START/#PLAY_STOP
    #RECORD_START/#RECORD_STOP   #PLAY_PATTERN/#STOP_PATTERN
    #WRITE_TESTED   #WRITE_UI_TESTED   #WRITE_AUDIO_TESTED   #WRITE_PAD_TESTED
    #READ_TESTED   #READ_UI_TEST_COMPLETED   #READ_UI_TESTED
    #READ_AUDIO_TESTED   #READ_PAD_TESTED
    #DUMP_CALIBRATION   #CHECK_CALIBRATION   #READ_CALIBRATION_STATUS
    #READ_SERIAL   #WRITE_SERIAL   #MRAM_DUMP   #MMCDUMP
    #MMC_GET_RECONFIGURED   #MMC_RECONFIGURE   #SAMPLE_UPLOAD   #VERIFY_SAMPLES
    #READ_SAMPLE_STATUS   #FORMAT_FS   #DUMP_PAD_CALIBRATION
    #REBOOT   #REBOOT_INTO_MAINTENANCE_MODE
    #LOAD_PAD_TEST   #START_UI_TEST   #ABORT_UI_TEST   #UI_TEST_POLL
    #TEST_STATUS   #RESET_ARM   #RESET_POLL   #SHOW_TEST_COMPLETE_SIGN

Error/refusal strings next to them: "ADDRESS ERROR", "SERIAL NUMBER ALREADY WRITTEN",
"WRITE PROTECTED", "UNIT NOT FULLY TESTED", "ALREADY RECONFIGURED",
"ALREADY FORMATTED", "NO REFERENCE", "Parameter read failed".

Unknown so far: the transport it listens on, whether it is reachable on a retail
unit or gated behind `#ENTER_TEST_MODE` plus a factory-test flag, and the argument
format beyond what the `%s %d`-style format strings imply. `#RESET_ARM` implies an
ARM part alongside the ColdFire, which is consistent with section 8 being ARM Thumb.

Worth pursuing: `#READ` would be a way to dump memory over MIDI from a running unit,
which is the cheapest route to anything this project cannot get from the `.syx`.
It runs in MAIN OS, so it is no use on a bricked device.
