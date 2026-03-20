# -*- coding: utf-8 -*-
"""Shared helpers for building ReNamer Mapping CSVs from combined_rename_map.csv."""
from __future__ import annotations

import csv
from pathlib import Path


def norm(s: str) -> str:
    return "".join(c.lower() for c in s if not c.isspace())


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
    for left_name, newrel in pairs:
        if newrel not in by_newrel:
            by_newrel[newrel] = []
        by_newrel[newrel].append((left_name, newrel))
    out: list[tuple[str, str]] = []
    for newrel in sorted(by_newrel.keys(), key=lambda s: s.lower()):
        group = sorted(by_newrel[newrel], key=lambda t: t[0].lower())
        for idx, (left_name, _ignored) in enumerate(group):
            if idx == 0:
                out.append((left_name, newrel))
                continue
            stem_part, ext_part = split_stem_ext(newrel)
            dup_index = idx + 1
            disambiguated = f"{stem_part} ({dup_index}){ext_part}"
            out.append((left_name, disambiguated))
    out.sort(key=lambda t: t[0].lower())
    return out


def load_path_norm_to_newrel(map_path: Path) -> dict[str, str]:
    """Last CSV row wins per norm(OldRel). Rows with empty NewRel are skipped."""
    mp: dict[str, str] = {}
    with map_path.open(newline="", encoding="utf-8-sig") as f:
        for row in csv.DictReader(f):
            old = (row.get("OldRel") or "").strip().strip('"')
            new = (row.get("NewRel") or "").strip().strip('"')
            if not old or not new:
                continue
            key = norm(old.replace("/", "\\"))
            mp[key] = new
    return mp


def disambiguate_newrel_per_relative_path(
    rel_path_to_newrel: list[tuple[str, str]],
) -> dict[str, str]:
    """Same target NewRel for multiple files -> append (2), (3) before extension by rel path order."""
    by_newrel: dict[str, list[str]] = {}
    for rel_s, newrel in rel_path_to_newrel:
        if newrel not in by_newrel:
            by_newrel[newrel] = []
        by_newrel[newrel].append(rel_s)
    out: dict[str, str] = {}
    for newrel in by_newrel:
        rels = sorted(by_newrel[newrel], key=lambda s: s.lower())
        for idx, rel_s in enumerate(rels):
            if idx == 0:
                out[rel_s] = newrel
            else:
                stem_part, ext_part = split_stem_ext(newrel)
                dup_index = idx + 1
                out[rel_s] = f"{stem_part} ({dup_index}){ext_part}"
    return out


def resolve_newrel_for_repo_rel(
    rel_under_root: str,
    path_norm_to_newrel: dict[str, str],
) -> str | None:
    """Try rel, then drop leading path segments until norm(rel) hits the map."""
    rel_s = rel_under_root.replace("/", "\\")
    parts = rel_s.split("\\")
    for i in range(0, len(parts)):
        candidate = "\\".join(parts[i:])
        k = norm(candidate)
        if k in path_norm_to_newrel:
            return path_norm_to_newrel[k]
    return None
