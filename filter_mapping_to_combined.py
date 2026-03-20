# -*- coding: utf-8 -*-
"""Keep only rows whose OldRel (normalized) matches a file under Combined/ (normalized rel path)."""
from __future__ import annotations

import csv
import os
from pathlib import Path


def norm(s: str) -> str:
    return "".join(c.lower() for c in s if not c.isspace())


def main() -> None:
    script_dir = Path(__file__).resolve().parent
    combined_dir = script_dir / "Combined"
    source_map = script_dir / "combined_rename_map.csv"
    out_combined_only = script_dir / "combined_rename_map_combined_only.csv"
    out_renamer = script_dir / "combined_rename_map_renamer_mapping.csv"
    out_skip = script_dir / "combined_rename_map_renamer_mapping_skip_ext.csv"

    if not combined_dir.is_dir():
        raise FileNotFoundError(str(combined_dir))
    if not source_map.is_file():
        raise FileNotFoundError(str(source_map))

    # norm(oldrel) -> (newrel, oldrel_from_csv)
    mp: dict[str, tuple[str, str]] = {}
    with source_map.open(newline="", encoding="utf-8-sig") as f:
        for row in csv.DictReader(f):
            old = (row.get("OldRel") or "").strip().strip('"')
            new = (row.get("NewRel") or "").strip().strip('"')
            if not old or not new:
                continue
            key = norm(old.replace("/", "\\"))
            mp[key] = (new, old)

    # One row per physical file. Do NOT dedupe by norm(rel): two different
    # on-disk names (e.g. StarWarsSolo2018.mkv vs spaced) normalize the same
    # but ReNamer Name must match the exact basename.
    rows: list[tuple[str, str, str]] = []
    missing: list[str] = []

    for dirpath, _dirnames, filenames in os.walk(combined_dir):
        for fn in filenames:
            full = Path(dirpath) / fn
            rel = full.relative_to(combined_dir)
            rel_s = str(rel).replace("/", "\\")
            k = norm(rel_s)
            if k in mp:
                newrel, _old_csv = mp[k]
                rows.append((rel_s, newrel, fn))
            else:
                missing.append(rel_s)

    rows.sort(key=lambda t: t[0].lower())

    with out_combined_only.open("w", newline="", encoding="utf-8") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(["OldRel", "NewRel"])
        for rel_s, newrel, _fn in rows:
            w.writerow([rel_s, newrel])

    def escape_field(s: str) -> str:
        if any(c in s for c in ',"'):
            return '"' + s.replace('"', '""') + '"'
        return s

    renamer_lines: list[str] = []
    skip_lines: list[str] = []
    for _rel_s, newrel, fn in rows:

        def stem(x: str) -> str:
            i = x.rfind(".")
            return x[:i] if i > 0 else x

        renamer_lines.append(escape_field(fn) + "," + escape_field(newrel))
        skip_lines.append(escape_field(stem(fn)) + "," + escape_field(stem(newrel)))

    out_renamer.write_text("\n".join(renamer_lines) + "\n", encoding="utf-8")
    out_skip.write_text("\n".join(skip_lines) + "\n", encoding="utf-8")

    print("matched_rows", len(rows))
    print("unmatched_files_on_disk", len(missing))
    print("wrote", out_combined_only.name, out_renamer.name, out_skip.name)
    if missing:
        print("unmatched_sample:")
        for m in missing[:20]:
            print(" ", m)


if __name__ == "__main__":
    main()
