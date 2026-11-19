# profiles/

Per-device state written by `scripts/android-tool.sh discover`:

- `device-profile.env` — what the scripts read back (serial, codename, lock state, slot, init_boot presence, stock build,
  STOCK_DIR / LAST_BACKUP as project-relative paths). `omarchy-install-slot-b.sh` takes the serial from here.
- `device-profile.md` — the same information for humans.

Both are gitignored: they hold the phone's serial and build, and they are regenerated in seconds. To keep a device's
profile for later, copy the pair into a subfolder, e.g. `profiles/PJZ110-7359ee91/`, before running `discover` on
another phone; subfolders are ignored too unless you force-add them.
