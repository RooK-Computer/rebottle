# Rebottle - put sd cards back into image files

This tool can create image files from raspberry pi os trixie installations by shrinking them and re-enabling the autoresizing mechanism.

To use it, simply call rebottle.sh $blockdevice $imagefilename.
It needs sudo permissions for a few of its operations, so call it with sudo.

## What it does

In a nutshell, it resizes the file system, then resizes the partition and does a copy of the block device (up to the second partition end), which gets compressed along the way.

