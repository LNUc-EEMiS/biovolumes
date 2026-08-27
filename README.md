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
replaying for a join).
`biovolume_pipeline.R` replays that log forward from a given starting
edition to bring an older file's identifiers up to date before joining.

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
  lmo,                # data frame with Species, SizeClassNo, and abundance column(s)
  from_year = 2015,   # PEG_BVOL edition year this occasion was originally coded against
  biovolume_file,
  change_log
)
```

`joined` has one row per input row, with the current-edition geometry/volume/
carbon-per-counting-unit columns attached. Rows where `Genus` is `NA` didn't
match even after remapping — inspect those manually.

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
  log fixes a name PEG_BVOL never adopted in the first place. These need a
  manual mapping.

## `data/LMO_378.xlsx` is a demo fixture, not real input

It's Carolin's example of the *target output shape*, but per her the
reference numbers in it (volume/carbon/biovolume/biomass) are outdated — it
already has those columns computed against some old PEG_BVOL edition. The
demo strips them back out and uses only its `Species`/`SizeClassNo`/
`Abundance` columns as a stand-in raw input, to exercise the remap+join
logic end to end; it is not a validated real run. Result as of this commit:
33/35 distinct species+size-class rows resolve against PEG_BVOL2026 after
remapping (32/35 without it) — the 2 remaining failures are the
Katodinium/Leubordinium case above and a bare-genus "Gymnodinium" row with no
`SizeClassNo` in the source file.

## Open questions for Carolin

1. **A genuine raw (pre-join) LMO count file.** `LMO_378.xlsx` already has
   HELCOM's geometry/volume/carbon columns filled in — we need an example of
   what the Polish lab actually sends before any HELCOM join, to build and
   validate against real input.
2. **Which PEG_BVOL edition was each LMO occasion originally coded against?**
   `from_year` above needs this per occasion (or per year of sampling) to
   know how far back to replay the change log.
3. **Emil's old change log/code, if findable** — though PEG_BVOL2026.xlsx's
   own `Change log` sheet already goes back to 2006 in structured form, so it
   may cover everything needed without it. Worth confirming whether Emil's
   file is the same thing or contains anything beyond what's already here.
4. **How to handle names PEG_BVOL hasn't adopted**, like Leubordinium above —
   is there a list of these already, or do they need to be found and mapped
   case by case as they come up?
