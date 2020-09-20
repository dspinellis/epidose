#!/bin/sh
#
# Utilities for shell scripts
#
# Copyright 2020 Diomidis Spinellis
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

# Sleep time between retries to get the filter over WiFi (in seconds)
# 15 minutes
export WIFI_RETRY_TIME=$((15 * 60))

# Directory of WiFi users
WIFI_USERS=/var/lock/epidose/wifi-users

# Obtain exclusive access to the above directory
WIFI_USERS_LOCK=/var/lock/epidose/wifi-users.lock

# Pick up Python scripts from the same directory
SCRIPT_DIR="$(dirname "$0")"

# Pick Python from the current directory
PYTHON=venv/bin/python


# Log with a timestamp
log()
{
  # Output is redirected to the log file if needed at the script's lop level
  date +'%F %T ' | tr -d \\n 1>&2
  echo "$@" 1>&2
}

# Report usage information and exit with an error
usage()
{
  cat <<EOF 1>&2
Usage: $0 [-d] [-i] [-v] server-url
-d	Debug mode
-i	Use Python installed for the epidose venv
-v	Verbose logging
EOF
  exit 1
}

# Turn WiFi on and wait for it to associate
# Internal function
_wifi_on()
{
  log "Turn on WiFi"

  log "Temporary stop beacon transmissions"
  supervisorctl stop epidose:beacon_tx

  # No WiFi operations when running in debug mode
  test "$DEBUG_FLAG" && return
  ip link set wlan0 up
  sleep 15
}

# Turn WiFi off
# TODO: Check if "iwconfig wlan0 txpower off" yields additional power savings
# Internal function
_wifi_off()
{
  log "Turn off WiFi"

  log "Resume beacon transmissions"
  supervisorctl start epidose:beacon_tx

  # No WiFi operations when running in debug mode
  test "$DEBUG_FLAG" && return
  ip link set wlan0 down
}

# On return WiFi will be on and stay on until the last app releases it
wifi_acquire()
{
  log "Acquiring WiFi"
  (
    # Acquire exclusive access to the WiFi users directory
    flock -n 9 || exit 1
    if mkdir "$WIFI_USERS" 2>/dev/null ; then
      # Directory was not there; having created it, turn WiFi on
      _wifi_on
    fi
    # Add ourselves to the WiFi users
    touch "$WIFI_USERS/$APP_NAME"
  ) 9>"$WIFI_USERS_LOCK"
  log "Acquired WiFi"
}

# Release use of the WiFi.  When the last app releases it it will turn
# off
wifi_release()
{
  log "Releasing WiFi"
  (
    # Acquire exclusive access to the WiFi users directory
    flock -n 9 || exit 1
    # Remove ourselves from the WiFi users
    rm "$WIFI_USERS/$APP_NAME"
    # Try to remove the directory; will succeed only if we were the last user
    if rmdir "$WIFI_USERS" 2>/dev/null ; then
      # Directory removed; turn WiFi off
      _wifi_off
    fi
  ) 9>"$WIFI_USERS_LOCK"
  log "Released WiFi"
}

# Run the specified Python script from the local or installation directory
run_python()
{
  prog="$1"
  shift
  # shellcheck disable=SC2086
  "$PYTHON" "$SCRIPT_DIR"/"$prog".py $DEBUG_FLAG $VERBOSE_FLAG "$@"
}

if [ -z "$APP_NAME" ] ; then
  echo "APP_NAME not set" 1>&2
  exit 2
fi

# Parse command line options
while getopts 'div' c
do
  case $c in
    d)
      # Debug: Pass flag to other programs
      export DEBUG_FLAG=-d
      ;;
    i)
      PYTHON=/opt/venvs/epidose/bin/python
      SCRIPT_DIR=/opt/venvs/epidose/lib/python3.7/site-packages/epidose/device
      ;;
    v)
      # Verbose logging; pass to other programs
      export VERBOSE_FLAG=-v
      ;;
    *)
      echo "Invalid option $c" 1>&2
      usage
      ;;
  esac
done

shift $((OPTIND-1))


log 'Starting up'

# Obtain server URL
if [ -n "$1" ] ; then
  export SERVER_URL="$1"
elif [ -z "$SERVER_URL" ] ; then
  usage
fi

# Create lock directory
mkdir -p "$(dirname "$WIFI_USERS_LOCK")"
