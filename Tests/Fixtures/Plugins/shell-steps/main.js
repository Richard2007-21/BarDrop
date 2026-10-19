// Testplugin: Programm mit Ausgabe auf stdout und stderr, Fortschritt aus den Zeilen
async function run(item) {
  var seen = [];
  var r = await bardrop.run("/bin/sh", ["-c",
    "printf 'P 25\\n'; printf 'warn' >&2; printf 'P 50\\rP 75\\n'; printf 'ing\\n' >&2; printf 'P 100'; exit 3"], {
    onOutput: function (line) {
      seen.push(line);
      var m = /^P (\d+)$/.exec(line);
      if (m) bardrop.progress(parseInt(m[1], 10) / 100);
    }
  });
  if (r.code !== 3) throw new Error("code " + r.code);
  bardrop.writeFile("lines.txt", seen.sort().join("|") + "\n" + r.stdout.length + "\n" + r.stderr.trim());
}
