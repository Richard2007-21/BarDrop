# Plugins für BarDrop: genaue Referenz

[English](PLUGINS.md) · Deutsch

Diese Datei beschreibt das Plugin-System von BarDrop vollständig und genau so, wie der Code es umsetzt (Stand 1.31.0 Beta 4). Was hier nicht steht, gibt es nicht. Wer ein Plugin schreibt, hält sich an diese Datei und prüft das Ergebnis mit `scripts/check_plugin.py` (Abschnitt 11).

Quellcode: `Sources/BarDrop/Plugins/`. Ändert sich dort etwas, wird diese Datei, ihre englische Fassung und `scripts/check_plugin.py` im selben Commit angepasst.

---

## 1. Überblick

* Ein Plugin ist **eine Datei mit der Endung `.bdrop`**. Darin steckt ein ZIP-Archiv mit `manifest.json` und einem JavaScript-Skript.
* BarDrop **bringt kein Plugin mit**. Plugins sind aus, bis der Nutzer unter Einstellungen → Plugins „Plugins verwenden“ einschaltet, und jedes Plugin ist danach einzeln aus.
* Ein Plugin bekommt **ein Objekt der Ablage** (Datei, Ordner oder Link). Alles, was es in seinen **Ausgabeordner** schreibt, wird zu **neuen Objekten direkt neben dem Original**.
* Gestartet wird ein Plugin auf drei Wegen: **Rechtsklick**, **Aktionsleiste** oder **automatisch beim Ablegen**.
* Das Skript läuft in **JavaScriptCore**. Es sieht nur das Objekt `bardrop`. Internet, Programme und Zwischenablage gibt es nur mit **Rechten**, die BarDrop beim ersten Gebrauch erfragt.

## 2. Die .bdrop-Datei

| Regel | Wert |
| --- | --- |
| Format | ZIP-Archiv, Endung `.bdrop` |
| Größe | höchstens 5 MB (5 242 880 Byte) |
| Aufbau | `manifest.json` direkt im Archiv **oder** in genau einem Ordner darin (versteckte Einträge und `__MACOSX` zählen nicht) |
| Skript | die Datei, die `script` im Manifest nennt; höchstens 1 MB; UTF-8 |
| Weitere Dateien | erlaubt (Texte, Vorlagen); das Skript liest sie mit `bardrop.readFile` |
| Symbolische Verweise | werden beim Entpacken gelöscht |

Entpackt wird mit `/usr/bin/ditto`. Installiert liegt ein Plugin in `~/Library/Application Support/BarDrop/Plugins/<id>/`. Der Ordnername muss der `id` entsprechen.

**Erzeugen:** `python3 scripts/check_plugin.py MeinPlugin/ --pack` prüft den Ordner und erzeugt `MeinPlugin.bdrop`. Von Hand geht es mit `ditto -c -k --norsrc --noextattr MeinPlugin MeinPlugin.bdrop` oder mit „Komprimieren“ im Finder und anschließendem Umbenennen von `.zip` in `.bdrop`.

**Installieren:** Doppelklick auf die Datei oder Einstellungen → Plugins → Plugin importieren. BarDrop zeigt Name, Rechte, nachzuladende Programme und das Skript, mit dem Hinweis, dass das Plugin nicht aus dem Katalog stammt. Installiert wird erst nach „Installieren“. Ist ein Plugin mit derselben `id` schon da, heißt der Knopf „Aktualisieren“. Ein Standard-Plugin aus dem Katalog lässt sich nicht durch einen Import ersetzen. Nach dem Import schaltet BarDrop „Plugins verwenden“ ein; das Plugin selbst bleibt aus. Lässt sich ein installiertes Plugin nicht mehr lesen (etwa nach dem Bearbeiten), steht es mit der Fehlermeldung in der Liste, mit „Im Finder zeigen“ und, außer bei Standard-Plugins, „Entfernen“.

## 3. manifest.json

Unbekannte Schlüssel werden ignoriert. Ein Schlüssel mit falschem Typ (z. B. Zahl statt Text) macht das ganze Manifest unlesbar.

### 3.1 Alle Schlüssel

| Schlüssel | Typ | Pflicht | Bedeutung |
| --- | --- | --- | --- |
| `schema` | Zahl | nein | Muss `1` sein. Fehlt er, gilt 1. |
| `id` | Text | ja | Eindeutige Kennung, z. B. `io.github.name.mein-plugin`. Muster: `^[A-Za-z0-9][A-Za-z0-9-]*(\.[A-Za-z0-9][A-Za-z0-9-]*)+$`, also mindestens ein Punkt, nur Buchstaben, Ziffern, Bindestriche; höchstens 120 Zeichen. Bleibt bei Updates gleich. |
| `name` | Text (3.2) | ja | Name in Einstellungen und Dialogen. Der englische Text darf nicht leer sein. |
| `description` | Text (3.2) | nein | Eine Zeile unter dem Namen in den Einstellungen und Hilfetext der Aktion. |
| `version` | Text | ja | `1`, `1.2` oder `1.2.3`, als Text in Anführungszeichen. Muster `^\d+(\.\d+){0,2}$`. Keine Beta-Zusätze. |
| `author` | Text | nein | Wird neben der Version angezeigt. |
| `homepage` | Text | nein | Wird gespeichert, aber derzeit nicht angezeigt. |
| `icon` | Objekt | nein | `{"symbol": "…", "color": "#RRGGBB"}`, siehe 3.4. |
| `actionTitle` | Text (3.2) | nein | Titel im Rechtsklick und in der Aktionsleiste. Fehlt er, gilt `name`. |
| `minAppVersion` | Text | nein | Älteste BarDrop-Version, z. B. `"1.31.0"`. Verglichen wird ohne Beta-Zusatz: 1.31.0 Beta 2 zählt als 1.31.0. Ist BarDrop älter, wird das Plugin abgelehnt. Empfehlung: immer setzen. |
| `script` | Text | nein | Dateiname des Skripts, Standard `"main.js"`. Muss auf `.js` enden, darf keinen `/` enthalten und nicht mit `.` beginnen. |
| `match` | Objekt | ja | Wofür das Plugin zuständig ist, siehe 4. |
| `triggers` | Liste | nein | Teilmenge von `"menu"`, `"action"`, `"automatic"`. Fehlt der Schlüssel, gelten alle drei. Unbekannte Werte werden still übergangen. Eine leere Liste `[]` heißt: über keinen Weg startbar. |
| `automaticByDefault` | Wahrheitswert | nein | „Automatisch beim Ablegen“ ist von Anfang an an. Gilt **nur**, wenn `triggers` `automatic` erlaubt und das Plugin weder `network` noch `run` noch `tools` hat. |
| `permissions` | Liste | nein | Teilmenge von `"network"`, `"run"`, `"clipboard"`, siehe 6. Ein **unbekannter** Wert lässt das ganze Plugin ablehnen. |
| `tools` | Liste | nein | Programme, die BarDrop nachlädt, siehe 7. Verlangt das Recht `run`. |
| `settings` | Liste | nein | Einstellungen des Plugins, siehe 3.3. |
| `canReplaceOriginal` | Wahrheitswert | nein | Zeigt den Schalter „Original ersetzen“ (Standard aus), siehe 8. |
| `consent` | Text (3.2) | nein | Hinweis, dem der Nutzer **einmal** zustimmen muss, bevor das Plugin eingeschaltet werden oder laufen kann. |

### 3.2 Texte in zwei Sprachen

Überall, wo „Text (3.2)“ steht, gibt es zwei Formen:

```json
"name": "Gilt für beide Sprachen"
"name": { "en": "English text", "de": "Deutscher Text" }
```

Regel: Ist die App auf Deutsch, gilt `de`, sonst `en`. Fehlt die gewünschte Sprache, gilt `en`. Fehlt auch `en`, gilt der alphabetisch erste vorhandene Eintrag. Andere Sprachschlüssel werden nicht verwendet.

### 3.3 settings

```json
"settings": [
  { "key": "format", "type": "choice", "title": { "en": "Format", "de": "Format" },
    "info": { "en": "Shown behind the (i)", "de": "Erscheint hinter dem (i)" },
    "default": "png",
    "options": [ { "value": "png", "title": "PNG" }, { "value": "jpg", "title": "JPEG" } ] },
  { "key": "keepName", "type": "toggle", "title": { "en": "Keep name", "de": "Namen behalten" }, "default": true },
  { "key": "prefix", "type": "text", "title": { "en": "Prefix", "de": "Präfix" }, "default": "" }
]
```

| Schlüssel | Pflicht | Bedeutung |
| --- | --- | --- |
| `key` | ja | Name des Werts in `bardrop.settings`. `replaceOriginal` ist reserviert. |
| `type` | ja | `toggle` (Schalter), `choice` (Auswahl), `text` (Textfeld). |
| `title` | ja | Text (3.2). |
| `info` | nein | Text (3.2), erscheint hinter einem (i). |
| `default` | nein | `toggle`: `true`/`false` (Standard `false`). `choice`: einer der `value` (Standard: die erste Möglichkeit). `text`: Text (Standard leer). |
| `options` | bei `choice` | Liste aus `{"value": "Text", "title": Text (3.2)}`. `value` ist **immer Text**, auch für Zahlen (`"1080"`, nicht `1080`). |

Darstellung wie die übrigen Einstellungen von BarDrop: Zwei Möglichkeiten und drei kurze Möglichkeiten erscheinen als Umschalter in der Zeile, sonst als Menü.

Im Skript: `bardrop.settings.<key>` liefert `true`/`false`, Texte als Text. `bardrop.settings.replaceOriginal` sagt, ob „Original ersetzen“ an ist.

### 3.4 icon

* `symbol`: Name eines **SF Symbols**, also eines der Systemsymbole, die auch Kurzbefehle verwendet und die auf jedem Mac vorhanden sind (z. B. `arrow.down.circle.fill`, `photo`, `link`, `doc.text`). Namen findet man in Apples App „SF Symbols“. Gibt es den Namen auf dem Mac nicht, zeigt BarDrop ein Puzzleteil.
* `color`: Farbe der Kachel als `#RRGGBB` (das `#` darf fehlen). Ungültig oder fehlend: grau.

BarDrop zeichnet das Symbol immer **weiß auf der farbigen Kachel mit leichtem Verlauf**, wie die Symbole der Einstellungen; im Rechtsklick in 16 pt, in der Aktionsleiste im Stil der Aktion „Teilen“. Eigene Bilddateien als Symbol gibt es nicht.

## 4. match: wofür ein Plugin zuständig ist

```json
"match": {
  "types": ["public.image", "com.adobe.pdf"],
  "extensions": ["txt", "md"],
  "links": { "hosts": ["example.com"], "patterns": ["^https://example\\.com/watch\\?"] }
}
```

Mindestens **eine** der vier Listen muss Einträge haben. Ein Objekt passt, wenn **irgendeine** Regel passt.

**Was BarDrop über ein Objekt weiß:**

| Objekt in der Ablage | `kind` | Typ | Endung |
| --- | --- | --- | --- |
| `.webloc`-Datei mit lesbarer Adresse (`URL` in der Property List) | `link` | `com.apple.web-internet-location` | `webloc` |
| Ordner (kein Paket) | `folder` | `public.folder` | die des Ordners, meist leer |
| alles andere, auch Pakete wie `.app` | `file` | aus der Endung, sonst aus der Datei | die Endung, klein geschrieben |

Links legt BarDrop selbst immer als `.webloc` ab.

**Regeln:**

* `extensions`: Vergleich ohne Groß- und Kleinschreibung; führende Punkte werden entfernt (`".PNG"` = `png`).
* `types`: Uniform Type Identifier. Ein Objekt passt auch, wenn sein Typ davon **abgeleitet** ist: `public.image` passt zu PNG, JPEG, HEIC usw., `public.movie` zu MP4 und MOV, `public.text` zu TXT, Markdown, Quelltext. Unbekannte Bezeichner werden übergangen.
* `links.hosts`: gilt **nur für Links**. `example.com` passt zu `example.com` und jeder Subdomain (`www.example.com`, `m.example.com`), aber nicht zu `notexample.com`. `*` passt zu jedem Link mit `http` oder `https`. Nur die Domain angeben, ohne `https://`, ohne Pfad, ohne Port.
* `links.patterns`: gilt **nur für Links**. Reguläre Ausdrücke (ICU-Syntax von macOS), geprüft auf die ganze Adresse, **ohne** Groß- und Kleinschreibung; ein Treffer irgendwo genügt. Mit `^` am Anfang verankern. In JSON jeden `\` doppelt schreiben.
* Ein Link passt außerdem auf `extensions: ["webloc"]`.

**Links aus dem Browser:** Wird ein Link zusammen mit einem Vorschaubild gezogen (z. B. ein Video aus einer Webseite), übernimmt BarDrop normalerweise das Bild. Passt der Link aber zu `links` eines **eingeschalteten** Plugins, übernimmt BarDrop den Link als `.webloc`. Das gilt nur für `links.hosts` und `links.patterns`.

## 5. Auslöser

**Rechtsklick (`menu`):** Passende, eingeschaltete Plugins erscheinen unter den gewohnten Einträgen, nach einer Trennlinie, mit ihrem Symbol und `actionTitle`. Bis zu drei direkt, ab vier gesammelt im Untermenü „Plugins“. Bei mehreren ausgewählten Objekten erscheint ein Plugin, wenn es zu mindestens einem passt; es läuft dann für jedes passende Objekt einmal.

**Aktionsleiste (`action`):** Einstellungen → Plugins → Plugin → „In der Aktionsleiste“ oder Einstellungen → Aktionen → Aktion hinzufügen. Die Aktion ist nur zu sehen, solange das Plugin eingeschaltet ist. Klick: läuft für die ausgewählten Objekte. Darauf ziehen: läuft für die gezogenen Objekte. Passt nichts, gibt es einen Warnton.

**Automatisch beim Ablegen (`automatic`):** Je Plugin ein Schalter, standardmäßig aus (Ausnahme 3.1 `automaticByDefault`). Es zählt nur, was der Nutzer selbst in die Ablage legt: Ziehen und ⌘V. Nicht: Bildschirmfotos, Ergebnisse von Aktionen und Plugins, Widerrufen, die Einführung. Für jedes abgelegte Objekt läuft **höchstens ein** Plugin: das erste in der Liste der Einstellungen, das eingeschaltet ist, automatisch läuft und passt. Die Reihenfolge ändern die Pfeile in den Details eines Plugins. Oben in der Ablage, wo sonst „1 von 3 ausgewählt“ steht, erscheint kurz „Plugin … aktiv“.

Ein automatisches Plugin läuft nur, wenn es **ohne Rückfrage** laufen kann: Zustimmung (`consent`) gegeben, alle Rechte aus `permissions` erteilt, alle Programme aus `tools` erlaubt. Beim Einschalten von „Automatisch beim Ablegen“ fragt BarDrop all das ab. Fehlt nur die Erlaubnis für ein Programm (Plugins aus Beta 1), fragt BarDrop beim nächsten Ablegen einmal nach. Fehlt anderes, läuft es nicht, und oben steht „… braucht eine Erlaubnis in den Einstellungen“. Während eines automatischen Laufs fragt das Plugin nie.

**Gleichzeitig:** Höchstens drei Plugins laufen gleichzeitig, weitere warten in der Reihenfolge, in der sie gestartet wurden (ihr Platzhalter zeigt eine Uhr und „Wartet“). Dasselbe Plugin startet für dieselbe Datei nicht ein zweites Mal, solange es noch läuft; oben erscheint dann „… läuft schon“.

## 6. Rechte

| Recht | erlaubt | Dialog |
| --- | --- | --- |
| `network` | `bardrop.fetch`, `bardrop.download` | „Zugriff aufs Internet“ |
| `run` | `bardrop.run`, also auch `tools` | „Programme ausführen“, als Warnung: vollen Zugriff auf den Mac |
| `clipboard` | `bardrop.setClipboard` | „Zwischenablage“ |

* Ein Aufruf ohne das Recht in `permissions` scheitert **sofort** mit dem Fehler `Permission “…” is missing in manifest.json`, ohne Frage.
* Steht das Recht im Manifest, ist aber noch nicht erteilt: Bei Rechtsklick und Aktionsleiste fragt BarDrop **einmal**. „Nicht erlauben“ lässt den Aufruf scheitern (`fetch`, `download`, `run` werden abgelehnt, `setClipboard` tut nichts) und fragt beim nächsten Lauf erneut. Bei automatischen Läufen fragt BarDrop nie.
* Erteilte Rechte gelten für **genau diesen Code**: eine SHA-256-Prüfsumme über `manifest.json` und das Skript. Jede Änderung an einer der beiden Dateien setzt alle Rechte zurück. Aktualisierungen aus dem Katalog behalten Rechte, die das Plugin weiter braucht.
* Der Dialog fragt „Darf „…“ auf das Internet zugreifen?“, „Darf „…“ Programme ausführen?“ bzw. „Darf „…“ die Zwischenablage verwenden?“, mit „Erlauben“ und „Nicht erlauben“.
* Einstellungen → Plugins → Plugin → Rechte zeigt je Recht „erlaubt“ oder „fragt zuerst“. „Erlauben“ fragt sofort nach allen fehlenden Rechten und Programmen (etwa nachdem ein bearbeitetes Skript seine Rechte verloren hat), „Zurücksetzen“ nimmt alle Rechte zurück.
* Es gibt **keine Sandbox von macOS** um Plugins. Das Skript selbst kann ohne Rechte nur die Aufrufe aus 9 nutzen. Ein mit `run` gestartetes Programm hat aber die vollen Rechte des Benutzers.

## 7. tools: nachgeladene Programme

BarDrop liefert nie Programme Dritter mit. Ein Plugin kann Programme nennen, die BarDrop beim ersten Gebrauch lädt:

```json
"tools": [
  { "id": "mytool", "name": "My Tool",
    "url": "https://example.com/releases/1.0/mytool_macos",
    "sha256": "64 Hex-Zeichen",
    "license": "MIT", "homepage": "https://example.com" }
]
```

| Schlüssel | Pflicht | Bedeutung |
| --- | --- | --- |
| `id` | ja | Name, unter dem das Skript es startet: `bardrop.run("mytool", […])`. Gilt für alle Plugins gemeinsam: Gleiche `id` heißt gleiche Datei. |
| `name` | ja | Anzeige im Dialog. |
| `url` | ja | `https://`, zeigt auf **eine einzelne ausführbare Datei** für macOS. Archive (ZIP, DMG, PKG) werden **nicht** entpackt. Umleitungen werden befolgt. |
| `sha256` | eins von beiden | Prüfsumme der Datei. |
| `checksums` | eins von beiden | `https://`-Adresse einer Prüfsummenliste des Herausgebers. Gesucht wird die Zeile `<64 Hex-Zeichen> <Dateiname>` oder `<…> *<Dateiname>`; Dateiname ist der letzte Teil von `url`. Für Adressen auf „latest“. |
| `license` | nein | Erscheint im Dialog. |
| `homepage` | nein | Wird gespeichert. |
| `refreshDays` | nein | Nach so vielen Tagen lädt BarDrop die Datei beim nächsten Gebrauch neu, ohne erneut zu fragen. Ohne Angabe nie. |

Ablauf: Fehlt die Datei, fragt BarDrop („… herunterladen?“ mit Herkunft, Lizenz und dem Hinweis, dass das Programm mit denselben Rechten läuft wie das Plugin). Nach „Laden“ wird geladen (der Platzhalter zeigt „Lädt …“), die Prüfsumme verglichen (passt sie nicht, wird die Datei gelöscht und der Aufruf scheitert), die Datei ausführbar gemacht (755) und die Quarantäne entfernt. Ablage: `~/Library/Application Support/BarDrop/Tools/<id>/<id>` mit `meta.json` daneben. Die Erlaubnis wird je Plugin gespeichert und gilt danach auch für automatische Läufe. Laden zwei Läufe gleichzeitig, lädt nur einer, der andere wartet. Beim Entfernen eines Plugins bleiben geladene Programme liegen.

## 8. Ergebnis

* `run(item)` endet ohne Fehler (auch ein `async`-`run`, dessen Versprechen erfüllt wird): **Erfolg**. Der Rückgabewert wird nicht verwendet.
* Wirft `run` einen Fehler oder wird das Versprechen abgelehnt: **Fehlschlag**. Es kommt nichts in die Ablage. Bei Rechtsklick und Aktionsleiste zeigt BarDrop die Meldung in einem Dialog: `error.message`, bei Fehlern im Code (`TypeError`, `ReferenceError`, `SyntaxError` …) mit dem Typ davor und Datei und Zeile dahinter (`TypeError: … (main.js:12)`); eine eigene Meldung mit `throw new Error(…)` erscheint genau so, wie sie ist; bei automatischen Läufen nur kurz „… hat nicht geklappt“. In beiden Fällen steht die Meldung in den Einstellungen unter „Letzter Fehler“ (bis zum Beenden).
* Bei Erfolg werden alle **Einträge der obersten Ebene** im Ausgabeordner übernommen, alphabetisch sortiert, **Ordner eingeschlossen**. Ausgenommen sind Namen, die mit `.` beginnen, und die Endungen `part`, `ytdl`, `tmp`, `download`, `crdownload`. Ist der Ordner leer, verschwindet nur der Platzhalter.
* Die Dateien werden in den Speicher von BarDrop verschoben und **direkt hinter dem Original** eingefügt (in der Reihenfolge, die der Nutzer sieht; liegt das Original in einem Stapel, hinter ihm im Stapel). Sie erscheinen sofort mit Vorschau und sind danach ausgewählt. Liegt das Original nicht mehr in der Ablage, kommen sie dazu wie neu abgelegte Objekte.
* „Original ersetzen“ (nur mit `canReplaceOriginal`, Schalter des Nutzers, beim Start des Laufs festgelegt): Solange das Plugin läuft, steht sein Platzhalter **an der Stelle des Originals**, das Original selbst ist nicht zu sehen. Danach steht das Ergebnis genau dort, ohne Überblenden; das Original ist **aus der Ablage** genommen, nie gelöscht, ⌘Z holt es zurück. Scheitert der Lauf oder wird er abgebrochen, ist das Original wieder zu sehen.

**Platzhalter:** Während ein Plugin läuft, steht neben dem Original (bei „Original ersetzen“ an seiner Stelle) ein Ring mit dem Symbol des Plugins und dem Namen (oder dem `label` aus `bardrop.progress`). Ohne Fortschritt dreht ein kurzer Bogen, mit Fortschritt füllt sich der Ring. Rechtsklick: Fortschritt in Prozent (läuft im offenen Menü mit), „Anhalten“ bzw. „Fortsetzen“, „Abbrechen“. Wartet ein Plugin noch, gibt es nur „Abbrechen“.

* **Anhalten:** gestartete Programme und alle Programme, die diese selbst gestartet haben, bekommen `SIGSTOP`, Downloads pausieren. Das Skript selbst und `bardrop.sleep` laufen weiter.
* **Abbrechen:** gestartete Programme und ihre Unterprogramme bekommen `SIGTERM`, Anfragen werden abgebrochen, das Ergebnis wird verworfen.
* Beim Beenden von BarDrop werden laufende Plugins abgebrochen.

## 9. Das Skript

### 9.1 Umgebung

* JavaScriptCore von macOS, also die Sprache JavaScript mit `async`/`await`, `Promise`, `JSON`, `RegExp`, `Map`, `Set` usw.
* **Nicht vorhanden:** DOM, `window`, `URL`, `URLSearchParams`, `setTimeout`/`setInterval` (statt dessen `bardrop.sleep`), globales `fetch` (statt dessen `bardrop.fetch`), `XMLHttpRequest`, `require`, `import`, Node-Module, Dateizugriff außer über `bardrop`.
* `console.log`, `console.info`, `console.warn`, `console.error` gibt es; sie schreiben wie `bardrop.log`. `console` nicht mit `let`/`const` neu anlegen.
* Jeder Lauf hat einen **eigenen, frischen Kontext**: Globale Variablen überleben keinen Lauf. Dauerhaftes gibt es nur über `settings`.
* Das Skript wird zuerst einmal ganz ausgeführt (globale Definitionen), dann wird `run(item)` aufgerufen.
* Ein Fehler beim ersten Ausführen (z. B. Syntaxfehler) ist ein Fehlschlag. Fehlt `run`, ebenfalls („Im Skript fehlt die Funktion run“).
* Endlosschleifen lassen sich nicht hart stoppen: „Abbrechen“ entfernt den Platzhalter, das Skript läuft im Hintergrund weiter, bis BarDrop beendet wird.

### 9.2 item

| Feld | Typ | Inhalt |
| --- | --- | --- |
| `kind` | Text | `"file"`, `"folder"` oder `"link"` |
| `path` | Text | Pfad der Datei in der Ablage (bei Links die `.webloc`) |
| `name` | Text | Dateiname mit Endung; bei Links der Name ohne `.webloc` |
| `extension` | Text | Endung, klein geschrieben, ohne Punkt |
| `type` | Text | Uniform Type Identifier, `""` wenn unbekannt |
| `url` | Text | nur bei Links: die Adresse |
| `size` | Zahl | Größe in Byte, nicht bei Ordnern |

### 9.3 bardrop

Alle Aufrufe mit `await` liefern ein Versprechen.

| Aufruf | Recht | Ergebnis und Regeln |
| --- | --- | --- |
| `bardrop.outputDirectory` | | Pfad des Ausgabeordners (Text). Dort liegt am Ende das Ergebnis. |
| `bardrop.writeFile(name, text)` | | Schreibt `text` als UTF-8 in den Ausgabeordner (andere Werte werden wie mit `String()` zu Text, Objekte also zu `[object Object]`: vorher `JSON.stringify` verwenden). `name` muss Text sein, `text` darf nicht `undefined` oder `null` sein, sonst Fehler. Liefert den Pfad. Der Name wird bereinigt (siehe 9.4); gibt es ihn schon, heißt die Datei `Name 2.txt` usw. |
| `bardrop.createLink(url, title)` | | Legt `<title>.webloc` im Ausgabeordner an (ohne `title`: die Domain). `url` braucht ein Schema (`https:`). Liefert den Pfad. Ungültige Adresse: Fehler. |
| `bardrop.readFile(path)` | | Liest eine Datei als Text (UTF-8, ungültige Bytes werden ersetzt), höchstens 20 MB. Ein Pfad ohne `/` am Anfang gilt relativ zum Ausgabeordner. Erlaubt nur: `item.path` selbst, Dateien im Ausgabeordner, Dateien im eigenen Plugin-Ordner. Sonst Fehler. Binärdaten lassen sich so nicht lesen; dafür `bardrop.run`. |
| `bardrop.progress(anteil, label)` | | `anteil` 0 bis 1 (wird begrenzt); keine Zahl (z. B. `null`) heißt „ohne Fortschritt“. `label` optional, höchstens 60 Zeichen, ersetzt den Namen unter dem Platzhalter. Die Anzeige erneuert sich höchstens alle 100 ms. |
| `bardrop.notify(text)` | | Kurze Meldung oben in der Ablage, höchstens 80 Zeichen, etwa 2 Sekunden. |
| `bardrop.isCancelled()` | | `true`, wenn der Nutzer abgebrochen hat. In langen Schleifen abfragen. |
| `await bardrop.sleep(ms)` | | Wartet `ms` Millisekunden (0 bis 3 600 000). |
| `bardrop.log(text)` | | Zeile im Diagnoseprotokoll (nur Beta-Versionen mit eingeschaltetem Protokoll), höchstens 300 Zeichen. |
| `await bardrop.fetch(url, options)` | `network` | `options` optional: `method` (Text), `headers` (Objekt), `body` (Text). Nur `http`/`https`, 60 s Zeitlimit, Kennung `BarDrop/<Version>`. Liefert `{status, url, headers, text}`; `headers` mit klein geschriebenen Namen, `text` höchstens 20 MB. Abgelehnt wird nur bei Netzwerkfehlern, **nicht** bei Status 404 oder 500: `status` selbst prüfen. |
| `await bardrop.download(url, options)` | `network` | Lädt in den Ausgabeordner, mit Fortschritt am Platzhalter. `options` optional: `name`, `method`, `headers`. Dateiname: `name`, sonst der vom Server vorgeschlagene, sonst der letzte Teil der Adresse (bereinigt, 9.4). Liefert den Pfad. Abgelehnt bei Netzwerkfehler oder Status außerhalb 200 bis 299. |
| `await bardrop.run(befehl, argumente, options)` | `run` | Startet ein Programm und wartet, bis es endet. `befehl`: eine `id` aus `tools`, ein absoluter Pfad oder ein Name, gesucht in `/usr/bin`, `/bin`, `/usr/sbin`, `/sbin`, `/opt/homebrew/bin`, `/usr/local/bin`. `argumente`: Liste, jedes Element wird zu Text; es gibt **keine Shell** (keine Platzhalter, keine Umleitungen; dafür `"/bin/sh", ["-c", "…"]`). Arbeitsordner ist der Ausgabeordner. Umgebung: die von BarDrop, dazu `PATH` = Tools-Ordner und die Suchorte oben, `BARDROP_OUTPUT` = Ausgabeordner. Keine Eingabe (stdin leer). `options.onOutput(zeile)` wird für jede Zeile von stdout und stderr aufgerufen, beide getrennt zerlegt; Zeilen enden an `\n` **und** `\r`, leere Zeilen fallen weg, Zeilen über 64 KB werden geteilt. Alle Zeilen kommen an, bevor `run` sein Ergebnis liefert. Ein Fehler in `onOutput` beendet den ganzen Lauf mit diesem Fehler. Liefert `{code, stdout, stderr}` (je höchstens 1 MB). Ein Code ungleich 0 wird **nicht** abgelehnt: `code` selbst prüfen. Abgelehnt wird, wenn das Programm nicht gefunden wird, nicht starten kann, das Recht fehlt oder abgebrochen wurde. |
| `bardrop.setClipboard(text)` | `clipboard` | Legt Text in die Zwischenablage. |
| `bardrop.settings` | | Werte der Einstellungen (3.3) und `replaceOriginal`. |
| `bardrop.language` | | `"de"` oder `"en"`, wie die App. |
| `bardrop.appVersion` | | z. B. `"1.31.0-beta.2"`. |
| `bardrop.plugin` | | `{id, version}`. |

### 9.4 Dateinamen

Für `writeFile`, `createLink` und `download` gilt: nur der letzte Teil eines Pfads zählt; `/` und `:` werden zu `-`, Zeilenumbrüche zu Leerzeichen; Leerzeichen am Rand fallen weg; führende Punkte werden entfernt; höchstens 80 Zeichen; leer wird zu „Item“ bzw. „Objekt“. Programme, die selbst in den Ausgabeordner schreiben, sind davon nicht betroffen.

## 10. Katalog

Der Katalog ist `Plugins/index.json` in diesem Repository (`https://raw.githubusercontent.com/zzuuuiii/BarDrop/main/Plugins/index.json`). Er ist vorerst leer.

```json
{
  "schema": 1,
  "plugins": [
    { "id": "io.github.name.plugin", "version": "1.0.0",
      "name": { "en": "Name", "de": "Name" },
      "description": { "en": "…", "de": "…" },
      "icon": { "symbol": "link", "color": "#34C759" },
      "url": "https://raw.githubusercontent.com/zzuuuiii/BarDrop/main/Plugins/plugin.bdrop",
      "sha256": "Prüfsumme der .bdrop",
      "standard": false, "removed": false, "minAppVersion": "1.31.0" }
  ]
}
```

* Abfrage höchstens einmal am Tag, nur bei eingeschalteten Plugins; beim Einschalten sofort.
* `standard: true`: wird automatisch installiert (ausgeschaltet), still aktualisiert, sobald `version` höher ist, lässt sich weder bearbeiten noch entfernen. Ohne Internet erscheint es als „Nicht geladen“ mit „Erneut versuchen“.
* `removed: true`: wird beim nächsten Abgleich entfernt, auch als Standard-Plugin.
* Andere Einträge erscheinen unter „Mehr im Katalog“ mit „Laden“.
* Einträge mit einer `minAppVersion`, die neuer ist als BarDrop, werden übergangen.
* Die `id` im Katalog muss der `id` im Manifest entsprechen, die Prüfsumme der Datei genau stimmen, sonst wird nichts installiert.
* Einreichen per Pull Request mit `.bdrop` und Eintrag; jedes Plugin wird vor dem Aufnehmen geprüft.

## 11. Prüfen vor dem Weitergeben

```sh
python3 scripts/check_plugin.py MeinPlugin/          # Ordner prüfen
python3 scripts/check_plugin.py MeinPlugin/ --pack   # prüfen und .bdrop erzeugen
python3 scripts/check_plugin.py MeinPlugin.bdrop     # fertige Datei prüfen
```

Das Programm prüft jede Regel aus 2 bis 7, warnt vor Aufrufen, die es in JavaScriptCore nicht gibt, vergleicht genutzte Aufrufe mit `permissions` und prüft mit Node.js (falls installiert) die Syntax.

**Danach von Hand:**

1. In BarDrop importieren, Plugin einschalten.
2. Per Rechtsklick an einem passenden Objekt ausprobieren; erscheint es nicht, passt `match` nicht.
3. Fehler stehen im Dialog und unter Einstellungen → Plugins → Plugin → „Letzter Fehler“.
4. Mehr Einzelheiten: Einstellungen → Über BarDrop → Diagnoseprotokoll (Beta), dann `bardrop.log`/`console.log` im Skript.
5. Erst dann „Automatisch beim Ablegen“ ausprobieren.

## 12. Häufige Fehler

| Fehler | Folge | Richtig |
| --- | --- | --- |
| `"version": 1.0` (Zahl) | Manifest unlesbar | `"version": "1.0"` |
| `"value": 1080` in `options` | Manifest unlesbar | `"value": "1080"` |
| unbekanntes Recht, z. B. `"files"` | Plugin abgelehnt | nur `network`, `run`, `clipboard` |
| `bardrop.run` ohne `"run"` | Fehler beim Aufruf | Recht eintragen |
| `tools` ohne `"run"` | Programm nicht startbar | `"permissions": ["run"]` |
| `"hosts": ["https://youtube.com"]` | passt nie | `"hosts": ["youtube.com"]` |
| `"patterns": ["\.pdf$"]` | ungültiges JSON | `"\\.pdf$"` |
| `extensions` für Links | passt nur auf `webloc` | `links.hosts` oder `links.patterns` |
| `setTimeout`, `new URL`, `fetch` | Fehler im Skript | `bardrop.sleep`, Text selbst zerlegen, `bardrop.fetch` |
| `fetch` ohne `status`-Prüfung | Fehlerseite als Ergebnis | `if (r.status !== 200) throw new Error(…)` |
| `run` ohne `code`-Prüfung | Fehlschlag bleibt unbemerkt | `if (r.code !== 0) throw new Error(r.stderr)` |
| Ergebnis außerhalb des Ausgabeordners | erscheint nicht | immer in `bardrop.outputDirectory` schreiben |
| Zwischendateien im Ausgabeordner | erscheinen als Objekte | löschen oder mit `.` am Anfang benennen |
| Archiv als `tools.url` | nicht ausführbar | einzelne ausführbare Datei |
| `automaticByDefault` mit `network` | wirkt nicht | Nutzer schaltet es selbst ein |
| Skript bearbeitet | alle Rechte weg | erwartet; erneut erlauben |

## 13. Beispiel: Tracking aus Links entfernen

`manifest.json`:

```json
{
  "schema": 1,
  "id": "io.github.name.clean-link",
  "name": { "en": "Clean Link", "de": "Link bereinigen" },
  "description": { "en": "Removes tracking from links", "de": "Entfernt Tracking aus Links" },
  "version": "1.0.0",
  "icon": { "symbol": "link", "color": "#34C759" },
  "minAppVersion": "1.31.0",
  "match": { "links": { "hosts": ["*"] } },
  "triggers": ["menu", "automatic"],
  "automaticByDefault": false,
  "canReplaceOriginal": true
}
```

`main.js`:

```js
function run(item) {
  if (item.kind !== "link") return;
  var hashAt = item.url.indexOf("#");
  var hash = hashAt >= 0 ? item.url.slice(hashAt) : "";
  var rest = hashAt >= 0 ? item.url.slice(0, hashAt) : item.url;
  var queryAt = rest.indexOf("?");
  if (queryAt < 0) return;                       // nichts zu tun: kein Ergebnis
  var keep = rest.slice(queryAt + 1).split("&").filter(function (pair) {
    return pair && !/^(utm_|fbclid=|gclid=|mc_)/.test(pair);
  });
  var clean = rest.slice(0, queryAt) + (keep.length ? "?" + keep.join("&") : "") + hash;
  bardrop.createLink(clean, item.name);
}
```
