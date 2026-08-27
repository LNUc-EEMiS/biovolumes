# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project status

This directory currently contains no code — only source data and a task description (`email_20260826.txt`).
No pipeline, script, or analysis code has been written yet.
There is no README, no CLAUDE.md predecessor, no build system, no tests, and nothing to lint or run.
When code is eventually added here (likely R, per the task description), update this file with the actual
build/lint/test commands at that point.

## The task (from `email_20260826.txt`)

Carolin runs LMO (long-term monitoring) phytoplankton counts.
A Polish lab sends back raw microscopy counts per LMO occasion (see `LMO_378.xlsx` for the shape of that output:
one row per division/species/size-class, with abundance, biovolume, and carbon-biomass columns already calculated
for that occasion).

The goal is a pipeline/dataframe that joins an LMO abundance file against the HELCOM `PEG_BVOL` reference file
(`PEG_BVOL2026.xlsx`) to look up each species/size-class's geometry, volume, and carbon-content values, so
biomass (volume and carbon) can be (re)calculated consistently.

The complication: HELCOM's `PEG_BVOL` reference file is revised yearly, and species/size-class identifiers drift
over time (renames, size-class splits/merges, taxonomy updates) — e.g. *Lingulodinium polyedra* was renamed to
*Lingulaulax polyedra*.
Older LMO files were coded against older `PEG_BVOL` versions, so a naive join on species name + size class breaks
silently whenever a name changed between the LMO file's vintage and the reference file's vintage.

The intended approach (following what a prior analyst, Emil, did manually through 2021): before joining an LMO
file to the current `PEG_BVOL` reference, first replay the relevant changelog entries against the LMO file so its
species names/size-classes are updated to current nomenclature — *then* join.
Emil's own change-log file/code from 2021 may exist somewhere (Carolin mentioned possibly having it in her email
archive) and, if located, would cover changes only from 2021 onward would need to be handled (~3590 entries),
rather than the full history back to 2015 (~9075 entries) — not all of which are relevant (some entries only
concern authorship, not species/size-class identity).

## Data files

- **`PEG_BVOL2026.xlsx`** — the HELCOM PEG_BVOL 2026 reference file (from
  `https://www.ices.dk/data/Documents/ENV/PEG_BVOL.zip`, updated yearly by HELCOM EG PHYTO). Sheets:
  - `Biovolume file` — one row per accepted species × size-class, with taxonomy (Division/Class/Order/Genus/Species),
    `Trophy`, `Geometric_shape`, `FORMULA`, `SizeClassNo`, dimensions (`Length(l1)µm`, `Width(w)µm`,
    `Diameter(d1)µm`, etc.), `Calculated_volume_µm3/counting_unit`, and `Calculated_Carbon_pg/counting_unit`. This
    is the lookup table the email requests columns from. Several columns are explicitly marked
    "NOT IMPORTED, NOT handled by ICES" and should generally be ignored for calculations.
  - `Change log` — the changelog referenced in the task: one row per historical change (name/size-class
    renames, additions, corrections), with `Invalid species name`/`Valid species name`,
    `Invalid size class`/`Valid size class`, `Version` (e.g. `PEG_BVOL2026`), and `Year`. This is the source
    for building the rename/remap step described above.
  - `Not_accepted` — species/size-class rows that are no longer accepted names, in the same column layout as
    `Biovolume file`.
  - `Explanations` — free-text documentation of the file's fields and conventions, worth reading before writing
    any parsing/join logic against this file.
- **`LMO_378.xlsx`** — an example raw output file from the Polish lab for one LMO occasion (occasion/station
  "378"), showing the abundance-side data that needs to be joined against `PEG_BVOL2026.xlsx`: one row per
  division/species/geometric shape/size-class, with `Abundance [unit number/l]`, `Biovolume[µg/l]`, and
  `Carbon biomass [µgC/l]` already computed for that occasion using an (unstated) prior version of the
  `PEG_BVOL` reference.

## Environment

`.screenrc` defines a `screen` session named `biovolumes` with windows for `rstudio`, `man`, `root`, and `claude`
— R (via RStudio) is the expected tool for the eventual analysis, consistent with the email's mention of R's
dataframe-join functions.
