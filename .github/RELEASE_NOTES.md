* **New: AirDrop into the shelf.** “Add files received with AirDrop” (Settings → Items) puts files that arrive via AirDrop into the shelf right away. They stay in the Downloads folder
* **New: Plugins start ready to use.** A plugin can come with default settings (action bar, automatically when dropped, replace original). After you install and allow it, it is turned on with these settings, and the gallery opens its page
* **New:** A `.bdrop` file added to the `Plugins/` folder of the repository appears in the gallery for everyone
* **Changed: Calmer plugin settings.** The list shows version and size for each plugin. A plugin’s page shows permission, running and errors as quiet rows in its top card (“Copy Error” instead of the whole message), short descriptions instead of info buttons, and a short Info that says clearly whether the plugin uses the internet. “Access” replaces “Permissions” and can revoke everything at once. The gallery shows two lines per plugin and only plugins you don’t have yet. Log and “Import From Files” sit at the bottom right
* **Changed:** A running plugin shows a blue progress bar like the Finder, centered between the picture and the name, and breathes calmly instead of flickering
* **Changed:** Clearer wording throughout Settings, in English and German
* **Changed:** The light outline of the shelf sits fully on the black instead of half on the edge, and a floating glass shelf no longer shows a double edge
* **Changed:** Everything at the top right of the shelf has the same distance from the edge as “BarDrop” on the left
* **Fixed:** If macOS doesn’t let BarDrop read the screenshot folder (for example after an update), Settings say so and open the right place in System Settings, instead of screenshots silently not arriving
* **Fixed:** Canceling a plugin with “Replace original” no longer brings the original back
* **Fixed:** Plugin actions in the action bar accept files dragged from the Finder (#57)
* **Fixed:** The plugin icon in the allow window no longer has a square around it
* Plugins: new `defaults` key in manifest.json; `scripts/build_gallery.py` builds the gallery from `Plugins/`

<!-- de -->

* **Neu: AirDrop in die Ablage.** „Mit AirDrop empfangene Dateien hinzufügen“ (Einstellungen → Objekte) legt per AirDrop empfangene Dateien sofort in die Ablage. Sie bleiben im Ordner „Downloads“
* **Neu: Plugins sind gleich startklar.** Ein Plugin kann Voreinstellungen mitbringen (Aktionsleiste, automatisch beim Ablegen, Original ersetzen). Nach dem Installieren und Erlauben ist es damit eingeschaltet, und die Galerie öffnet seine Seite
* **Neu:** Eine `.bdrop`-Datei im Ordner `Plugins/` des Repositorys erscheint für alle in der Galerie
* **Geändert: Ruhigere Plugin-Einstellungen.** Die Liste zeigt je Plugin Version und Größe. Die Seite eines Plugins zeigt Erlaubnis, Lauf und Fehler als ruhige Zeilen in der oberen Karte („Fehler kopieren“ statt der ganzen Meldung), kurze Erklärungen statt Info-Knöpfen und eine kurze Info, die klar sagt, ob das Plugin das Internet nutzt. „Zugriff“ ersetzt „Rechte“ und kann alles auf einmal entziehen. Die Galerie zeigt zwei Zeilen je Plugin und nur Plugins, die du noch nicht hast. Protokoll und „Aus Dateien importieren“ stehen unten rechts
* **Geändert:** Ein laufendes Plugin zeigt einen blauen Fortschrittsbalken wie im Finder, mittig zwischen Bild und Name, und atmet ruhig, statt zu flackern
* **Geändert:** Klarere Formulierungen in allen Einstellungen, auf Deutsch und Englisch
* **Geändert:** Der helle Rahmen der Ablage liegt ganz auf dem Schwarz statt halb auf der Kante, und eine schwebende Ablage aus Glas zeigt keinen doppelten Rand mehr
* **Geändert:** Alles oben rechts in der Ablage hat denselben Abstand zur Kante wie „BarDrop“ links
* **Behoben:** Darf BarDrop den Ordner der Bildschirmfotos nicht lesen (etwa nach einem Update), sagen das die Einstellungen und öffnen die richtige Stelle in den Systemeinstellungen, statt dass Bildschirmfotos still nicht ankommen
* **Behoben:** Ein abgebrochenes Plugin mit „Original ersetzen“ holt das Original nicht mehr zurück
* **Behoben:** Plugin-Aktionen in der Aktionsleiste nehmen Dateien aus dem Finder an (#57)
* **Behoben:** Das Plugin-Symbol im Erlauben-Fenster hat kein Viereck mehr darum
* Plugins: neuer Schlüssel `defaults` in der manifest.json; `scripts/build_gallery.py` baut die Galerie aus `Plugins/`
