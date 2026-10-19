* The action bar has no line above it anymore: items simply disappear under the bar
* Plugins: errors show the file and line in the script (for example “TypeError: … (main.js:4)”), and all messages of the plugin interface are in English and German
* Plugins: Pause and Cancel also stop programs that a plugin’s program started itself
* Plugins: output of programs is split into lines separately for stdout and stderr, so lines no longer get mixed up
* Plugins: the same plugin doesn’t start twice for the same file; waiting plugins show a clock and can only be cancelled
* Plugins: while a program is downloaded for a plugin, the placeholder says so; the dialog now says that the program runs with the same rights as the plugin
* Plugins: permission dialogs ask a clear question (“Allow … to access the internet?”); Settings → Plugins has “Allow” for missing permissions, and plugins that can’t be read can be shown in the Finder or removed
* Plugins: `readFile` accepts paths relative to the output folder; `writeFile` and `readFile` check their arguments
* Plugins: “Works with” uses the language of BarDrop

<!-- de -->

* Über der Aktionsleiste ist keine Linie mehr zu sehen: Objekte verschwinden einfach unter der Leiste
* Plugins: Fehler nennen die Datei und Zeile im Skript (etwa „TypeError: … (main.js:4)“), und alle Meldungen der Plugin-Schnittstelle gibt es auf Deutsch und Englisch
* Plugins: Anhalten und Abbrechen stoppen auch Programme, die das Programm eines Plugins selbst gestartet hat
* Plugins: Die Ausgabe von Programmen wird für stdout und stderr getrennt in Zeilen zerlegt, Zeilen vermischen sich nicht mehr
* Plugins: Dasselbe Plugin startet für dieselbe Datei nicht doppelt; wartende Plugins zeigen eine Uhr und lassen sich nur abbrechen
* Plugins: Während für ein Plugin ein Programm geladen wird, steht das am Platzhalter; der Dialog sagt jetzt, dass das Programm mit denselben Rechten läuft wie das Plugin
* Plugins: Die Fragen nach Rechten sind klar gestellt („Darf … auf das Internet zugreifen?“); Einstellungen → Plugins hat „Erlauben“ für fehlende Rechte, und Plugins, die sich nicht lesen lassen, lassen sich im Finder zeigen oder entfernen
* Plugins: `readFile` nimmt auch Pfade relativ zum Ausgabeordner; `writeFile` und `readFile` prüfen ihre Angaben
* Plugins: „Passt zu“ steht in der Sprache von BarDrop
