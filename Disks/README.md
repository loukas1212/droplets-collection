# Disks

A droplet for [Droppy](https://getdroppy.app), built with [DroppyKit](https://getdroppy.app/docs/droppykit). It puts your mounted disks on the shelf, with their used space and an Eject button.

## What it does

- Lists every mounted volume with its icon and name. The list updates by itself when a disk is mounted, unmounted or renamed.
- The Open button shows the disk in Finder.
- The Eject button unmounts and ejects the disk safely. While it works, the button shows a spinner so a second click can't start a second eject. If macOS refuses (a file is still open on the disk, for example), the widget tells you why.
- Click a disk to see how much of it is used, as a bar and a figure. The chevron takes you back to the list.
- Paired with another widget, the card lists the disks by name.

The startup disk can be opened but not ejected.

## How it works

Disks reads volumes with `FileManager` and `NSWorkspace`, and reacts to the mount, unmount and rename notifications, so it never polls.

Names, capacities and icons are read on one serial `DispatchQueue`, and ejects run on their own `DispatchQueue`. Neither uses Swift's shared concurrency threads, so a sleeping drive or an unreachable network share can't stall Droppy's own async work. While a scan is running, new requests are merged into a single follow-up scan. Disks needs no capability and reads nothing outside the volume list.

## Build

```bash
droppykit run
droppykit validate
droppykit build
```

Requires Xcode 26 and DroppyKit 1.6 or later.

## License

MIT