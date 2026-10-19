# BarDrop plugins

English · [Deutsch](PLUGINS.de.md)

Plugins add your own steps to BarDrop: an entry in the right-click menu, an action in the action bar, or something that runs by itself when you drop a matching item. BarDrop doesn’t come with any plugin built in. Plugins are off until you turn them on in **Settings → Plugins**.

## The .bdrop file

A plugin is a single `.bdrop` file. Inside it is a ZIP archive with:

```
manifest.json   what the plugin is, what it works with and what it may do
main.js         the script (JavaScript)
…               optional further files (texts, templates)
```

The files may also sit in exactly one folder inside the archive (that is what “Compress” in the Finder makes). To make a `.bdrop`, compress the folder in the Finder and rename the `.zip` to `.bdrop`, or run:

```sh
ditto -c -k --norsrc --noextattr MyPlugin MyPlugin.bdrop
```

Double-clicking a `.bdrop` (or Settings → Plugins → Import Plugin) shows what the plugin wants to do and its script, with a warning that it isn’t from the BarDrop catalog. Nothing is installed without your confirmation. A plugin may be at most 5 MB, its script at most 1 MB.

## manifest.json

```json
{
  "schema": 1,
  "id": "io.github.yourname.clean-link",
  "name": { "en": "Clean Link", "de": "Link bereinigen" },
  "description": { "en": "Removes tracking from links", "de": "Entfernt Tracking aus Links" },
  "version": "1.0.0",
  "author": "yourname",
  "icon": { "symbol": "link", "color": "#34C759" },
  "actionTitle": { "en": "Clean Link", "de": "Link bereinigen" },
  "minAppVersion": "1.31.0",
  "script": "main.js",
  "match": {
    "types": ["public.image"],
    "extensions": ["webloc"],
    "links": { "hosts": ["example.com"], "patterns": ["^https://example\\.com/watch"] }
  },
  "triggers": ["menu", "action", "automatic"],
  "automaticByDefault": false,
  "permissions": ["network", "run", "clipboard"],
  "tools": [],
  "settings": [],
  "canReplaceOriginal": false,
  "consent": { "en": "…", "de": "…" }
}
```

| Key | Required | Meaning |
| --- | --- | --- |
| `id` | yes | Unique, in reverse domain style. An update must keep it. |
| `name`, `description`, `actionTitle` | `name` | Text for both languages (`{"en": …, "de": …}`) or one text for both. English is used when German is missing. |
| `version` | yes | `1`, `1.2` or `1.2.3`. |
| `icon` | no | `symbol` is the name of an SF Symbol, the same symbols the Shortcuts app uses, so every Mac has them. `color` is the tile color as `#RRGGBB`. BarDrop draws the symbol white on the colored tile, like the icons in its Settings. Unknown symbols become a puzzle piece. |
| `minAppVersion` | no | Oldest BarDrop version the plugin works with. |
| `match` | yes | At least one rule. An item matches when one rule matches. `types` are Uniform Type Identifiers and include their subtypes (`public.image` matches PNG, JPEG, HEIC …). `extensions` without a dot. `links` apply to links in the shelf: `hosts` match the domain and its subdomains (`*` matches every web link), `patterns` are regular expressions on the whole address. |
| `triggers` | no | `menu` (right-click), `action` (action bar), `automatic` (when dropped). All three if missing. |
| `automaticByDefault` | no | Asks for “Automatically when dropped” to start on. Only honored for plugins without `network`, `run` or `tools`; those the user turns on in Settings, which also asks for the permissions right then. |
| `permissions` | no | `network` (load web pages and files), `run` (run programs; this means full access to the Mac), `clipboard` (put text on the clipboard). Each one is asked for the first time it is used. Using a permission that isn’t listed fails. |
| `tools` | no | Programs the plugin needs, see below. |
| `settings` | no | Settings shown under the plugin in Settings → Plugins, see below. |
| `canReplaceOriginal` | no | Shows a “Replace original” switch (off by default). When on, the result takes the original’s place in the shelf; the original file itself is never deleted, and ⌘Z brings it back into the shelf. |
| `consent` | no | A note the user has to agree to once before the plugin runs, for example about legal limits. |

### settings

```json
"settings": [
  { "key": "format", "type": "choice", "title": { "en": "Format", "de": "Format" },
    "default": "png",
    "options": [ { "value": "png", "title": "PNG" }, { "value": "jpg", "title": "JPEG" } ] },
  { "key": "keepName", "type": "toggle", "title": { "en": "Keep name", "de": "Namen behalten" }, "default": true },
  { "key": "prefix", "type": "text", "title": { "en": "Prefix", "de": "Präfix" } }
]
```

The values reach the script as `bardrop.settings.<key>`; `bardrop.settings.replaceOriginal` tells whether “Replace original” is on.

### tools

BarDrop never ships third-party programs. A plugin can name programs that BarDrop loads on first use, after asking:

```json
"tools": [
  { "id": "mytool", "name": "My Tool", "url": "https://example.com/releases/1.0/mytool_macos",
    "sha256": "<64 hex characters>", "license": "MIT", "homepage": "https://example.com" }
]
```

Only `https` is allowed. Instead of `sha256`, `checksums` can point to a checksum list of the publisher (lines `<sha256>  <file name>`), for programs that update often; `refreshDays` then loads them again after that many days. A file that doesn’t match its checksum is deleted. Programs are kept in `~/Library/Application Support/BarDrop/Tools` and can be used by all plugins.

## The script

The script defines `run(item)`. It may be `async` or return a promise. When it ends without an error, **everything in `bardrop.outputDirectory` becomes new items in the shelf, right next to the original** and shown immediately. Hidden files and partial downloads (`.part`, `.tmp`, `.download`, `.crdownload`, `.ytdl`) are left out. If the script throws, nothing is added and BarDrop shows the error.

`item` describes the item:

| Field | Meaning |
| --- | --- |
| `kind` | `"file"`, `"folder"` or `"link"` |
| `path` | Path of the file in the shelf (for links the .webloc) |
| `name` | File name; for links the title |
| `extension`, `type` | File extension and Uniform Type Identifier |
| `url` | Address of a link |
| `size` | Size in bytes (files) |

`bardrop` offers:

| Call | Permission | Meaning |
| --- | --- | --- |
| `bardrop.writeFile(name, text)` | | Writes a text file to the output folder, returns its path |
| `bardrop.createLink(url, title)` | | Creates a link (.webloc) in the output folder |
| `bardrop.readFile(path)` | | Reads a text file: only the item itself, the output folder and the plugin’s own files |
| `bardrop.progress(fraction, label)` | | Progress 0…1 for the placeholder; `label` replaces its name (optional) |
| `bardrop.notify(text)` | | Short note at the top of the shelf |
| `bardrop.isCancelled()` | | Whether the user cancelled |
| `await bardrop.sleep(ms)` | | Waits (there is no `setTimeout`) |
| `bardrop.log(text)` | | Line in the diagnostic log (beta versions, when turned on) |
| `await bardrop.fetch(url, {method, headers, body})` | `network` | `{status, url, headers, text}` |
| `await bardrop.download(url, {name})` | `network` | Downloads into the output folder with progress, returns the path |
| `await bardrop.run(command, args, {onOutput})` | `run` | Runs a program: a `tools` id, an absolute path, or a name found in `/usr/bin`, `/bin`, `/usr/sbin`, `/sbin`, `/opt/homebrew/bin`, `/usr/local/bin`. It runs in the output folder. `onOutput(line)` gets every line (also at `\r`, for progress). Returns `{code, stdout, stderr}` |
| `bardrop.setClipboard(text)` | `clipboard` | Puts text on the clipboard |
| `bardrop.settings`, `bardrop.language` (`"en"`/`"de"`), `bardrop.appVersion`, `bardrop.plugin` | | Values |

Each plugin runs in its own short-lived JavaScriptCore context on its own queue. At most three plugins run at the same time; more wait. The script has the JavaScript language itself, but no browser or Node APIs: no DOM, no `URL`, no `setTimeout`, no `require` and no file access other than the calls above. Nothing of a plugin runs while it isn’t used.

### Example

```js
// Removes utm_… and other tracking parameters from a link
function run(item) {
  if (item.kind !== "link") return;
  var hashAt = item.url.indexOf("#");
  var hash = hashAt >= 0 ? item.url.slice(hashAt) : "";
  var rest = hashAt >= 0 ? item.url.slice(0, hashAt) : item.url;
  var queryAt = rest.indexOf("?");
  if (queryAt < 0) return;
  var keep = rest.slice(queryAt + 1).split("&").filter(function (pair) {
    return pair && !/^(utm_|fbclid=|gclid=|mc_)/.test(pair);
  });
  var clean = rest.slice(0, queryAt) + (keep.length ? "?" + keep.join("&") : "") + hash;
  bardrop.createLink(clean, item.name);
}
```

with `"match": { "links": { "hosts": ["*"] } }` and `"canReplaceOriginal": true`.

## In BarDrop

* **Right-click:** matching plugins appear below the usual entries, after a separator. Up to three directly, from four on in a “Plugins” submenu.
* **Action bar:** Settings → Plugins → a plugin → “In the action bar”, or Settings → Actions → Add Action.
* **Automatically when dropped:** per plugin, off by default. If several automatic plugins match the same item, only the first one in the list runs; the arrows in Settings change the order. The place that shows “1 of 3 selected” briefly shows which plugin is active.
* **Placeholder:** while a plugin runs, a placeholder with a ring stands right next to the original. Its right-click menu shows the progress in percent and can pause, resume and cancel. Pausing stops running programs and downloads where they are; quitting BarDrop cancels them.
* **Permissions** are asked the first time they are used, and for automatic plugins when “Automatically when dropped” is turned on. Editing a plugin’s script (Settings → Plugins → Script → Open in Editor) resets its permissions. Standard plugins can’t be edited or removed, only turned off.

## Catalog

The catalog is [`Plugins/index.json`](../Plugins/index.json) in this repository. It lists reviewed plugins:

```json
{
  "schema": 1,
  "plugins": [
    { "id": "io.github.yourname.clean-link", "version": "1.0.0",
      "name": { "en": "Clean Link", "de": "Link bereinigen" },
      "icon": { "symbol": "link", "color": "#34C759" },
      "url": "https://raw.githubusercontent.com/zzuuuiii/BarDrop/main/Plugins/clean-link.bdrop",
      "sha256": "<checksum of the .bdrop>",
      "standard": false }
  ]
}
```

* `standard: true`: installed automatically when the user turns on plugins (turned off), updated silently, can’t be removed by the user.
* `removed: true`: BarDrop removes the plugin at the next check, standard plugins included.
* Other entries appear under “More in the catalog” with a “Get” button.

BarDrop checks the catalog at most once a day and only while plugins are turned on. To submit a plugin, open a pull request that adds the `.bdrop` and its entry; every plugin is reviewed before it is merged. The catalog is empty for now.
