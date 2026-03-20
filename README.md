# rifftrax

Rename helpers (run on the machine that has `\\amber\Rifftrax`):

- **Combined/** (letter-spaced names): `RUN_BUILD_RENAMER_MAPPING_FROM_LOG.bat` → `combined_rename_map_renamer_mapping*.csv`
- **Everything except Combined/**: `RUN_FILTER_MAPPING_REST.bat` → den4b **Files → Export menu → Import file paths and new names** (no Mapping rule). Use **`renamer_no_combined_all_videos_import.csv`** for every video under the repo (outside Combined\\); rows without a map keep the current filename. Use **`renamer_no_combined_import_paths_newnames.csv`** (same as `rest_of_repo_import_paths_newnames.csv`) for **matched-only** renames. Also writes `rest_of_repo_renamer_mapping*.csv`, audit CSV, `rest_of_repo_unmatched_paths.txt`, `rest_of_repo_basename_mapping_skipped.txt`. See `RENAMER_ZERO_MATCHES.txt` if Mapping shows no changes.
