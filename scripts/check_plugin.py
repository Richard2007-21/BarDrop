#!/usr/bin/env python3
"""Prüft ein BarDrop-Plugin genau so, wie BarDrop es beim Import prüft, und packt es.

    python3 scripts/check_plugin.py MeinPlugin/            # Ordner prüfen
    python3 scripts/check_plugin.py MeinPlugin/ --pack     # prüfen und MeinPlugin.bdrop erzeugen
    python3 scripts/check_plugin.py MeinPlugin.bdrop       # fertige Datei prüfen

Fehler (Exitcode 1) lehnt BarDrop ab. Hinweise sind Dinge, die BarDrop annimmt, die aber
fast immer ein Versehen sind. Ist Node.js installiert, wird auch die Syntax des Skripts
geprüft (BarDrop selbst verwendet JavaScriptCore; Node findet aber dieselben Syntaxfehler).

Diese Regeln müssen mit Sources/BarDrop/Plugins/PluginManifest.swift und
PluginPackage.swift übereinstimmen. Wer dort etwas ändert, ändert es auch hier und in
docs/PLUGINS.md.
"""
import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

MAX_PACKAGE = 5 * 1024 * 1024
MAX_SCRIPT = 1024 * 1024
ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9-]*(\.[A-Za-z0-9][A-Za-z0-9-]*)+$")
VERSION_PATTERN = re.compile(r"^\d+(\.\d+){0,2}$")
PERMISSIONS = {"network", "run", "clipboard"}
TRIGGERS = {"menu", "action", "automatic"}
SETTING_TYPES = {"toggle", "choice", "text"}
KNOWN_KEYS = {"schema", "id", "name", "description", "version", "author", "homepage", "icon", "actionTitle",
              "minAppVersion", "script", "match", "triggers", "automaticByDefault", "permissions", "tools",
              "settings", "canReplaceOriginal", "consent"}
API = {"writeFile", "createLink", "readFile", "progress", "notify", "isCancelled", "sleep", "log", "fetch",
       "download", "run", "setClipboard", "settings", "language", "appVersion", "outputDirectory", "plugin"}

errors, hints = [], []


def error(text):
    errors.append(text)


def hint(text):
    hints.append(text)


def localized(value, where, required=False):
    if value is None:
        if required:
            error(f"{where} fehlt")
        return
    if isinstance(value, str):
        if required and not value.strip():
            error(f"{where} ist leer")
        return
    if not isinstance(value, dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in value.items()):
        error(f"{where} muss ein Text oder {{\"en\": \"…\", \"de\": \"…\"}} sein")
        return
    if "en" not in value:
        hint(f"{where} hat kein \"en\": für Englisch nimmt BarDrop dann irgendeine andere Sprache")
    if "de" not in value:
        hint(f"{where} hat kein \"de\": auf Deutsch erscheint der englische Text")
    if required and not (value.get("en") or next(iter(sorted(value.items())), ("", ""))[1]).strip():
        error(f"{where} ist leer")


def version_tuple(v):
    return tuple(int(x) for x in v.split("-")[0].split("."))


def check_manifest(m, files):
    if not isinstance(m, dict):
        return error("manifest.json muss ein JSON-Objekt sein")
    for key in m:
        if key not in KNOWN_KEYS:
            hint(f"Unbekannter Schlüssel \"{key}\" wird ignoriert (Tippfehler?)")
    if m.get("schema", 1) != 1:
        error("\"schema\" muss 1 sein")
    pid = m.get("id")
    if not isinstance(pid, str) or not ID_PATTERN.match(pid) or len(pid) > 120:
        error("\"id\" fehlt oder ist ungültig (z. B. io.github.name.plugin, nur Buchstaben, Ziffern, - und Punkte, höchstens 120 Zeichen)")
    localized(m.get("name"), "\"name\"", required=True)
    for key in ("description", "actionTitle", "consent"):
        localized(m.get(key), f"\"{key}\"")
    version = m.get("version")
    if not isinstance(version, str) or not VERSION_PATTERN.match(version):
        error("\"version\" fehlt oder ist ungültig (1, 1.2 oder 1.2.3, als Text)")
    minimum = m.get("minAppVersion")
    if minimum is not None and (not isinstance(minimum, str) or not VERSION_PATTERN.match(minimum)):
        error("\"minAppVersion\" ist ungültig (z. B. \"1.31.0\")")
    elif minimum is None:
        hint("\"minAppVersion\" fehlt: setze mindestens \"1.31.0\"")

    icon = m.get("icon")
    if icon is None:
        hint("\"icon\" fehlt: das Plugin bekommt ein graues Puzzleteil")
    elif not isinstance(icon, dict) or not isinstance(icon.get("symbol"), str):
        error("\"icon\" braucht \"symbol\" (Name eines SF Symbols)")
    elif "color" in icon and not re.fullmatch(r"#?[0-9A-Fa-f]{6}", str(icon["color"])):
        hint("\"icon.color\" ist kein #RRGGBB: die Kachel wird grau")

    script = m.get("script", "main.js")
    if not isinstance(script, str) or "/" in script or script.startswith(".") or not script.endswith(".js"):
        error("\"script\" muss ein Dateiname auf .js ohne Ordner sein")
    elif script not in files:
        error(f"Skript \"{script}\" fehlt im Plugin")

    match = m.get("match")
    if not isinstance(match, dict):
        error("\"match\" fehlt")
        match = {}
    types = match.get("types") or []
    exts = match.get("extensions") or []
    links = match.get("links") or {}
    hosts = links.get("hosts") or [] if isinstance(links, dict) else []
    patterns = links.get("patterns") or [] if isinstance(links, dict) else []
    if not (types or exts or hosts or patterns):
        error("\"match\" braucht mindestens eine Regel (types, extensions, links.hosts oder links.patterns)")
    for ext in exts:
        if not isinstance(ext, str) or not ext.strip("."):
            error(f"Ungültige Endung in \"extensions\": {ext!r}")
        elif ext.startswith("."):
            hint(f"Endung \"{ext}\" ohne Punkt schreiben (wird toleriert)")
    for t in types:
        if not isinstance(t, str) or "." not in t:
            error(f"\"types\" erwartet Uniform Type Identifier wie public.image, nicht {t!r}")
    for h in hosts:
        if not isinstance(h, str) or "/" in h or ":" in h:
            error(f"\"links.hosts\" erwartet nur Domains wie youtube.com, nicht {h!r}")
    for p in patterns:
        try:
            re.compile(p)
        except (re.error, TypeError):
            error(f"Ungültiger regulärer Ausdruck in \"links.patterns\": {p!r}")

    triggers = m.get("triggers")
    if triggers is not None:
        unknown = [t for t in triggers if t not in TRIGGERS]
        if unknown:
            hint(f"Unbekannte \"triggers\" werden ignoriert: {unknown}")
    permissions = m.get("permissions") or []
    for p in permissions:
        if p not in PERMISSIONS:
            error(f"Unbekanntes Recht \"{p}\" (erlaubt: network, run, clipboard): BarDrop lehnt das Plugin ab")
    tools = m.get("tools") or []
    for tool in tools:
        tid = tool.get("id") if isinstance(tool, dict) else None
        if not isinstance(tid, str) or not isinstance(tool.get("name"), str) or not isinstance(tool.get("url"), str):
            error("Jedes Programm in \"tools\" braucht \"id\", \"name\" und \"url\"")
            continue
        if not tool["url"].startswith("https://"):
            error(f"Programm \"{tid}\": \"url\" muss mit https:// beginnen")
        if "checksums" in tool and not str(tool["checksums"]).startswith("https://"):
            error(f"Programm \"{tid}\": \"checksums\" muss mit https:// beginnen")
        if not tool.get("sha256") and not tool.get("checksums"):
            error(f"Programm \"{tid}\": \"sha256\" oder \"checksums\" fehlt")
        if tool.get("sha256") and not re.fullmatch(r"[0-9A-Fa-f]{64}", tool["sha256"]):
            error(f"Programm \"{tid}\": \"sha256\" muss 64 Hex-Zeichen haben")
        if tool["url"].lower().endswith((".zip", ".tar.gz", ".tgz", ".dmg", ".pkg")):
            error(f"Programm \"{tid}\": BarDrop lädt nur einzelne ausführbare Dateien, keine Archive oder Installer")
        if "run" not in permissions:
            error(f"Programm \"{tid}\" lässt sich nur mit dem Recht \"run\" starten")
    if m.get("automaticByDefault") and (({"network", "run"} & set(permissions)) or tools):
        hint("\"automaticByDefault\" gilt nicht für Plugins mit network, run oder tools: der Nutzer schaltet es selbst ein")

    for spec in m.get("settings") or []:
        key = spec.get("key") if isinstance(spec, dict) else None
        if not isinstance(key, str) or spec.get("type") not in SETTING_TYPES:
            error("Jede Einstellung braucht \"key\" und \"type\" (toggle, choice oder text)")
            continue
        localized(spec.get("title"), f"Einstellung \"{key}\": \"title\"", required=True)
        if key == "replaceOriginal":
            error("Der Schlüssel \"replaceOriginal\" ist für BarDrop reserviert")
        if spec["type"] == "choice":
            options = spec.get("options") or []
            if not options:
                error(f"Einstellung \"{key}\": \"choice\" braucht \"options\"")
            values = [o.get("value") for o in options if isinstance(o, dict)]
            if any(not isinstance(v, str) for v in values):
                error(f"Einstellung \"{key}\": jeder \"value\" muss ein Text sein (auch Zahlen in Anführungszeichen)")
            if "default" in spec and spec["default"] not in values:
                error(f"Einstellung \"{key}\": \"default\" ist keine der Möglichkeiten")
        if spec["type"] == "toggle" and "default" in spec and not isinstance(spec["default"], bool):
            error(f"Einstellung \"{key}\": \"default\" muss true oder false sein")


def check_script(text, m):
    if "function run" not in text and not re.search(r"\brun\s*=", text):
        error("Das Skript definiert keine Funktion run(item)")
    for name in sorted(set(re.findall(r"\bbardrop\.(\w+)", text))):
        if name not in API:
            error(f"bardrop.{name} gibt es nicht")
    for word, why in (("setTimeout", "bardrop.sleep(ms) verwenden"), ("require(", "es gibt keine Module"),
                      ("document.", "es gibt kein DOM"), ("new URL(", "es gibt keine URL-Klasse"),
                      ("XMLHttpRequest", "bardrop.fetch verwenden"), ("window.", "es gibt kein window")):
        if word in text:
            error(f"\"{word.rstrip('(.')}\" gibt es in BarDrop-Plugins nicht: {why}")
    if re.search(r"(^|[^.\w])fetch\(", text):
        error("Globales fetch gibt es nicht: bardrop.fetch verwenden")
    if re.search(r"\b(let|const|class)\s+console\b", text):
        error("console ist schon vorhanden; nicht mit let/const neu anlegen")
    perms = set(m.get("permissions") or [])
    for call, perm in (("fetch", "network"), ("download", "network"), ("run", "run"), ("setClipboard", "clipboard")):
        if re.search(rf"\bbardrop\.{call}\(", text) and perm not in perms:
            error(f"bardrop.{call} braucht das Recht \"{perm}\" in \"permissions\"")
    for perm in perms:
        calls = {"network": ("fetch", "download"), "run": ("run",), "clipboard": ("setClipboard",)}[perm] if perm in PERMISSIONS else ()
        if calls and not any(f"bardrop.{c}(" in text for c in calls):
            hint(f"Recht \"{perm}\" wird im Skript nicht verwendet: weglassen, dann fragt BarDrop nicht danach")
    node = shutil.which("node")
    if node:
        with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False, encoding="utf-8") as f:
            f.write(text)
        r = subprocess.run([node, "--check", f.name], capture_output=True, text=True)
        if r.returncode != 0:
            error("Syntaxfehler im Skript:\n" + r.stderr.strip())
    else:
        hint("Node.js nicht gefunden: Syntax des Skripts nicht geprüft")


def load(path):
    """Liefert (Ordner mit manifest.json, Dateinamen dort, temporärer Ordner oder None)."""
    if path.is_dir():
        root = path
        tmp = None
    else:
        if path.stat().st_size > MAX_PACKAGE:
            error("Die .bdrop-Datei ist größer als 5 MB")
        tmp = pathlib.Path(tempfile.mkdtemp())
        try:
            with zipfile.ZipFile(path) as z:
                z.extractall(tmp)
        except zipfile.BadZipFile:
            error("Die Datei ist kein ZIP-Archiv")
            return None, set(), tmp
        root = tmp
        if not (root / "manifest.json").exists():
            inner = [p for p in root.iterdir() if not p.name.startswith(".") and p.name != "__MACOSX"]
            if len(inner) == 1 and (inner[0] / "manifest.json").exists():
                root = inner[0]
    if not (root / "manifest.json").exists():
        error("manifest.json fehlt (direkt im Archiv oder in genau einem Ordner darin)")
        return None, set(), tmp
    files = {p.name for p in root.iterdir() if p.is_file()}
    return root, files, tmp


def pack(folder, target):
    with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as z:
        for p in sorted(folder.rglob("*")):
            if p.is_file() and not p.name.startswith(".") and not p.is_symlink():
                z.write(p, p.relative_to(folder).as_posix())
    if target.stat().st_size > MAX_PACKAGE:
        error("Die erzeugte .bdrop-Datei ist größer als 5 MB")


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if len(args) != 1:
        print(__doc__)
        sys.exit(2)
    path = pathlib.Path(args[0]).resolve()
    root, files, tmp = load(path)
    manifest = {}
    if root:
        try:
            manifest = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as e:
            error(f"manifest.json ist kein gültiges JSON: {e}")
        else:
            check_manifest(manifest, files)
            script = root / str(manifest.get("script", "main.js"))
            if script.is_file():
                data = script.read_bytes()
                if len(data) > MAX_SCRIPT:
                    error("Das Skript ist größer als 1 MB")
                try:
                    check_script(data.decode("utf-8"), manifest)
                except UnicodeDecodeError:
                    error("Das Skript ist nicht in UTF-8 gespeichert")
            for link in root.rglob("*"):
                if link.is_symlink():
                    hint(f"Verweis {link.name} wird beim Import entfernt")
    if "--pack" in sys.argv and root and path.is_dir() and not errors:
        target = path.parent / (path.name + ".bdrop")
        pack(root, target)
        print(f"Gepackt: {target}")
    if tmp:
        shutil.rmtree(tmp, ignore_errors=True)
    for h in hints:
        print(f"Hinweis: {h}")
    for e in errors:
        print(f"Fehler: {e}")
    if errors:
        sys.exit(1)
    print(f"In Ordnung: {manifest.get('id', path.name)} {manifest.get('version', '')}")


if __name__ == "__main__":
    main()
