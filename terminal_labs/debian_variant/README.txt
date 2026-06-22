Debian variant for terminal labs.

Files:
- `00_debian_setup_commands.txt` installs the full package set for Debian.
- `lab12_commands.txt` ... `lab22_commands.txt` are copied here so `lab_capture.sh` can process this directory directly.

Recommended run from the project root:
- `./lab_capture.sh -f debian_variant`

Important:
- For `xdotool`, use an X11/Xorg session, not Wayland.
