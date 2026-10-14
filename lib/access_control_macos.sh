#!/usr/bin/env bash
# access_control_macos.sh: check and remove the macos access control list entries a grant adds.
# called by the install record's undo lines and by the installer's plan, from the pinned copy of this
# package (see lib/access_control.sh). the work is in lib/access_control_macos.py; this entry name stays
# because install records store the command text.
#
#   access_control_macos.sh check  USER [--allow-own-entries] --tree FOLDER... --alone FOLDER...
#   access_control_macos.sh status USER yes|no PATH
#   access_control_macos.sh sweep  USER yes|no PATH
#
# yes is for a granted folder and everything inside it, no for a pass-through parent (a folder the
# agent only passes through). see the header of the python file for what each does.
exec python3 -I "$(dirname "${BASH_SOURCE[0]}")/access_control_macos.py" "$@"
