# shellcheck shell=bash
# make the disposable machine look like a real host to the installer. the installer decides it is in a
# container from /.dockerenv, /run/.containerenv, and container= in process 1's environment (in_container in
# lib/common.sh). the first two are removed here. the third cannot be changed from inside a container, so on an
# engine that sets it (podman does, docker does not) the scenario fails loudly instead of testing the wrong path.
# sourced after world.sh. a throwaway container only: this deletes files at the root of the machine.
rm -f /.dockerenv /run/.containerenv
if (. "$SRC/lib/common.sh"; in_container); then
  printf 'not ok  the installer still sees a container; process 1 has container= set, so this engine cannot simulate a real host\n'
  exit 1
fi
printf 'ok      the installer takes the non-container path (in_container is false)\n'
