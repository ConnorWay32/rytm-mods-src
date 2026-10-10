# Flashing

The Rytm MKII has one delivery format, a `.syx`. There is no card slot and no
`.bin` equivalent of the Octatrack's CF-card path.

## Normal route (Elektron Transfer, USB)

1. Connect over USB, power on.
2. Transfer > CONNECTION: set MIDI IN and OUT to the device.
3. Transfer > DROP: drag `build/Analog-Rytm_MKII_OS1.73_<tag>.syx` on.
4. Press `[YES]` on the device to confirm.

The unit restarts by itself. This path runs inside MAIN OS
(`OsUpgradeMenuView`), so it needs a MAIN OS that still boots.

## Recovery route (STARTUP menu, DIN MIDI only)

1. Hold `[FUNC]` while powering on.
2. `[TRIG 4]` enters OS UPGRADE.
3. Transfer > CONNECTION: "LEGACY OS UPGRADE mode", select the `.syx`, UPGRADE.

This one is served by the bootstrap, not by MAIN OS - the menu text lives in
section 2, at `0x9302` in the decompressed bootstrap:

    STARTUP MENU
      ... TEST MODE
    2 ... EMPTY RESET
    3 ... FACTORY RESET
    4 ... OS UPGRADE
    5 ... EXIT

so it should still come up after a MAIN OS that does not boot. USB is not available
here; it needs the DIN MIDI port.

## After flashing

Elektron's readme: "After some upgrades the bootstrap is also upgraded. This upgrade
is performed right after the first restart of the device. Do not turn the power off
during the upgrade." The bootstrap carries its own `BOOTSTRAP UPGRADE` /
`DO NOT TURN OFF!` screen. See `docs/HAZARDS.md`.

## Downgrades

Not supported by the device. MAIN OS carries "Downgrade not possible" and the
bootstrap carries a VERSION CHECK. Assume you cannot go back, and that this is why
the project pins the newest OS rather than an older one.
