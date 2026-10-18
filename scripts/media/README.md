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
