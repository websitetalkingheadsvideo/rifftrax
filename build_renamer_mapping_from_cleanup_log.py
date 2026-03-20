# -*- coding: utf-8 -*-
"""
Build ReNamer Mapping CSV: current on-disk basename (letter-spaced) -> NewRel.

Uses cleanup_combined_filenames.log RENAMED lines (old basename -> spaced basename)
and combined_rename_map.csv (OldRel path -> NewRel). Resolves basename via norm() and
a few explicit aliases when CSV basename != log old basename.
"""
from __future__ import annotations

import csv
import re
from pathlib import Path


def norm(s: str) -> str:
    return "".join(c.lower() for c in s if not c.isspace())


def basename_only(rel: str) -> str:
    return rel.replace("/", "\\").split("\\")[-1]


def split_stem_ext(filename: str) -> tuple[str, str]:
    i = filename.rfind(".")
    if i <= 0:
        return filename, ""
    return filename[:i], filename[i:]


def disambiguate_duplicate_targets(
    pairs: list[tuple[str, str]],
) -> list[tuple[str, str]]:
    """Append ' (2)', ' (3)' before extension when several sources share the same NewRel."""
    by_newrel: dict[str, list[tuple[str, str]]] = {}
    for spaced_b, newrel in pairs:
        if newrel not in by_newrel:
            by_newrel[newrel] = []
        by_newrel[newrel].append((spaced_b, newrel))
    out: list[tuple[str, str]] = []
    for newrel in sorted(by_newrel.keys(), key=lambda s: s.lower()):
        group = sorted(by_newrel[newrel], key=lambda t: t[0].lower())
        for idx, (spaced_b, _ignored) in enumerate(group):
            if idx == 0:
                out.append((spaced_b, newrel))
                continue
            stem_part, ext_part = split_stem_ext(newrel)
            dup_index = idx + 1
            disambiguated = f"{stem_part} ({dup_index}){ext_part}"
            out.append((spaced_b, disambiguated))
    out.sort(key=lambda t: t[0].lower())
    return out


def main() -> None:
    root = Path(__file__).resolve().parent
    log_path = root / "cleanup_combined_filenames.log"
    map_path = root / "combined_rename_map.csv"
    out_renamer = root / "combined_rename_map_renamer_mapping.csv"
    out_skip = root / "combined_rename_map_renamer_mapping_skip_ext.csv"
    out_combined_only = root / "combined_rename_map_combined_only.csv"

    # norm(basename OldRel) -> NewRel (last wins)
    by_norm: dict[str, str] = {}
    with map_path.open(newline="", encoding="utf-8-sig") as f:
        for row in csv.DictReader(f):
            old = (row.get("OldRel") or "").strip().strip('"')
            new = (row.get("NewRel") or "").strip().strip('"')
            if not old or not new:
                continue
            by_norm[norm(basename_only(old))] = new

    # Log old basename -> spaced basename (last wins for duplicate RENAMED lines)
    log_pairs: list[tuple[str, str]] = []
    pat = re.compile(r"^RENAMED\t(.+)\t(.+)$")
    for line in log_path.read_text(encoding="utf-8").splitlines():
        m = pat.match(line)
        if not m:
            continue
        log_pairs.append((m.group(1), m.group(2)))

    # Explicit aliases: norm(log old basename) when it does not match CSV basename
    aliases: dict[str, str] = {
        norm("IndianaJonesAndTheTempleOfDoom 1984.mp4"): by_norm.get(
            norm("IndianaJonesAndTheTempleOfDoom 1984 1080p BluRay x264 YIFY.mp4"), ""
        ),
        norm("TotalRecallMindBendingEdition 1990.mp4"): by_norm.get(
            norm("TotalRecallMindBendingEditio n19901080p BluRay x264Y IFY.mp4"), ""
        ),
        norm("RoadHouse 1989.mkv"): by_norm.get(
            norm("RoadHous e19891080p Rifftra x13R ifferRifftra x2M ike.mkv"), ""
        ),
    }

    rows: list[tuple[str, str, str]] = []
    for old_b, spaced_b in log_pairs:
        k = norm(old_b)
        newrel = by_norm.get(k) or aliases.get(k, "")
        if not newrel:
            continue
        rows.append((old_b, spaced_b, newrel))

    # StarWarsSolo2018.mkv (not in log RENAMED left column) — same NewRel as Solo rows
    solo_new = by_norm.get(norm("StarWarsSolo2018.mkv"), "")
    if solo_new:
        rows.append(("StarWarsSolo2018.mkv", "StarWarsSolo2018.mkv", solo_new))

    # Dedupe by spaced basename (Name in ReNamer); keep last
    by_spaced: dict[str, tuple[str, str]] = {}
    for _old_b, spaced_b, newrel in rows:
        by_spaced[spaced_b] = (spaced_b, newrel)

    final_list = disambiguate_duplicate_targets(
        sorted(by_spaced.values(), key=lambda t: t[0].lower())
    )

    def esc(s: str) -> str:
        if any(c in s for c in ',"'):
            return '"' + s.replace('"', '""') + '"'
        return s

    def stem(x: str) -> str:
        i = x.rfind(".")
        return x[:i] if i > 0 else x

    renamer_lines = [esc(a) + "," + esc(b) for a, b in final_list]
    skip_lines = [esc(stem(a)) + "," + esc(stem(b)) for a, b in final_list]

    out_renamer.write_text("\n".join(renamer_lines) + "\n", encoding="utf-8")
    out_skip.write_text("\n".join(skip_lines) + "\n", encoding="utf-8")

    with out_combined_only.open("w", newline="", encoding="utf-8") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(["OldRel", "NewRel"])
        for spaced_b, newrel in final_list:
            w.writerow([spaced_b, newrel])

    print("rows", len(final_list))
    print("wrote", out_renamer.name, out_skip.name, out_combined_only.name)


if __name__ == "__main__":
    main()
