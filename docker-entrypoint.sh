#!/bin/sh

VALKEY_CONF=${VALKEY_CONF:-/etc/valkey.conf}
VALKEY_SERVER=${VALKEY_SERVER:-/usr/local/bin/valkey-server}

# The password is never passed through sed or echoed. Every byte is encoded as
# \xHH, which valkey decodes inside a double-quoted config argument, so any
# character (including quotes, backslashes, spaces and newlines) is safe.
{
  sed -e 's/protected-mode yes/protected-mode no/' "$VALKEY_CONF" | sed -e 's/bind 127\.0\.0\.1 \-\:\:1/bind \* \-\:\:\*/'
  echo
  if [ -n "$PASSWORD" ]; then
    ESC=$(printf '%s' "$PASSWORD" | od -An -v -tx1 | tr -d ' \n' | sed 's/../\\x&/g')
    printf 'requirepass "%s"\n' "$ESC"
  fi
} | "$VALKEY_SERVER" -
