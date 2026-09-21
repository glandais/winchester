#!/usr/bin/env python3
"""Rassemble toutes les traductions du dépôt dans un seul JSON, et les y remet.

    scripts/i18n.py export [-o i18n/translations.json]   # sources -> un JSON
    scripts/i18n.py import [-i i18n/translations.json]   # un JSON -> sources
    scripts/i18n.py check                                # l'aller-retour est exact à l'octet

Ce qu'il couvre, en anglais et en français :

  * `Sources/Resources/Localizable.xcstrings`  — les écrans
  * `screenshots/koubou/koubou-strings.xcstrings` — les titres des captures du store
  * `metadata/app-info/<locale>.json`          — nom, sous-titre et adresses du store
  * `metadata/version/<version>/<locale>.json` — description, mots-clés, nouveautés

La correspondance est bijective : un `import` lancé juste après un `export`
réécrit chacun de ces fichiers octet pour octet, si bien que le JSON peut être
modifié (ou confié à une traductrice) puis reposé sans rien perdre des
variations de pluriel, des substitutions, des commentaires, des états
d'extraction, de l'ordre des clés ni du formatage des fichiers.

Une clé dont le nom est une phrase française est une chaîne **pas encore
migrée** : `xcstringstool` l'a extraite du code telle quelle. Le registre de ce
qui reste à traduire, c'est donc le catalogue lui-même — voir la section
« Traduction » de `CLAUDE.md`.

Les clés du catalogue Koubou sont la phrase anglaise elle-même : c'est ainsi que
Koubou retrouve la traduction d'une variable de `screenshots/koubou/*.yaml`. Elles
échappent donc à la règle des noms pointés, et `check` vérifie à la place que chaque
variable des deux configurations est une clé du catalogue, et qu'elles concordent.

Volontairement hors champ, parce qu'anglais par nature :
`metadata/review-notes.md` et `metadata/app-privacy.json` (aucune prose).
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RESOURCES = ROOT / "Sources" / "Resources"

CATALOGS = {
    "Localizable": RESOURCES / "Localizable.xcstrings",
    "Koubou": ROOT / "screenshots" / "koubou" / "koubou-strings.xcstrings",
}
# Les configurations Koubou dont les variables sont les clés du catalogue du même nom.
KOUBOU_CONFIGS = sorted((ROOT / "screenshots" / "koubou").glob("[!.]*.yaml"))
METADATA = ROOT / "metadata"
DEFAULT_JSON = ROOT / "i18n" / "translations.json"

# Le catalogue emploie des codes de langue courts ; App Store Connect a les
# siens pour les mêmes langues, et ce sont ceux-là qui nomment `metadata/`.
LOCALE_MAP = {"en": "en-US", "fr": "fr-FR"}

# ---------------------------------------------------------------- catalog i/o

def catalog_style(path: Path) -> tuple[str, str]:
    """Renifle la façon dont ce catalogue est déjà écrit, pour qu'une réécriture
    ne change rien.

    Xcode écrit `"clé" : valeur` ; un fichier produit par un autre outil peut
    employer le compact `"clé": valeur`. On garde celui du fichier sur le
    disque, et sa dernière ligne (ou son absence)."""
    text = path.read_text(encoding="utf-8") if path.exists() else ""
    colon = " : " if '" : ' in text else ": "
    return colon, "\n" if text.endswith("\n") else ""


# Xcode écrit une entrée vide sur trois lignes — `{`, une ligne blanche, `}` —
# là où `json.dumps` écrit `{}`. Une clé pas encore migrée n'a rien d'autre,
# donc sans ça l'aller-retour diverge sur 173 entrées.
EMPTY_OBJECT = re.compile(r"^(\s*)(.*): \{\}(,?)$", re.MULTILINE)


def dump_catalog(data: dict, style: tuple[str, str]) -> str:
    colon, tail = style
    text = json.dumps(data, indent=2, sort_keys=True,
                      ensure_ascii=False, separators=(",", colon))
    text = EMPTY_OBJECT.sub(lambda m: f"{m[1]}{m[2]}: {{\n\n{m[1]}}}{m[3]}", text)
    return text + tail

# ------------------------------------------------------- unit encode / decode
# Un « nœud d'unité » est tout ce qui porte stringUnit / variations /
# substitutions : une localisation, un cas de variation, ou le corps d'une
# substitution.

def encode_unit(node: dict) -> object:
    out: dict = {}
    unit = node.get("stringUnit")
    if unit is not None:
        out["value"] = unit["value"]
        if unit.get("state") != "translated":
            out["state"] = unit.get("state")
    if "variations" in node:
        out["variations"] = {
            kind: {case: encode_unit(body) for case, body in cases.items()}
            for kind, cases in node["variations"].items()
        }
    if "substitutions" in node:
        subs = {}
        for name, sub in node["substitutions"].items():
            body = encode_unit({k: v for k, v in sub.items()
                                if k in ("stringUnit", "variations", "substitutions")})
            if not isinstance(body, dict):
                body = {"value": body}
            entry = {k: v for k, v in sub.items()
                     if k not in ("stringUnit", "variations", "substitutions")}
            entry.update(body)
            subs[name] = entry
        out["substitutions"] = subs
    # le cas courant — une chaîne traduite toute simple — reste une chaîne nue
    if list(out) == ["value"]:
        return out["value"]
    return out


def decode_unit(node: object) -> dict:
    if isinstance(node, str):
        return {"stringUnit": {"state": "translated", "value": node}}
    out: dict = {}
    if "value" in node:
        out["stringUnit"] = {"state": node.get("state", "translated"),
                             "value": node["value"]}
    if "variations" in node:
        out["variations"] = {
            kind: {case: decode_unit(body) for case, body in cases.items()}
            for kind, cases in node["variations"].items()
        }
    if "substitutions" in node:
        subs = {}
        for name, entry in node["substitutions"].items():
            body = decode_unit({k: v for k, v in entry.items()
                                if k in ("value", "state", "variations", "substitutions")})
            meta = {k: v for k, v in entry.items()
                    if k not in ("value", "state", "variations", "substitutions")}
            subs[name] = {**meta, **body}
        out["substitutions"] = subs
    return out


def encode_catalog(path: Path) -> dict:
    cat = json.loads(path.read_text(encoding="utf-8"))
    keys = {}
    for key, entry in cat["strings"].items():
        out = {}
        if "comment" in entry:
            out["comment"] = entry["comment"]
        if "extractionState" in entry:
            out["extractionState"] = entry["extractionState"]
        out["translations"] = {lang: encode_unit(loc)
                               for lang, loc in entry.get("localizations", {}).items()}
        keys[key] = out
    return {"path": str(path.relative_to(ROOT)),
            "sourceLanguage": cat.get("sourceLanguage", "en"),
            "version": cat.get("version", "1.0"),
            "keys": keys}


def decode_catalog(table: dict) -> dict:
    strings = {}
    for key, entry in table["keys"].items():
        out = {}
        if "comment" in entry:
            out["comment"] = entry["comment"]
        if "extractionState" in entry:
            out["extractionState"] = entry["extractionState"]
        # Une clé pas encore migrée n'a aucune localisation, et `xcstringstool`
        # l'écrit alors sans clé `localizations` du tout : en poser une vide
        # ferait diverger l'aller-retour à chaque synchronisation.
        if entry["translations"]:
            out["localizations"] = {lang: decode_unit(node)
                                    for lang, node in entry["translations"].items()}
        strings[key] = out
    return {"sourceLanguage": table["sourceLanguage"],
            "strings": strings,
            "version": table["version"]}

# ------------------------------------------------------------------- metadata

def metadata_files() -> list[Path]:
    files = sorted((METADATA / "app-info").glob("*.json"))
    for version_dir in sorted((METADATA / "version").iterdir()):
        if version_dir.is_dir():
            files += sorted(version_dir.glob("*.json"))
    return files


def encode_metadata() -> dict:
    """Une entrée par fichier canonique de métadonnées, ordre des clés compris."""
    scopes: dict = {}
    for path in metadata_files():
        rel = path.relative_to(METADATA)
        scope = "app-info" if rel.parts[0] == "app-info" else f"version/{rel.parts[1]}"
        scopes.setdefault(scope, {})[path.stem] = json.loads(
            path.read_text(encoding="utf-8"))
    return {"path": str(METADATA.relative_to(ROOT)), "scopes": scopes}


def dump_metadata_file(payload: dict) -> str:
    return json.dumps(payload, indent=2, ensure_ascii=False) + "\n"


def metadata_targets(meta: dict) -> list[tuple[Path, str]]:
    out = []
    for scope, locales in meta["scopes"].items():
        for locale, payload in locales.items():
            out.append((METADATA / scope / f"{locale}.json",
                        dump_metadata_file(payload)))
    return out

# ------------------------------------------------------------------ commands

def build_export() -> dict:
    tables = {name: encode_catalog(path) for name, path in CATALOGS.items()}
    seen = {lang for t in tables.values()
            for k in t["keys"].values() for lang in k["translations"]}
    languages = {
        "catalog": sorted(seen & set(LOCALE_MAP)),
        "appStoreConnect": sorted(LOCALE_MAP.values()),
    }
    # Une clé dont le nom n'est pas un nom pointé est une chaîne que
    # `xcstringstool` a extraite telle quelle du code : elle n'a pas encore
    # été migrée. La chaîne vide n'en est pas une — c'est l'indice
    # d'accessibilité absent de `accessibilityHint(… : "")`.
    dotted = re.compile(r"^[a-z][A-Za-z0-9-]*(\.[A-Za-z0-9-]+)+$")
    pending = sorted(k for name, t in tables.items() if name != "Koubou"
                     for k in t["keys"] if k and not dotted.match(k))
    return {
        "generatedBy": "scripts/i18n.py export",
        "languages": languages,
        "localeMap": LOCALE_MAP,
        "notYetMigrated": pending,
        "tables": tables,
        "metadata": encode_metadata(),
    }


def cmd_export(args) -> int:
    out = Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    data = build_export()
    out.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n",
                   encoding="utf-8")
    keys = sum(len(t["keys"]) for t in data["tables"].values())
    units = sum(len(k["translations"])
                for t in data["tables"].values() for k in t["keys"].values())
    fields = sum(len(p) for s in data["metadata"]["scopes"].values()
                 for p in s.values())
    print(f"{out.relative_to(ROOT)} : {keys} clés, {units} localisations, "
          f"{fields} champs de métadonnées, "
          f"{len(data['languages']['catalog'])} langues, "
          f"{len(data['notYetMigrated'])} chaînes pas encore migrées")
    return 0


def cmd_import(args) -> int:
    data = json.loads(Path(args.input).read_text(encoding="utf-8"))
    for name, table in data["tables"].items():
        path = ROOT / table["path"]
        path.write_text(dump_catalog(decode_catalog(table), catalog_style(path)),
                        encoding="utf-8")
        print(f"écrit {table['path']} ({len(table['keys'])} clés)")
    for path, body in metadata_targets(data["metadata"]):
        path.write_text(body, encoding="utf-8")
    print(f"écrit {len(metadata_targets(data['metadata']))} fichiers "
          f"sous {data['metadata']['path']}/")
    return 0


def koubou_variables(path: Path) -> dict:
    import yaml
    config = yaml.safe_load(path.read_text(encoding="utf-8"))
    return {card: dict(spec.get("variables", {}))
            for card, spec in config.get("screenshots", {}).items()}


def check_koubou(keys: set) -> bool:
    """Chaque variable est une clé du catalogue, et l'iPhone dit ce que dit l'iPad."""
    ok = True
    configs = [p for p in KOUBOU_CONFIGS if not p.name.endswith(".local.yaml")]
    seen = {p.name: koubou_variables(p) for p in configs}
    for name, cards in seen.items():
        for card, variables in cards.items():
            for var, value in variables.items():
                if value not in keys:
                    ok = False
                    print(f"{name} : {card}.{var} n'est pas une clé du catalogue Koubou",
                          file=sys.stderr)
    if len({json.dumps(c, sort_keys=True) for c in seen.values()}) > 1:
        ok = False
        print(f"{', '.join(seen)} : les variables divergent — un titre se change "
              f"dans toutes les configurations", file=sys.stderr)
    if ok and seen:
        print(f"screenshots/koubou/ : {len(seen)} configurations, variables toutes au catalogue")
    return ok


def cmd_check(args) -> int:
    data = build_export()
    ok = check_koubou(set(data["tables"]["Koubou"]["keys"]))
    for name, table in data["tables"].items():
        path = ROOT / table["path"]
        after = dump_catalog(decode_catalog(table), catalog_style(path))
        if path.read_text(encoding="utf-8") == after:
            print(f"{table['path']} : aller-retour exact à l'octet")
        else:
            ok = False
            print(f"{table['path']} : DIVERGENCE", file=sys.stderr)
    bad = [p for p, text in metadata_targets(data["metadata"])
           if p.read_text(encoding="utf-8") != text]
    if bad:
        ok = False
        for p in bad:
            print(f"{p.relative_to(ROOT)} : DIVERGENCE", file=sys.stderr)
    else:
        print(f"metadata/ : aller-retour exact à l'octet "
              f"({len(metadata_targets(data['metadata']))} fichiers)")
    return 0 if ok else 1


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    e = sub.add_parser("export"); e.add_argument("-o", "--output", default=str(DEFAULT_JSON)); e.set_defaults(func=cmd_export)
    i = sub.add_parser("import"); i.add_argument("-i", "--input", default=str(DEFAULT_JSON)); i.set_defaults(func=cmd_import)
    c = sub.add_parser("check"); c.set_defaults(func=cmd_check)
    args = p.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
