* **Changed:** Plugins with “Replace original” turned on no longer show the original next to a placeholder: the placeholder stands in the original’s place, and the result appears there directly, without a fade
* Plugins: messages a plugin gives itself (`throw new Error(…)`) appear exactly as written; file and line are only added for errors in the code
* **Improved:** macOS sometimes reports changed displays many times per second without anything changing (over 200 times in 30 seconds in a diagnostic log). BarDrop now collects these reports and only rearranges the shelf when something really changed, which saves work and keeps the diagnostic log readable
* **Improved:** Files for which Quick Look can’t make a preview, such as links, are no longer asked for a preview again and again

<!-- de -->

* **Geändert:** Plugins mit „Original ersetzen“ zeigen das Original nicht mehr neben einem Platzhalter: Der Platzhalter steht an der Stelle des Originals, und das Ergebnis erscheint direkt dort, ohne Überblenden
* Plugins: Meldungen, die ein Plugin selbst gibt (`throw new Error(…)`), erscheinen genau so, wie sie geschrieben sind; Datei und Zeile kommen nur bei Fehlern im Code dazu
* **Verbessert:** macOS meldet geänderte Bildschirme teils viele Male pro Sekunde, ohne dass sich etwas ändert (in einem Diagnoseprotokoll über 200 Mal in 30 Sekunden). BarDrop sammelt diese Meldungen jetzt und richtet die Ablage nur neu aus, wenn sich wirklich etwas geändert hat. Das spart Arbeit und hält das Diagnoseprotokoll lesbar
* **Verbessert:** Für Dateien, für die Quick Look kein Vorschaubild erzeugen kann, etwa Links, wird nicht mehr immer wieder eines angefragt
