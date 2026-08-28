# HELCOM PEG_BVOL name/size-class remap + lookup for LMO phytoplankton counts
#
# Context: LMO occasions are counted against whichever PEG_BVOL edition was
# current at the time. Species get renamed and size classes get renumbered
# between editions, so a straight join of an LMO count file against the
# current PEG_BVOL reference on (Species, SizeClassNo) silently drops rows
# whose identifiers have since changed (e.g. Lingulodinium polyedra ->
# Lingulaulax polyedra). PEG_BVOL2026.xlsx ships a "Change log" sheet that
# records these renames/renumberings in structured columns back to 2006; this
# script replays ("remaps") that log to bring an older count file's
# identifiers forward to the current edition before joining.
#
# Per Carolin (email 2026-08-28), HELCOM's renames are backwards-compatible:
# when a species/size-class is split off into a new identifier, the old
# identifier is never reused for anything else. That means replaying the
# *entire* change log against any LMO file is always safe, regardless of
# which PEG_BVOL edition it was originally coded against -- if the file
# already uses the current identifier, no change-log row's "invalid" name
# will match it, so nothing changes. This is why there's no `from_year`
# parameter here: the whole log is always applied.
#
# data/LMO_378.xlsx is confirmed (Carolin, 2026-08-28) to be genuine raw
# output from the Polish lab: its Species/SizeClassNo/Abundance columns are
# real counts, not a demo. It also carries Biovolume/Carbon-biomass columns
# the lab pre-computed against an older PEG_BVOL edition -- those are simply
# omitted on import (see the demo below), not something to validate against.
#
# Deliberately out of scope here: computing final biovolume/carbon biomass
# from abundance. Per Carolin's email, once she has abundance joined to the
# HELCOM geometry/volume/carbon-per-counting-unit columns she'll do that
# calculation herself -- this script stops at producing that joined table.

# Requires the readxl/dplyr/tidyr/stringr packages -- see README.md
# "Prerequisites" for the one-line install command.
required_packages <- c("readxl", "dplyr", "tidyr", "stringr")
missing_packages <- setdiff(required_packages, rownames(installed.packages()))
if (length(missing_packages) > 0) {
  stop(
    "Missing required package(s): ", paste(missing_packages, collapse = ", "),
    "\nInstall with: install.packages(c(",
    paste(sprintf('"%s"', missing_packages), collapse = ", "), "))"
  )
}

library(readxl)
library(dplyr)
library(tidyr)
library(stringr)

peg_bvol_path <- "data/PEG_BVOL2026.xlsx"

# ---- 1. Reference data ------------------------------------------------

#' The current, accepted species/size-class reference table: one row per
#' Species x SizeClassNo, with the geometry/volume/carbon columns Carolin's
#' email asks for.
read_biovolume_file <- function(path) {
  read_excel(path, sheet = "Biovolume file") %>%
    transmute(
      Division, Class, Order, Genus, Species, Trophy,
      Geometric_Shape = Geometric_shape,
      FORMULA,
      SizeClassNo = as.numeric(SizeClassNo),
      Unit,
      `Length(l1)µm`, `Length(l2)µm`, `Width(w)µm`, `Height(h)µm`,
      `Diameter(d1)µm`, `Diameter(d2)µm`,
      `No_of_cells/counting_unit`,
      `Calculated_volume_µm3/counting_unit`,
      `Filament_length_of_cell(µm)`,
      `Calculated_Carbon_pg/counting_unit`
    ) %>%
    filter(!is.na(Species), !is.na(SizeClassNo))
}

#' The Change log sheet, cleaned down to the columns that matter for
#' remapping identifiers, one row per historical change event.
#'
#' Only rows where `invalid_species` and/or `invalid_sizeclass` are populated
#' represent an identifier change we can replay automatically -- additions
#' (new species/taxa) and attribute-only edits (Division/Class/Order/Author/
#' Geometric_shape/Unit/... corrections that don't touch identity) are
#' dropped here since they don't affect a (Species, SizeClassNo) join key.
#' NOTE: this only catches changes recorded in these structured columns --
#' a handful of historical fixes are logged only as free-text `Comment`
#' (e.g. a 2020 "Lingulodinium polyedrum" -> "Lingulodinium polyedra"
#' spelling correction) and will NOT be picked up. See README.
read_change_log <- function(path) {
  read_excel(path, sheet = "Change log") %>%
    transmute(
      # The row's own current-at-the-time species name. For a species-rename
      # row this is the NEW name; for a size-class-only row (invalid_species
      # NA) it's the species the size class belongs to -- required to scope
      # size-class renumbering to the right species, since size class numbers
      # collide across species.
      context_species = Species,
      invalid_species = `Invalid species name`,
      valid_species = `Valid species name`,
      invalid_sizeclass = as.numeric(`Invalid size class`),
      valid_sizeclass = as.numeric(`Valid size class`),
      Version = str_trim(Version),
      Year = as.numeric(Year)
    ) %>%
    filter(!is.na(Year), Version != "Information") %>%
    filter(!is.na(invalid_species) | !is.na(invalid_sizeclass)) %>%
    distinct() %>%
    arrange(Year)
}

# ---- 2. Remap engine ---------------------------------------------------

#' Replay the *entire* change log against one (species, size class) pair,
#' walking forward in chronological (Year) order, until nothing more
#' applies. Safe to run regardless of which PEG_BVOL edition the pair
#' originated from -- see the backward-compatibility note at the top of this
#' file. Guards against runaway loops (there shouldn't be any, but a cycle
#' would otherwise hang silently).
remap_one <- function(species, sizeclass, change_log) {
  cur_species <- species
  cur_sizeclass <- sizeclass
  n_steps <- 0

  repeat {
    hit <- change_log %>%
      filter(
        (!is.na(invalid_species) & invalid_species == cur_species &
           (is.na(invalid_sizeclass) | invalid_sizeclass == cur_sizeclass)) |
        (is.na(invalid_species) & context_species == cur_species &
           !is.na(invalid_sizeclass) & invalid_sizeclass == cur_sizeclass)
      ) %>%
      slice(1)

    if (nrow(hit) == 0) break
    if (n_steps > 50) {
      warning("remap did not converge for ", species, " / ", sizeclass)
      break
    }

    if (!is.na(hit$valid_species)) cur_species <- hit$valid_species
    if (!is.na(hit$valid_sizeclass)) cur_sizeclass <- hit$valid_sizeclass
    n_steps <- n_steps + 1
  }

  tibble(
    Species_remapped = cur_species,
    SizeClassNo_remapped = cur_sizeclass,
    n_remap_steps = n_steps
  )
}

#' Vectorised/memoised remap over a whole count file: distinct (species,
#' sizeclass) pairs are remapped once and joined back, since a typical LMO
#' file has many rows sharing the same identifier.
remap_species_sizeclass <- function(species, sizeclass, change_log) {
  keys <- tibble(species, sizeclass) %>%
    mutate(.row = row_number())

  distinct_keys <- keys %>% distinct(species, sizeclass)

  remapped <- distinct_keys %>%
    rowwise() %>%
    mutate(remap_one(species, sizeclass, change_log)) %>%
    ungroup()

  keys %>%
    left_join(remapped, by = c("species", "sizeclass")) %>%
    arrange(.row) %>%
    select(Species_remapped, SizeClassNo_remapped, n_remap_steps)
}

# ---- 3. Join engine -----------------------------------------------------

#' Remap a raw LMO count data frame's identifiers to the current PEG_BVOL
#' edition, then join in the geometry/volume/carbon reference columns.
#'
#' `lmo` must have Species and SizeClassNo columns identifying what was
#' counted, plus whatever abundance column(s) the lab provides. The full
#' change log is always replayed (see the note at the top of this file for
#' why that's safe regardless of the file's original PEG_BVOL vintage).
#'
#' Adds a `needs_manual_review` column: TRUE where no match was found even
#' after remapping (e.g. a name PEG_BVOL never adopted, or a size class
#' missing from whatever reference the lab used) -- these need a manual
#' look, same as Carolin already does for cases like this.
join_lmo_to_peg_bvol <- function(lmo, biovolume_file, change_log) {
  remapped <- remap_species_sizeclass(lmo$Species, lmo$SizeClassNo, change_log)

  lmo %>%
    bind_cols(remapped) %>%
    left_join(
      biovolume_file,
      by = c("Species_remapped" = "Species", "SizeClassNo_remapped" = "SizeClassNo")
    ) %>%
    mutate(needs_manual_review = is.na(Genus))
}

# =========================================================================
# Demo: exercise the remap + join logic against data/LMO_378.xlsx.
#
# LMO_378.xlsx is genuine raw output from the Polish lab (Carolin, 2026-08-28):
# its Species/SizeClassNo/Abundance columns are real counts. It also carries
# Biovolume/Carbon-biomass columns the lab pre-computed against an older
# PEG_BVOL edition -- those are dropped on import below and not used for
# anything (not even comparison), since recomputing them from the current
# reference is the whole point of this pipeline.
# =========================================================================

if (sys.nframe() == 0) {
  biovolume_file <- read_biovolume_file(peg_bvol_path)
  change_log <- read_change_log(peg_bvol_path)

  lmo_raw <- read_excel("data/LMO_378.xlsx") %>%
    filter(!is.na(Species)) %>%
    transmute(
      `Division/Class`,
      Species,
      SizeClassNo,
      `Abundance [unit number/l]`
    )

  cat(sprintf("Loaded %d reference rows, %d identifier-change events.\n",
              nrow(biovolume_file), nrow(change_log)))

  # How much does a *direct* join (no remap) already miss?
  direct <- lmo_raw %>%
    left_join(biovolume_file, by = c("Species" = "Species", "SizeClassNo" = "SizeClassNo"))
  cat(sprintf(
    "Direct join (no remap) against current PEG_BVOL2026: %d/%d rows unmatched.\n",
    sum(is.na(direct$Genus)),
    nrow(direct)
  ))

  joined <- join_lmo_to_peg_bvol(lmo_raw, biovolume_file, change_log)

  cat(sprintf(
    "After remap: %d/%d rows unmatched (needs_manual_review).\n",
    sum(joined$needs_manual_review), nrow(joined)
  ))

  unmatched <- joined %>% filter(needs_manual_review) %>%
    distinct(Species, SizeClassNo, Species_remapped, SizeClassNo_remapped)
  if (nrow(unmatched) > 0) {
    cat("Still-unmatched species/size classes after remap -- flag for manual review:\n")
    print(unmatched)
  }

  renamed <- joined %>%
    filter(Species != Species_remapped | n_remap_steps > 0) %>%
    distinct(Species, SizeClassNo, Species_remapped, SizeClassNo_remapped, n_remap_steps)
  if (nrow(renamed) > 0) {
    cat("Identifiers the remap engine changed:\n")
    print(renamed)
  }
}
