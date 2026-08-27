# HELCOM PEG_BVOL name/size-class remap + lookup for LMO phytoplankton counts
#
# Context: LMO occasions are counted against whichever PEG_BVOL edition was
# current at the time. Species get renamed and size classes get renumbered
# between editions, so a straight join of an LMO count file against the
# current PEG_BVOL reference on (Species, SizeClassNo) silently drops rows
# whose identifiers have since changed (e.g. Lingulodinium polyedra ->
# Lingulaulax polyedra). PEG_BVOL2026.xlsx ships a "Change log" sheet that
# records these renames/renumberings in structured columns back to 2006; this
# script replays that log to bring an older count file's identifiers forward
# to the current edition before joining.
#
# STATUS: work in progress, see README.md "Open questions". We don't yet have
# a genuine raw (pre-join) LMO count file to validate against -- data/LMO_378.xlsx
# is an example of the *target* output shape but with outdated reference
# numbers, so the demo at the bottom of this script uses it only to exercise
# the remap+join logic, not as a real input.
#
# Deliberately out of scope here: computing final biovolume/carbon biomass
# from abundance. Per Carolin's email, once she has abundance joined to the
# HELCOM geometry/volume/carbon-per-counting-unit columns she'll do that
# calculation herself -- this script stops at producing that joined table.

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

#' Replay the change log against one (species, size class) pair, walking
#' forward in chronological (Year) order, until nothing more applies.
#'
#' `from_year` is the PEG_BVOL edition the original count was coded against;
#' only changes strictly after it are replayed. Guards against runaway loops
#' (there shouldn't be any, but a cycle would otherwise hang silently).
remap_one <- function(species, sizeclass, from_year, change_log) {
  applicable <- change_log %>% filter(Year > from_year)
  cur_species <- species
  cur_sizeclass <- sizeclass
  n_steps <- 0

  repeat {
    hit <- applicable %>%
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
#' sizeclass, from_year) triples are remapped once and joined back, since a
#' typical LMO file has many rows sharing the same identifier.
remap_species_sizeclass <- function(species, sizeclass, from_year, change_log) {
  keys <- tibble(species, sizeclass, from_year) %>%
    mutate(.row = row_number())

  distinct_keys <- keys %>% distinct(species, sizeclass, from_year)

  remapped <- distinct_keys %>%
    rowwise() %>%
    mutate(remap_one(species, sizeclass, from_year, change_log)) %>%
    ungroup()

  keys %>%
    left_join(remapped, by = c("species", "sizeclass", "from_year")) %>%
    arrange(.row) %>%
    select(Species_remapped, SizeClassNo_remapped, n_remap_steps)
}

# ---- 3. Join engine -----------------------------------------------------

#' Remap a raw LMO count data frame's identifiers to the current PEG_BVOL
#' edition, then join in the geometry/volume/carbon reference columns.
#'
#' `lmo` must have Species and SizeClassNo columns identifying what was
#' counted, plus whatever abundance column(s) the lab provides.
#' `from_year` is the PEG_BVOL edition year the LMO occasion was originally
#' coded against (a single year applied to every row, or a same-length
#' vector if it varies row to row).
join_lmo_to_peg_bvol <- function(lmo, from_year, biovolume_file, change_log) {
  remapped <- remap_species_sizeclass(
    lmo$Species, lmo$SizeClassNo, from_year, change_log
  )

  lmo %>%
    bind_cols(remapped) %>%
    left_join(
      biovolume_file,
      by = c("Species_remapped" = "Species", "SizeClassNo_remapped" = "SizeClassNo")
    )
}

# =========================================================================
# Demo: exercise the remap + join logic against data/LMO_378.xlsx.
#
# This is NOT a real pipeline run -- LMO_378.xlsx is an already-joined
# example with outdated numbers (see README), so its Species/SizeClassNo
# columns are used here only as a stand-in "raw" input, and the resulting
# joined columns are not compared against its own (outdated) values.
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

  # Worst-case assumption: this occasion was coded against the oldest edition
  # the change log covers (2006), so remap everything forward from there.
  joined <- join_lmo_to_peg_bvol(lmo_raw, from_year = 2006, biovolume_file, change_log)

  cat(sprintf(
    "After remap (assuming from_year = 2006): %d/%d rows unmatched.\n",
    sum(is.na(joined$Genus)), nrow(joined)
  ))

  unmatched <- joined %>% filter(is.na(Genus)) %>%
    distinct(Species, SizeClassNo, Species_remapped, SizeClassNo_remapped)
  if (nrow(unmatched) > 0) {
    cat("Still-unmatched species/size classes after remap:\n")
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
