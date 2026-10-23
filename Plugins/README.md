# Plugins

## Deutsch

Jede `.bdrop`-Datei in diesem Ordner (auch in Unterordnern) erscheint in der Galerie von BarDrop. Nach jeder Änderung hier prüft `.github/workflows/plugin-gallery.yml` die Dateien mit denselben Regeln wie `scripts/check_plugin.py` und trägt sie auf dem Zweig `plugin-katalog` ein. Fehlerhafte Dateien werden übersprungen und im Lauf unter Actions gemeldet. Alles hier ist öffentlich: nur geprüfte Plugins hochladen.

1. Auf GitHub diesen Ordner öffnen, **Add file → Upload files**, die `.bdrop`-Datei hineinziehen und **Commit changes**.
2. Nach etwa einer Minute steht das Plugin in der Galerie. BarDrop zeigt es spätestens nach einem Tag, beim Öffnen von Einstellungen → Plugins nach einer Stunde.
3. Aktualisieren: eine neue Datei mit höherer `version` in der manifest.json hochladen (die alte löschen oder liegen lassen, die höchste Version gilt).
4. Entfernen: die Datei löschen. Das Plugin bleibt als zurückgezogen in der Galerie stehen, damit installierte Kopien davon erfahren.

`index.json` hier ist der leere Katalog für ältere Versionen von BarDrop und bleibt unverändert. Mehr in [docs/PLUGINS.de.md](../docs/PLUGINS.de.md), Abschnitt 10.

## English

Every `.bdrop` file in this folder (subfolders included) appears in the BarDrop gallery. After each change here, `.github/workflows/plugin-gallery.yml` checks the files with the same rules as `scripts/check_plugin.py` and adds them to the `plugin-katalog` branch. Files with errors are skipped and reported in the run under Actions. Everything here is public: upload reviewed plugins only.

1. Open this folder on GitHub, choose **Add file → Upload files**, drop in the `.bdrop` file and **Commit changes**.
2. After about a minute the plugin is in the gallery. BarDrop shows it within a day, or after an hour when Settings → Plugins is opened.
3. Update: upload a new file with a higher `version` in its manifest.json (delete the old one or keep it, the highest version wins).
4. Remove: delete the file. The plugin stays in the gallery as withdrawn so installed copies learn about it.

`index.json` here is the empty catalog for older versions of BarDrop and stays unchanged. More in [docs/PLUGINS.md](../docs/PLUGINS.md), section 10.
