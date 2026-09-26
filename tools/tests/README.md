# Isolated note compatibility regression

`note-compat.lua` is an automated test, not a playable mod. Do not install it into the normal release's mods folder. Run it in a separate copy of the executable with its own mods directory, using `--lua-song=tutorial`.

The test mod ID is `psych-lua-test` (use the example mod's metadata). Place the test under its `scripts/` folder. It uses the supplied RoaringBoy mod's `custom_notetypes/RoaringNote.lua`, corrected `custom_notetypes/ItemNotePixel.lua`, `sounds/heal.ogg`, and four pixel PNGs under `images/pixelUI/`: itemnote, itemnoteENDS, RoaringNote, and RoaringNoteENDS. Third-party assets are not bundled with this regression script.

The test creates a `note-check-passed.txt` marker only after checking raw-chart property writes, real pixel head dimensions, continuous-hold texture conversion, ignored misses/hold drops, hurt-note behavior with zero and nonzero miss damage, botplay ignoring optional notes, missing-splash fallback, and recycling back to native graphics/flags. Check stdout/stderr for Lua callback errors as well. It does not establish compatibility for the rest of the mod or every Psych texture format.
