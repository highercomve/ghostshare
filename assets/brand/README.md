# GhostShare logo

The friendly coral ghost carries a rightward arrow: files moving from one device to another. Broad shapes and rounded corners keep the mark readable at small sizes.

- `ghostshare-mark.svg`: transparent scalable mark.
- `ghostshare-icon.svg` / `.png`: launcher icon on warm paper, 1024px PNG.
- `ghostshare-tray.png`: transparent 128px tray icon.

Colors: coral `#d95e43`, paper `#f5f1e9`, details `#fff7ed`.

Export the PNGs with librsvg:

```sh
rsvg-convert -w 1024 -h 1024 ghostshare-icon.svg -o ghostshare-icon.png
rsvg-convert -w 128 -h 128 ghostshare-mark.svg -o ghostshare-tray.png
```
