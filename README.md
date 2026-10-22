# BarDrop-Galerie

Dieser Zweig enthält nur die Plugin-Galerie von BarDrop. Die App liest `index.json` von hier:

    https://raw.githubusercontent.com/zzuuuiii/BarDrop/plugin-katalog/index.json

Ein Push auf diesen Zweig baut **kein** Release der App.

## Aufbau

    index.json                         Liste aller Plugins (schema 1)
    plugins/<id>/<id>-<version>.bdrop  die Plugins selbst, je eines in der aktuellen Version

## Plugin eintragen oder aktualisieren

Im Hauptzweig der App, nicht hier von Hand:

    python3 scripts/publish_plugin.py MeinPlugin/ --category images
    python3 scripts/publish_plugin.py MeinPlugin/ --push

Das Skript prüft das Plugin, packt es, rechnet die Prüfsumme und schreibt den Eintrag.
Kategorien: `images`, `links`, `documents`, `text`, `media`, `files`, `other`.

## Zurückziehen

    python3 scripts/publish_plugin.py --remove io.github.name.plugin --push

Der Eintrag bleibt mit `"removed": true` stehen, damit installierte Fassungen davon erfahren.
Das ganze Format beschreibt `docs/PLUGINS.md`, Abschnitt Katalog.
