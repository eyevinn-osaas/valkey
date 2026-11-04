#!/bin/sh

VALKEY_CONF=${VALKEY_CONF:-/etc/valkey.conf}
VALKEY_SERVER=${VALKEY_SERVER:-/usr/local/bin/valkey-server}

# The password is never passed through sed or echoed. Every byte is encoded as
# \xHH, which valkey decodes inside a double-quoted config argument, so any
# character (including quotes, backslashes, spaces and newlines) is safe.
CONFIG=$(
  sed -e 's/protected-mode yes/protected-mode no/' "$VALKEY_CONF" | sed -e 's/bind 127\.0\.0\.1 \-\:\:1/bind \* \-\:\:\*/'
  echo
  # Snapshot at least once a minute while data changes. Replaces the built-in
  # 3600 1 300 100 60 10000 (valkey.conf has no active save line).
  echo 'save 60 1'
  if [ -n "$PASSWORD" ]; then
    ESC=$(printf '%s' "$PASSWORD" | od -An -v -tx1 | tr -d ' \n' | sed 's/../\\x&/g')
    printf 'requirepass "%s"\n' "$ESC"
  fi
)

# exec replaces the shell so the server is PID 1 and receives SIGTERM, which
# makes it save the dataset before exiting. The config goes in on stdin via a
# here-document, so the password is never in argv and never written to disk.
exec "$VALKEY_SERVER" - <<EOF
$CONFIG
EOF
