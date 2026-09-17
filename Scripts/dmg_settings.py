"""Finder presentation; read by dmgbuild with the staging directory in defines."""
from pathlib import Path

staging = Path(defines['staging'])
artwork = Path(defines['artwork'])
format = 'UDZO'
filesystem = 'HFS+'
files = [str(staging / 'DeskKit.app'), str(staging / '样例与说明')]
symlinks = {'Applications': '/Applications'}
icon = str(staging / 'DeskKit.app/Contents/Resources/AppIcon.icns')
background = str(artwork / 'background.png')
# Finder bounds include the title bar; leave 560 points for the artwork.
window_rect = ((160, 120), (760, 592))
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
default_view = 'icon-view'
include_icon_view_settings = True
include_list_view_settings = False
arrange_by = None
grid_spacing = 80
scroll_position = (0, 0)
show_icon_preview = False
text_size = 13
icon_size = 112
hide_extensions = ['DeskKit.app']
icon_locations = {
    'DeskKit.app': (196, 256),
    'Applications': (564, 256),
    '样例与说明': (644, 442),
}
