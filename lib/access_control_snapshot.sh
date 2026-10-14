#!/usr/bin/env bash
# access_control_snapshot.sh: check, record, and undo the linux access control lists a grant adds.
# called by the install record's undo lines, by the grant rollback and the kill switch, and by the
# installer's plan, from the pinned copy of this package (see lib/access_control.sh). the work is in
# lib/access_control_snapshot.py; this entry name stays because install records store the command text.
#
#   access_control_snapshot.sh check   USER --tree FOLDER... --alone FOLDER...
#   access_control_snapshot.sh record  SNAPSHOT FOLDER yes|no USER [--audit FILE]
#   access_control_snapshot.sh restore SNAPSHOT FOLDER yes|no USER [--audit FILE]
#   access_control_snapshot.sh status  SNAPSHOT FOLDER yes|no USER
#   access_control_snapshot.sh repair  FOLDER yes|no USER [--audit FILE]
#
# the third argument is yes for a granted folder and everything inside it, no for a traverse folder
# (a parent the agent only passes through). see the header of the python file for what each does.
# older install records call restore with four arguments after the name and no --audit; that works.
exec python3 -I "$(dirname "${BASH_SOURCE[0]}")/access_control_snapshot.py" "$@"
