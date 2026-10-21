# dmgbuild settings for the release DMG. scripts/package_release.sh passes -D app=<.app> -D background=<.tiff>.
# Icon positions match the arrow drawn by `scripts/make_art.swift dmg`.
import os.path

app = defines["app"]
app_name = os.path.basename(app)

files = [app]
symlinks = {"Программы": "/Applications"}
icon = os.path.join(app, "Contents/Resources/AppIcon.icns")
hide_extension = [app_name]

format = "UDZO"
compression_level = 9
filesystem = "HFS+"

background = defines["background"]
window_rect = ((200, 160), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
arrange_by = None
icon_size = 112
text_size = 13
icon_locations = {app_name: (165, 205), "Программы": (495, 205)}
