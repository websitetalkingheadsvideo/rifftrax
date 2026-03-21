# rifftrax

Rename helpers (run on the machine that has `\\amber\Rifftrax`):

- **Combined/** (letter-spaced names): `RUN_BUILD_RENAMER_MAPPING_FROM_LOG.bat` → `combined_rename_map_renamer_mapping*.csv`
- **Everything except Combined/**: `RUN_FILTER_MAPPING_REST.bat` (optional: `--repo-root` for Import CSV path prefix). **Which CSV?** **`WHICH_CSV_FOR_RENAMER.txt`**. Usual case: **Mapping** + **`rest_of_repo_renamer_mapping*.csv`** (no paths in file — like Combined). Optional: **`renamer_no_combined_*_import*.csv`** via Import menu. Troubleshooting: **`RENAMER_ZERO_MATCHES.txt`**.
