# -*- coding: utf-8 -*-
"""
Match media under the repo root (excluding Combined/) for ReNamer.

1) combined_rename_map.csv — progressive path suffix vs OldRel.
2) imdb_title_year_from_log.csv — norm(file stem) vs norm(VideoName).

Outputs (ReNamer Import file paths and new names: column 1 must be absolute paths;
den4b wiki states relative paths are not supported):
- renamer_no_combined_all_videos_import.csv — every media file outside Combined\\; unmatched =
  same filename.
- renamer_no_combined_import_paths_newnames.csv — matched-only import.
- rest_of_repo_import_paths_newnames.csv — same as renamer_no_combined_import_paths_newnames.csv.
Use --repo-root if files were added in ReNamer via a mapped drive (e.g. Z:\\) but the script
lives on a UNC path.
- rest_of_repo_renamer_mapping*.csv — Mapping rule Match=basename when unambiguous.
"""
from __future__ import annotations

import argparse
import csv
import os
import sys
from collections import defaultdict
from pathlib import Path

from renamer_mapping_common import (
    disambiguate_duplicate_targets,
    disambiguate_newrel_per_relative_path,
    load_path_norm_to_newrel,
    norm,
    resolve_newrel_for_repo_rel,
)


def should_prune_dir(dir_name: str) -> bool:
    n = dir_name.casefold()
    return n == ".git" or n == ".cursor" or n == "combined"


def is_media_file(path: Path, media_suffixes: frozenset[str]) -> bool:
    return path.suffix.casefold() in media_suffixes


def escape_field(s: str) -> str:
    if any(c in s for c in ',"'):
        return '"' + s.replace('"', '""') + '"'
    return s


def stem_only(x: str) -> str:
    i = x.rfind(".")
    return x[:i] if i > 0 else x


def safe_windows_filename_base(title: str) -> str:
    invalid = '<>:"/\\|?*'
    out: list[str] = []
    for ch in title:
        if ch in invalid:
            out.append("_")
        elif ord(ch) < 32:
            out.append("_")
        else:
            out.append(ch)
    cleaned = "".join(out).strip()
    while cleaned.endswith("."):
        cleaned = cleaned[:-1].strip()
    if cleaned in ("", ".", ".."):
        return "Video"
    return cleaned


def build_newrel_from_imdb(display: str, year: str, ext: str) -> str:
    base = safe_windows_filename_base(display)
    if year:
        return f"{base} ({year}){ext}"
    return f"{base}{ext}"


def rel_path_to_absolute_path_string(repo_root: Path, rel_s: str) -> str:
    normalized = rel_s.replace("/", "\\")
    segments: list[str] = [seg for seg in normalized.split("\\") if seg != ""]
    combined = repo_root.joinpath(*segments)
    return os.path.normpath(str(combined))


def write_renamer_import_csv_absolute(
    out_path: Path,
    rel_to_new_name: dict[str, str],
    repo_root_for_absolute_paths: Path,
) -> None:
    with out_path.open("w", newline="", encoding="utf-8") as f:
        w = csv.writer(f, lineterminator="\n")
        for rel_s in sorted(rel_to_new_name.keys(), key=lambda s: s.lower()):
            abs_path = rel_path_to_absolute_path_string(repo_root_for_absolute_paths, rel_s)
            w.writerow([abs_path, rel_to_new_name[rel_s]])


def load_imdb_stem_lookup(imdb_path: Path) -> dict[str, tuple[str, str]]:
    mp: dict[str, tuple[str, str]] = {}
    with imdb_path.open(newline="", encoding="utf-8-sig") as f:
        for row in csv.DictReader(f):
            vn = (row.get("VideoName") or "").strip()
            if not vn:
                continue
            imdb = (row.get("ImdbTitle") or "").strip()
            year = (row.get("Year") or "").strip()
            display = imdb if imdb else vn
            mp[norm(vn)] = (display, year)
    return mp


def main(repo_root_for_import_csv: Path) -> None:
    script_dir = Path(__file__).resolve().parent
    csv_root = repo_root_for_import_csv.resolve()
    source_map = script_dir / "combined_rename_map.csv"
    imdb_log = script_dir / "imdb_title_year_from_log.csv"
    out_audit = script_dir / "rest_of_repo_rename_matched.csv"
    out_import = script_dir / "rest_of_repo_import_paths_newnames.csv"
    out_import_renamer = script_dir / "renamer_no_combined_import_paths_newnames.csv"
    out_import_all_videos = script_dir / "renamer_no_combined_all_videos_import.csv"
    out_renamer = script_dir / "rest_of_repo_renamer_mapping.csv"
    out_skip = script_dir / "rest_of_repo_renamer_mapping_skip_ext.csv"
    out_unmatched = script_dir / "rest_of_repo_unmatched_paths.txt"
    out_basename_conflicts = script_dir / "rest_of_repo_basename_mapping_skipped.txt"

    media_suffixes = frozenset(
        {
            ".mkv",
            ".mp4",
            ".avi",
            ".m4v",
            ".wmv",
            ".mpg",
            ".mpeg",
            ".mov",
        }
    )

    if not script_dir.is_dir():
        raise NotADirectoryError(str(script_dir))
    if not source_map.is_file():
        raise FileNotFoundError(str(source_map))

    path_norm_to_newrel = load_path_norm_to_newrel(source_map)
    imdb_by_norm: dict[str, tuple[str, str]] = {}
    if imdb_log.is_file():
        imdb_by_norm = load_imdb_stem_lookup(imdb_log)

    matched: list[tuple[str, str, str, str]] = []
    scan_rows: list[tuple[str, str, str | None, str]] = []
    unmatched: list[str] = []
    basename_to_targets: dict[str, set[str]] = {}

    for dirpath, dirnames, filenames in os.walk(script_dir):
        dirnames[:] = [d for d in dirnames if not should_prune_dir(d)]
        for fn in filenames:
            full = Path(dirpath) / fn
            if not is_media_file(full, media_suffixes):
                continue
            rel = full.relative_to(script_dir)
            rel_s = str(rel).replace("/", "\\")
            ext = full.suffix
            file_stem = full.stem

            newrel = resolve_newrel_for_repo_rel(rel_s, path_norm_to_newrel)
            source = "combined_map"
            if newrel is None and imdb_by_norm:
                im_hit = imdb_by_norm.get(norm(file_stem))
                if im_hit is not None:
                    display, year = im_hit
                    newrel = build_newrel_from_imdb(display, year, ext)
                    source = "imdb_log"

            if newrel is None:
                scan_rows.append((rel_s, fn, None, "unmatched"))
                unmatched.append(rel_s)
                continue

            scan_rows.append((rel_s, fn, newrel, source))
            matched.append((rel_s, newrel, fn, source))
            bn = fn.casefold()
            if bn not in basename_to_targets:
                basename_to_targets[bn] = set()
            basename_to_targets[bn].add(newrel)

    conflicts: list[str] = []
    for bn_cf, targets in basename_to_targets.items():
        if len(targets) > 1:
            conflicts.append(
                f"basename casefold={bn_cf!r} -> distinct NewRel count={len(targets)}: {sorted(targets)}"
            )
    if conflicts:
        msg = "Same filename maps to multiple NewRel values; fix maps or paths.\n" + "\n".join(
            conflicts
        )
        raise ValueError(msg)

    rel_path_pairs = [(rel_s, newrel) for rel_s, newrel, _fn, _src in matched]
    rel_to_final = disambiguate_newrel_per_relative_path(rel_path_pairs)

    rel_to_final_all: dict[str, str] = {}
    for rel_s, fn, newrel, _src in scan_rows:
        if newrel is None:
            rel_to_final_all[rel_s] = fn
        else:
            rel_to_final_all[rel_s] = rel_to_final[rel_s]

    write_renamer_import_csv_absolute(out_import, rel_to_final, csv_root)
    write_renamer_import_csv_absolute(out_import_renamer, rel_to_final, csv_root)
    write_renamer_import_csv_absolute(out_import_all_videos, rel_to_final_all, csv_root)

    by_basename: dict[str, list[tuple[str, str]]] = defaultdict(list)
    for rel_s, newrel, fn, _src in matched:
        final_n = rel_to_final[rel_s]
        by_basename[fn].append((rel_s, final_n))

    pairs_for_renamer: list[tuple[str, str]] = []
    basename_skipped: list[str] = []
    for fn, entries in sorted(by_basename.items(), key=lambda t: t[0].lower()):
        distinct_new = {e[1] for e in entries}
        if len(distinct_new) != 1:
            basename_skipped.append(
                f"{fn}\t" + "; ".join(sorted({f'{r} -> {n}' for r, n in entries}))
            )
            continue
        single_new = next(iter(distinct_new))
        pairs_for_renamer.append((fn, single_new))

    final_pairs = disambiguate_duplicate_targets(pairs_for_renamer)

    with out_audit.open("w", newline="", encoding="utf-8") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(["OldRel", "NewRel", "Source"])
        for rel_s, newrel, _fn, src in sorted(matched, key=lambda t: t[0].lower()):
            w.writerow([rel_s, rel_to_final[rel_s], src])

    renamer_lines = [escape_field(a) + "," + escape_field(b) for a, b in final_pairs]
    skip_lines = [
        escape_field(stem_only(a)) + "," + escape_field(stem_only(b)) for a, b in final_pairs
    ]

    out_renamer.write_text("\n".join(renamer_lines) + "\n", encoding="utf-8")
    out_skip.write_text("\n".join(skip_lines) + "\n", encoding="utf-8")
    out_unmatched.write_text("\n".join(sorted(unmatched, key=str.lower)) + "\n", encoding="utf-8")
    out_basename_conflicts.write_text(
        "\n".join(basename_skipped) + ("\n" if basename_skipped else ""), encoding="utf-8"
    )

    n_combined = sum(1 for t in matched if t[3] == "combined_map")
    n_imdb = sum(1 for t in matched if t[3] == "imdb_log")
    print("import_csv_absolute_root", str(csv_root))
    print("matched_files", len(matched), "combined_map", n_combined, "imdb_log", n_imdb)
    print("all_videos_import_rows", len(rel_to_final_all), "(includes unmatched as identity)")
    print("import_paths_rows", len(rel_to_final))
    print("renamer_mapping_rows", len(final_pairs), "(basename-only; skipped if ambiguous)")
    print("basename_mapping_skipped", len(basename_skipped))
    print("unmatched_files", len(unmatched))
    print(
        "wrote",
        out_import.name,
        out_import_renamer.name,
        out_import_all_videos.name,
        out_audit.name,
        out_renamer.name,
        out_skip.name,
        out_unmatched.name,
        out_basename_conflicts.name,
    )


def parse_cli_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Build den4b ReNamer import CSVs. Column 1 is absolute path (required by ReNamer)."
        )
    )
    parser.add_argument(
        "--repo-root",
        type=Path,
        dest="repo_root",
        help=(
            "Absolute repo root for CSV column 1. Use when ReNamer lists files under a mapped "
            "drive (e.g. Z:\\Rifftrax) but this script runs from \\\\server\\share\\Rifftrax."
        ),
    )
    return parser.parse_args(argv)


if __name__ == "__main__":
    script_dir_for_default = Path(__file__).resolve().parent
    cli = parse_cli_args(sys.argv[1:])
    chosen_root = cli.repo_root if cli.repo_root is not None else script_dir_for_default
    main(chosen_root)
