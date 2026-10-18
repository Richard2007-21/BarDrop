# Product images and preview GIF

The pictures in `docs/images` and `docs/preview.gif` show the real app. CI renders the
shelf, Settings and the shelf states for the GIF from the app's own views
(`testProductShots` in `Tests/BarDropTests/ViewSmokeTests.swift`) and attaches them as
`previews.zip` to the draft release “CI Vorschaubilder”.

To rebuild them, put the `Produkt_*.png` files from that zip next to these files, add
`Resources/AppIcon.png`, then:

```bash
pip install playwright pillow
python3 make.py && python3 shoot.py p_hero_en p_actions_en p_stacks_en p_settings_en \
    p_hero_de p_actions_de p_stacks_de p_settings_de
python3 -c "from PIL import Image; Image.open('Produkt_GIF_oben.png').crop((326,348,454,444)).save('lake_icon.png')"
python3 gifshot.py
ffmpeg -framerate 25 -i frames/f%04d.png -vf palettegen=max_colors=192 pal.png
ffmpeg -framerate 25 -i frames/f%04d.png -i pal.png -lavfi paletteuse=dither=sierra2_4a -loop 0 preview.gif
```

The preview GIF (`docs/preview.gif`) is built from `gif2.html` and `gif2.js`. Put the `GIF2_*.png` files
from `previews.zip` next to them, cut the photos and the note icon out of the shelf shots, then:

```bash
python3 -c "from PIL import Image; im=Image.open('GIF2_2.png').convert('RGB'); [im.crop((x-61,349,x+61,439)).save(f'GIF2_Sunset_{n}.jpg',quality=95) for n,x in [(1,390),(2,580),(3,770)]]; Image.open('GIF2_4.png').crop((516,596,644,724)).save('GIF2_notes_icon.png')"
python3 gif2shot.py 25
ffmpeg -framerate 25 -i frames2/f%04d.png -vf palettegen=max_colors=192:stats_mode=full pal.png
ffmpeg -framerate 25 -i frames2/f%04d.png -i pal.png -lavfi paletteuse=dither=sierra2_4a -loop 0 preview.gif
```
