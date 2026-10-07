# Gifdrop

A droplet for [Droppy](https://getdroppy.app), built with [DroppyKit](https://getdroppy.app/docs/droppykit). It turns a video or an image into a GIF with FFmpeg, shows the progress next to the notch, and expands the notch when the GIF is ready.

## What it does

- Converts MP4, M4V, MOV, WebM, PNG and JPG files to an animated GIF (15 fps, up to 640 px wide). A PNG or JPG gives a single-frame GIF.
- Drop a file on the widget, or press Choose video… to pick one.
- While it works, a progress ring and a percentage sit on each side of the notch, so you can keep working in another app. The Cancel button stops FFmpeg and removes the partial file.
- When the GIF is done, the notch expands into a card with the file name and its size. If something goes wrong, the card says so instead.
- The Show in Finder button reveals the result. Convert another picks the next file.
- Paired with another widget, the card shows the percentage on its own.

The GIF is saved next to the source file. The source is never touched, and an existing GIF is never overwritten: a second conversion becomes `name 2.gif`.

## How it works

Video to GIF runs FFmpeg as a child process in two passes. The first builds an optimal 256-colour palette, the second encodes the GIF with it, which keeps the colours from washing out. Progress comes from FFmpeg's `-progress` output, divided by the duration that `ffprobe` reports. The palette pass counts for 30%, the encode for 70%.

The live activity is a compact row on both sides of the notch, published only while a conversion runs and released the moment it ends. The completion HUD appears as a strip first, then morphs into the card under the same id.

Video to GIF asks for the `hud` capability and no other. It does not use the network and reads only the file you give it. FFmpeg is not bundled.

## Requirements

FFmpeg and ffprobe, installed with Homebrew:

```bash
brew install ffmpeg
```

Video to GIF looks for them in `/opt/homebrew/bin`, `/usr/local/bin`, `/opt/local/bin` and `/usr/bin`. Without `ffprobe` the conversion still works, but the percentage stays at 0% until it finishes.

## Build

```bash
droppykit run
droppykit validate
droppykit build
```

Requires Xcode 26 and DroppyKit 1.20 or later.

## License

MIT