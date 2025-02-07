#!/bin/sh

if [ ! -z "$PASSWORD" ]; then
  sed -i -e "s/# requirepass foobared/requirepass $PASSWORD/" /etc/valkey.conf
fi
cat /etc/valkey.conf | sed -e 's/protected-mode yes/protected-mode no/' | sed -e 's/bind 127\.0\.0\.1 \-\:\:1/bind \* \-\:\:\*/' | /usr/local/bin/valkey-server -