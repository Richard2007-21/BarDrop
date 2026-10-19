# Plugins für BarDrop

[English](PLUGINS.md) · Deutsch

Plugins ergänzen BarDrop um eigene Schritte: einen Eintrag im Rechtsklick-Menü, eine Aktion in der Aktionsleiste oder etwas, das von selbst läuft, wenn du ein passendes Objekt ablegst. BarDrop bringt selbst kein Plugin mit. Plugins sind aus, bis du sie unter **Einstellungen → Plugins** einschaltest.

## Die .bdrop-Datei

Ein Plugin ist eine einzelne `.bdrop`-Datei. Darin steckt ein ZIP-Archiv mit:

```
manifest.json   was das Plugin ist, wozu es passt und was es darf
main.js         das Skript (JavaScript)
…               weitere Dateien nach Bedarf (Texte, Vorlagen)
```

Die Dateien dürfen auch in genau einem Ordner im Archiv liegen (so entsteht es mit „Komprimieren“ im Finder). Für eine `.bdrop` den Ordner im Finder komprimieren und die `.zip` in `.bdrop` umbenennen, oder:

```sh
ditto -c -k --norsrc --noextattr MeinPlugin MeinPlugin.bdrop
```

Ein Doppelklick auf eine `.bdrop` (oder Einstellungen → Plugins → Plugin importieren) zeigt, was das Plugin tun will, und sein Skript, mit dem Hinweis, dass es nicht aus dem Katalog von BarDrop stammt. Installiert wird erst nach deiner Bestätigung. Ein Plugin darf höchstens 5 MB groß sein, sein Skript höchstens 1 MB.

## manifest.json

Aufbau und Schlüssel stehen ausführlich in der [englischen Fassung](PLUGINS.md#manifestjson). Kurz:

* `id` (eindeutig, umgekehrte Domain), `name`, `version` und `match` sind Pflicht.
* Texte (`name`, `description`, `actionTitle`, `consent`, Titel der Einstellungen) gibt es als `{"en": …, "de": …}` oder als ein Text für beide Sprachen. Fehlt Deutsch, gilt Englisch.
* `icon.symbol` ist der Name eines SF-Symbols, derselben Symbole wie in der App Kurzbefehle, also auf jedem Mac vorhanden. `icon.color` ist die Farbe der Kachel (`#RRGGBB`). BarDrop zeichnet das Symbol weiß auf die farbige Kachel, wie die Symbole seiner Einstellungen. Unbekannte Symbole werden zum Puzzleteil.
* `match`: `types` (Uniform Type Identifier, mit Untertypen: `public.image` passt zu PNG, JPEG, HEIC …), `extensions` (ohne Punkt) und `links` (`hosts` mit Subdomains, `*` für alle Weblinks, `patterns` als reguläre Ausdrücke). Eine passende Regel genügt.
* `triggers`: `menu` (Rechtsklick), `action` (Aktionsleiste), `automatic` (beim Ablegen). Ohne Angabe alle drei.
* `permissions`: `network` (Webseiten und Dateien laden), `run` (Programme ausführen; das heißt vollen Zugriff auf den Mac), `clipboard` (Text in die Zwischenablage). Jedes Recht wird beim ersten Gebrauch erfragt. Ein Recht, das nicht im Manifest steht, kann das Skript nicht nutzen.
* `automaticByDefault` gilt nur für Plugins ohne `network`, `run` und `tools`. Für alle anderen schaltet der Nutzer „Automatisch beim Ablegen“ selbst ein und wird dabei gleich nach den Rechten gefragt.
* `tools`: Programme, die BarDrop erst nach Rückfrage lädt (nur `https`, mit `sha256` oder einer Prüfsummenliste unter `checksums`). BarDrop liefert nie Programme Dritter mit. Was nicht zur Prüfsumme passt, wird gelöscht.
* `settings`: Schalter (`toggle`), Auswahl (`choice`) und Textfelder (`text`), die unter dem Plugin in den Einstellungen erscheinen. Das Skript liest sie über `bardrop.settings`.
* `canReplaceOriginal`: zeigt den Schalter „Original ersetzen“ (standardmäßig aus). Die Originaldatei wird dabei nie gelöscht, ⌘Z holt sie zurück in die Ablage.
* `consent`: ein Hinweis, dem man einmal zustimmen muss, bevor das Plugin läuft.

## Das Skript

Das Skript enthält `run(item)`, gern auch `async`. Endet es ohne Fehler, wird **alles im Ordner `bardrop.outputDirectory` zu neuen Objekten direkt neben dem Original**, sofort mit Vorschau zu sehen. Versteckte Dateien und halbe Downloads bleiben weg. Wirft das Skript einen Fehler, kommt nichts dazu, und BarDrop zeigt den Fehler.

`item` enthält `kind` (`file`, `folder`, `link`), `path`, `name`, `extension`, `type`, bei Links `url` und bei Dateien `size`.

`bardrop` bietet: `writeFile`, `createLink`, `readFile` (nur das Objekt selbst, den Ausgabeordner und die eigenen Dateien), `progress`, `notify`, `isCancelled`, `sleep`, `log`, `fetch` und `download` (Recht `network`), `run` (Recht `run`) und `setClipboard` (Recht `clipboard`), dazu `settings`, `language`, `appVersion` und `plugin`. Die Tabelle mit allen Einzelheiten steht in der [englischen Fassung](PLUGINS.md#the-script).

Jedes Plugin läuft in einem eigenen, kurzlebigen JavaScriptCore-Kontext. Höchstens drei laufen gleichzeitig, weitere warten. Es gibt die Sprache JavaScript selbst, aber keine Schnittstellen von Browser oder Node (kein DOM, kein `URL`, kein `setTimeout`, kein `require`). Solange ein Plugin nicht benutzt wird, läuft davon nichts.

## In BarDrop

* **Rechtsklick:** Passende Plugins stehen unter den gewohnten Einträgen, nach einer Trennlinie. Bis zu drei direkt, ab vier im Untermenü „Plugins“.
* **Aktionsleiste:** Einstellungen → Plugins → ein Plugin → „In der Aktionsleiste“, oder Einstellungen → Aktionen → Aktion hinzufügen.
* **Automatisch beim Ablegen:** je Plugin, standardmäßig aus. Passen mehrere automatische Plugins zum selben Objekt, läuft nur das erste der Liste; die Pfeile in den Einstellungen ändern die Reihenfolge. Wo sonst „1 von 3 ausgewählt“ steht, erscheint kurz, welches Plugin aktiv ist.
* **Platzhalter:** Solange ein Plugin läuft, steht direkt neben dem Original ein Platzhalter mit einem Ring. Sein Rechtsklick-Menü zeigt den Fortschritt in Prozent und kann anhalten, fortsetzen und abbrechen. Angehalten stehen laufende Programme und Downloads still; beim Beenden von BarDrop werden sie abgebrochen.
* **Rechte** werden beim ersten Gebrauch erfragt, bei automatischen Plugins schon beim Einschalten von „Automatisch beim Ablegen“. Wer das Skript eines Plugins bearbeitet (Einstellungen → Plugins → Skript → Im Editor öffnen), setzt seine Rechte zurück. Standard-Plugins lassen sich weder bearbeiten noch entfernen, nur ausschalten.

## Katalog

Der Katalog ist [`Plugins/index.json`](../Plugins/index.json) in diesem Repository und nennt geprüfte Plugins. `standard: true` heißt: wird beim Einschalten der Plugins automatisch installiert (ausgeschaltet), still aktualisiert und lässt sich nicht entfernen. `removed: true` entfernt ein Plugin beim nächsten Abgleich, auch ein Standard-Plugin. Alle anderen Einträge erscheinen unter „Mehr im Katalog“.

BarDrop fragt den Katalog höchstens einmal am Tag ab, und nur, solange Plugins eingeschaltet sind. Einreichen per Pull Request mit der `.bdrop` und ihrem Eintrag; jedes Plugin wird vor dem Aufnehmen geprüft. Der Katalog ist vorerst leer.
