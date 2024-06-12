#!/bin/sh

cat /etc/valkey.conf | sed -e 's/protected-mode yes/protected-mode no/' | sed -e 's/bind 127\.0\.0\.1 \-\:\:1/bind \* \-\:\:\*/' | /usr/local/bin/valkey-server -