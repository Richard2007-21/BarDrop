// Testplugin: Kopie einer Textdatei in Großbuchstaben neben dem Original
function run(item) {
  var text = bardrop.readFile(item.path);
  var base = item.name.replace(/\.[^.]*$/, "");
  bardrop.progress(0.5);
  bardrop.writeFile(base + bardrop.settings.suffix + "." + item.extension, text.toUpperCase());
}
