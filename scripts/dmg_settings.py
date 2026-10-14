# Einstellungen für dmgbuild: Installationsfenster mit Hintergrund, BarDrop links,
# Verknüpfung zu „Programme“ rechts. Aufruf siehe scripts/build_app.sh.
import os.path

app = defines.get("app", "build/BarDrop.app")          # noqa: F821 (von dmgbuild gesetzt)
app_name = os.path.basename(app)

volume_name = "BarDrop"
format = "UDZO"
filesystem = "HFS+"

files = [app]
symlinks = {"Programme": "/Applications"}
hide_extensions = [app_name]

background = defines.get("background", "Resources/dmg-background.tiff")  # noqa: F821
window_rect = ((200, 140), (600, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False

icon_size = 112
text_size = 13
arrange_by = None
icon_locations = {
    app_name: (165, 185),
    "Programme": (435, 185),
}
