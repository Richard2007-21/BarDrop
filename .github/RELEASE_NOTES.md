* **Fixed:** Links dragged from a web page together with a preview image (for example a video from YouTube) are kept as a link when a turned-on plugin is made for that link, instead of saving the preview image
* **Fixed:** Plugins that run automatically and need a program (`tools`) no longer fail silently on their first run. Turning on “Automatically when dropped” now also asks whether the program may be loaded; plugins whose automatic mode was turned on in Beta 1 ask once at the next drop
* Settings → Plugins shows the last error of a plugin, with Copy
* Plugin scripts can use `console.log`; it goes to the diagnostic log like `bardrop.log`
* Two plugins that need the same program at the same time no longer load it twice
* docs/PLUGINS.md is now an exact reference, with a checker for plugins (scripts/check_plugin.py)

<!-- de -->

* **Behoben:** Links, die zusammen mit einem Vorschaubild aus einer Webseite gezogen werden (zum Beispiel ein Video von YouTube), bleiben ein Link, wenn ein eingeschaltetes Plugin für diesen Link gemacht ist, statt dass das Vorschaubild gespeichert wird
* **Behoben:** Plugins, die automatisch laufen und ein Programm brauchen (`tools`), scheitern beim ersten Lauf nicht mehr still. Beim Einschalten von „Automatisch beim Ablegen“ fragt BarDrop jetzt auch, ob das Programm geladen werden darf; Plugins, deren Automatik schon in Beta 1 an war, fragen einmal beim nächsten Ablegen
* Einstellungen → Plugins zeigt den letzten Fehler eines Plugins, mit „Kopieren“
* Plugin-Skripte können `console.log` verwenden; es landet wie `bardrop.log` im Diagnoseprotokoll
* Zwei Plugins, die gleichzeitig dasselbe Programm brauchen, laden es nicht mehr doppelt
* docs/PLUGINS.de.md ist jetzt eine genaue Referenz, mit einem Prüfprogramm für Plugins (scripts/check_plugin.py)
