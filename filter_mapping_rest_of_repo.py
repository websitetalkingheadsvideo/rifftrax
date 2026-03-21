# -*- coding: utf-8 -*-
"""
Match media under the repo root (excluding Combined/) for ReNamer Mapping.

Uses combined_rename_map.csv (path suffix -> NewRel) and imdb_title_year_from_log.csv
(norm stem -> title/year). Anything else gets a filename-derived target.

Writes only:
  rest_of_repo_renamer_mapping.csv       — Match = basename, Skip extension OFF
  rest_of_repo_renamer_mapping_skip_ext.csv — Match/New Name without extension
"""
from __future__ import annotations

import csv
import os
import re
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


def infer_preferred_from_stem(stem: str, ext: str) -> str:
    stripped = stem.strip()
    m = re.match(r"^(.*)\s+\((\d{4})\)\s*$", stripped)
    if m is not None:
        title = m.group(1).strip()
        year = m.group(2)
        return build_newrel_from_imdb(title, year, ext)
    return build_newrel_from_imdb(stripped, "", ext)


def write_renamer_mapping_csv(out_path: Path, pairs: list[tuple[str, str]]) -> None:
    with out_path.open("w", newline="", encoding="utf-8") as f:
        w = csv.writer(
            f,
            delimiter=",",
            lineterminator="\n",
            quoting=csv.QUOTE_MINIMAL,
        )
        for left, right in pairs:
            w.writerow([left, right])


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


def main() -> None:
    script_dir = Path(__file__).resolve().parent
    source_map = script_dir / "combined_rename_map.csv"
    imdb_log = script_dir / "imdb_title_year_from_log.csv"
    out_renamer = script_dir / "rest_of_repo_renamer_mapping.csv"
    out_skip = script_dir / "rest_of_repo_renamer_mapping_skip_ext.csv"

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
            if newrel is not None:
                source = "combined_map"
            elif imdb_by_norm:
                im_hit = imdb_by_norm.get(norm(file_stem))
                if im_hit is not None:
                    display, year = im_hit
                    newrel = build_newrel_from_imdb(display, year, ext)
                    source = "imdb_log"
            if newrel is None:
                newrel = infer_preferred_from_stem(file_stem, ext)
                source = "inferred_stem"

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

    by_basename: dict[str, list[tuple[str, str]]] = defaultdict(list)
    for rel_s, newrel, fn, _src in matched:
        final_n = rel_to_final[rel_s]
        by_basename[fn].append((rel_s, final_n))

    pairs_for_renamer: list[tuple[str, str]] = []
    basename_skipped = 0
    for fn, entries in sorted(by_basename.items(), key=lambda t: t[0].lower()):
        distinct_new = {e[1] for e in entries}
        if len(distinct_new) != 1:
            basename_skipped += 1
            continue
        single_new = next(iter(distinct_new))
        pairs_for_renamer.append((fn, single_new))

    final_pairs = disambiguate_duplicate_targets(pairs_for_renamer)

    write_renamer_mapping_csv(out_renamer, final_pairs)
    skip_pairs = [(stem_only(a), stem_only(b)) for a, b in final_pairs]
    write_renamer_mapping_csv(out_skip, skip_pairs)

    n_combined = sum(1 for t in matched if t[3] == "combined_map")
    n_imdb = sum(1 for t in matched if t[3] == "imdb_log")
    n_inferred = sum(1 for t in matched if t[3] == "inferred_stem")
    print(
        "files",
        len(matched),
        "combined_map",
        n_combined,
        "imdb_log",
        n_imdb,
        "inferred_stem",
        n_inferred,
        "mapping_rows",
        len(final_pairs),
        "basename_collisions_omitted",
        basename_skipped,
    )
    print("wrote", out_renamer.name, out_skip.name)


if __name__ == "__main__":
    main()
