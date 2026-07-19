# Rebottle - put SD cards back into image files

This tool can create image files from Raspberry Pi OS trixie installations by shrinking them and re-enabling the autoresizing mechanism.

## Usage

To use it, simply call:

```bash
sudo rebottle.sh <BLOCK-DEVICE> <IMAGE-FILE-NAME.img.gz>
```

It needs `sudo` permissions for a few of its operations, so call it with sudo.

## What it does

In a nutshell, it resizes the file system, then resizes the partition and does a copy of the block device (up to the second partition end), which gets compressed along the way.
