// Testplugin: Notiz mit der Adresse und ein bereinigter Link
async function run(item) {
  if (item.kind !== "link") throw new Error("kein Link");
  bardrop.writeFile("notes/../" + item.name + ".txt", item.url + "\n");
  // Relativer Pfad: aus dem Ausgabeordner gelesen
  var again = bardrop.readFile(item.name + ".txt");
  if (again.trim() !== item.url) throw new Error("readFile relativ");
  await bardrop.sleep(10);
  bardrop.createLink(item.url.split("?")[0], item.name + " clean");
}
