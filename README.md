# biovolumes

Turns LMO phytoplankton counting-unit abundances into a dataframe joined
against HELCOM's PEG_BVOL reference (geometry, volume, and carbon per
counting unit), so biovolume/carbon biomass can be calculated per LMO
occasion.

Written for Carolin, see `email_20260826.txt` for the original request.

## The problem this solves

An LMO occasion's counts are recorded against whichever PEG_BVOL edition was
current at the time.
Species get renamed and size classes get renumbered between editions (e.g.
*Lingulodinium polyedra* → *Lingulaulax polyedra*), so joining an older count
file straight onto the current PEG_BVOL reference on `(Species,
SizeClassNo)` silently drops every row whose identifier has since changed.

`PEG_BVOL2026.xlsx` ships a `Change log` sheet that records these
renames/renumberings in structured columns (`Invalid species name`, `Valid
species name`, `Invalid size class`, `Valid size class`) back to 2006 —
343 identifier-changing events out of ~10,200 change-log rows in total (most
of the rest are attribute-only edits — Division/Class/Order reclassification,
author, geometric shape, unit — that don't touch identity and don't need
replaying for a join; of the 343, 25 are distinct species renames, which
matches Carolin's own manual count of the change log exactly).

We call bringing an older file's identifiers up to date "**remapping**":
`biovolume_pipeline.R` walks the change log in date order and rewrites each
old species/size-class pair to whatever HELCOM calls it today, *before*
looking up the volume/carbon numbers — otherwise the lookup would silently
fail for anything renamed since the count was made.

Per Carolin, HELCOM's renames are backwards-compatible: once a species/size
class is split off into a new identifier, the old identifier is never reused
for anything else. That means it's always safe to replay the *entire* change
log against a count file, regardless of which PEG_BVOL edition it was
originally recorded against — if it already uses a current identifier,
nothing in the log will match it, so nothing changes. So, unlike an earlier
version of this script, there's no need to know or supply which edition an
LMO occasion was originally coded against.

## Prerequisites

- **R** (developed against 4.6.1 — any reasonably recent R should work) and,
  recommended, **RStudio**.
- Open `biovolumes.Rproj` in RStudio (double-click it, or File → Open
  Project) rather than opening `biovolume_pipeline.R` directly — this sets
  the working directory to the project folder automatically, which the
  script depends on for its relative paths like `data/PEG_BVOL2026.xlsx`. If
  you open the script on its own instead and see a "cannot open file" /
  "No such file or directory" error, that's the working directory not being
  set to this folder — run `setwd()` to it, or reopen via the `.Rproj`.
- Four packages, installed once per machine:

  ```r
  install.packages(c("readxl", "dplyr", "tidyr", "stringr"))
  ```

  The script also checks for these itself when run and will tell you exactly
  which are missing if any aren't installed yet.

## Usage

```r
source("biovolume_pipeline.R")
biovolume_file <- read_biovolume_file("data/PEG_BVOL2026.xlsx")
change_log <- read_change_log("data/PEG_BVOL2026.xlsx")

joined <- join_lmo_to_peg_bvol(
  lmo,   # data frame with Species, SizeClassNo, and abundance column(s)
  biovolume_file,
  change_log
)
```

`lmo`'s `Species`/`SizeClassNo` columns should be exactly what the lab
reported — if the file also has pre-computed Biovolume/Carbon-biomass
columns from the lab (like `LMO_378.xlsx` does), just don't select them into
`lmo`; they're not needed and shouldn't be compared against.

`joined` has one row per input row, with the current-edition geometry/volume/
carbon-per-counting-unit columns attached, plus a `needs_manual_review`
column: `TRUE` where nothing matched even after remapping (e.g. a name
PEG_BVOL never adopted) — inspect those rows by hand.

Deliberately out of scope: computing final biovolume/carbon biomass from
abundance. Per Carolin's email, once abundance is joined to the HELCOM
geometry/volume/carbon columns she'll do that calculation herself.

Running the script directly (`Rscript biovolume_pipeline.R`) exercises the
demo at the bottom against `data/LMO_378.xlsx` — see caveat below.

## Known limitations

- **Only structured changes are replayed.** A handful of historical fixes in
  the change log are recorded only as free-text `Comment` (e.g. a 2020
  "Lingulodinium polyedrum" → "Lingulodinium polyedra" spelling correction
  with no `Invalid/Valid species name` populated) and won't be caught.
- **Change-log ordering is Year-level only.** A few editions were released as
  sub-versions within the same calendar year (`PEG_BVOL2017_2`,
  `PEG_BVOL2016-4`, ...); changes within the same year are not ordered
  relative to each other. Hasn't caused a wrong result in testing so far.
- **Names HELCOM hasn't adopted aren't resolvable at all.** E.g.
  `data/LMO_378.xlsx` uses "Leubordinium glaucum", but PEG_BVOL2026 still
  calls it "Katodinium glaucum" — no amount of replaying HELCOM's own change
  log fixes a name PEG_BVOL never adopted in the first place. Confirmed by
  Carolin: these need a manual mapping, found case by case (e.g. via WORMS)
  as they come up — flagged in `joined` via `needs_manual_review = TRUE`,
  same as any other unresolved row.
- **A bare genus with no size class won't match**, e.g. `LMO_378.xlsx` has
  "Gymnodinium" rows with `SizeClassNo` blank (only distinguished by
  Trophy). Confirmed by Carolin: this happens because whatever reference the
  Polish lab used (possibly a PEG_BVOL subset) is missing the
  heterotrophic size classes for some genera — also a manual, case-by-case
  fix, also flagged via `needs_manual_review`.

## `data/LMO_378.xlsx` is genuine raw input

Confirmed by Carolin (2026-08-28): its `Species`/`SizeClassNo`/`Abundance`
columns are exactly what the Polish lab sends, before any HELCOM join. It
also carries Biovolume/Carbon-biomass columns the lab pre-computed against
an older PEG_BVOL edition — the demo (and any real usage) just omits those
on import; they're not compared against or otherwise used. Result as of
this commit: 33/35 distinct species+size-class rows resolve against
PEG_BVOL2026 after remapping (32/35 without it) — the 2 remaining failures
are the Katodinium/Leubordinium and bare-genus-Gymnodinium cases above.

## Open questions for Carolin

1. ~~A genuine raw (pre-join) LMO count file~~ — resolved: `LMO_378.xlsx`'s
   `Species`/`SizeClassNo`/`Abundance` columns are exactly that.
2. ~~Which PEG_BVOL edition was each LMO occasion originally coded
   against?~~ — resolved, and turns out not to matter: since HELCOM's
   renames are backwards-compatible, replaying the full change log is
   always safe regardless of the file's original vintage (see "The problem
   this solves" above). `from_year` has been removed from the script.
3. **Emil's old data file, once it arrives** — Carolin doesn't have his
   code, but does have a file with all LMO phytoplankton data adjusted to
   PEG_BVOL_2020, which she's attempting to send. Once here, worth checking
   whether it's useful as a second, independent validation set (e.g. do our
   remap results for the same occasions agree with what he produced
   manually) rather than as a source of additional changelog logic — the
   change log already goes back to 2006 in structured form.
4. Confirmed resolved, no open question remains: names PEG_BVOL hasn't
   adopted, and bare-genus rows with missing size classes, both get flagged
   for manual review rather than auto-resolved (see "Known limitations").
