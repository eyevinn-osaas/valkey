#!/bin/bash
# Image-level test for the OSC entrypoint (docker-entrypoint.sh): the server must receive SIGTERM,
# save before exiting, and the data must survive a restart on the same data directory.
#
# Docker mode (docker available):  IMAGE=<image> tests/osc/sigterm-persistence.sh   (builds the image when IMAGE is unset)
# Native mode (no docker):         tests/osc/sigterm-persistence.sh   (needs src/valkey-server and src/valkey-cli built with make)
#
# Both modes make the same assertions. Exit status is 0 only when every assertion passes.
# Reference: osaas-ai#2438 (password handling), osaas-ai#2527 (SIGTERM and save policy).
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CK="$(cd "$HERE/../.." && pwd)"
PW='a&b/c\d"e$f#g h'
PORT="${TEST_PORT:-$((20000 + RANDOM % 20000))}"
FAILS=0
MODE=native
if command -v docker > /dev/null 2>&1 && docker info > /dev/null 2>&1; then MODE=docker; fi

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }
check() { # check <description> <command...>
  local d="$1"; shift
  if "$@"; then pass "$d"; else fail "$d"; fi
}

WORK="$(mktemp -d)"
DATA="$WORK/data"
mkdir -p "$DATA"
PID=""
CNAME="valkey-sigterm-test-$$"
VOL="valkey-sigterm-vol-$$"
cleanup() {
  if [ "$MODE" = docker ]; then
    docker rm -f "$CNAME" > /dev/null 2>&1
    docker volume rm "$VOL" > /dev/null 2>&1
  else
    [ -n "$PID" ] && kill -KILL "$PID" 2> /dev/null
    [ -n "${LOGPID:-}" ] && kill -KILL "$LOGPID" 2> /dev/null
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

if [ "$MODE" = docker ]; then
  IMAGE="${IMAGE:-valkey-osc-test:$$}"
  if [ -z "${IMAGE_PREBUILT:-}" ] && [ "${IMAGE#valkey-osc-test:}" != "$IMAGE" ]; then docker build -q -t "$IMAGE" "$CK" > /dev/null || exit 2; fi
  docker volume create "$VOL" > /dev/null
  CLI=(docker exec -i)
else
  SERVER="$CK/src/valkey-server"
  VCLI="$CK/src/valkey-cli"
  [ -x "$SERVER" ] && [ -x "$VCLI" ] || { echo "build first: make -C $CK"; exit 2; }
  sed "s/^port 6379/port $PORT/" "$CK/valkey.conf" > "$DATA/valkey.conf"
fi

RUN=0
LOG=""
START_TS=0
# start <password-or-empty>
start() {
  RUN=$((RUN + 1))
  LOG="$WORK/server-$RUN.log"
  START_TS=$(date +%s)
  if [ "$MODE" = docker ]; then
    local penv=()
    [ -n "$1" ] && penv=(-e "PASSWORD=$1")
    docker run -d --name "$CNAME" -v "$VOL:/data" ${penv[@]+"${penv[@]}"} "$IMAGE" > /dev/null || return 1
    docker logs -f "$CNAME" > "$LOG" 2>&1 &
    LOGPID=$!
  else
    pushd "$DATA" > /dev/null || return 1
    if [ -n "$1" ]; then
      PASSWORD="$1" VALKEY_CONF="$DATA/valkey.conf" VALKEY_SERVER="$SERVER" sh "$CK/docker-entrypoint.sh" > "$LOG" 2>&1 &
    else
      env -u PASSWORD VALKEY_CONF="$DATA/valkey.conf" VALKEY_SERVER="$SERVER" sh "$CK/docker-entrypoint.sh" > "$LOG" 2>&1 &
    fi
    PID=$!
    popd > /dev/null || return 1
  fi
}

# cli <auth-or-empty> <args...>; the password goes through REDISCLI_AUTH, never argv
cli() {
  local auth="$1"; shift
  if [ "$MODE" = docker ]; then
    if [ -n "$auth" ]; then docker exec -e "REDISCLI_AUTH=$auth" "$CNAME" valkey-cli --no-auth-warning "$@" 2>&1
    else docker exec "$CNAME" valkey-cli "$@" 2>&1; fi
  else
    if [ -n "$auth" ]; then REDISCLI_AUTH="$auth" "$VCLI" -p "$PORT" --no-auth-warning "$@" 2>&1
    else env -u REDISCLI_AUTH "$VCLI" -p "$PORT" "$@" 2>&1; fi
  fi
}

wait_ready() { # wait_ready <auth>
  local i
  for i in $(seq 1 100); do
    [ "$(cli "$1" PING)" = PONG ] && return 0
    sleep 0.1
  done
  return 1
}

# a terminated child stays a zombie until waited for, so kill -0 alone cannot tell
alive() { kill -0 "$1" 2> /dev/null && ! grep -q '^State:[[:space:]]*Z' "/proc/$1/status" 2> /dev/null; }
STOP_RC=""
STOP_SECS=""
stop_server() {
  local t0 t1
  t0=$(date +%s.%N)
  if [ "$MODE" = docker ]; then
    docker stop -t 30 "$CNAME" > /dev/null 2>&1
    STOP_RC=$(docker inspect -f '{{.State.ExitCode}}' "$CNAME")
    t1=$(date +%s.%N)
    docker logs "$CNAME" > "$LOG" 2>&1
    kill "$LOGPID" 2> /dev/null
    docker rm "$CNAME" > /dev/null
  else
    kill -TERM "$PID"
    local i
    for i in $(seq 1 300); do alive "$PID" || break; sleep 0.1; done
    if alive "$PID"; then
      # a shell that ignored SIGTERM or a server still running: report as a failed stop
      STOP_RC=timeout
    else
      wait "$PID"; STOP_RC=$?
    fi
    t1=$(date +%s.%N)
    sleep 0.2
  fi
  STOP_SECS=$(awk "BEGIN{printf \"%.1f\", $t1 - $t0}")
}

logged_pid() { sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' "$LOG" | head -1; }
log_has() { grep -q -- "$1" "$LOG"; }
saved_after_sigterm() { awk '/Received SIGTERM/{s=1} s && /DB saved on disk/{f=1} END{exit !f}' "$LOG"; }
stop_ok() { # stop_ok <label>: assertions 5-7
  check "$1 exit status is 0 (got $STOP_RC; 137 and 143 fail)" [ "$STOP_RC" = 0 ]
  check "$1 stop took under 10 s (got ${STOP_SECS}s)" awk "BEGIN{exit !($STOP_SECS < 10)}"
  check "$1 log has 'Received SIGTERM' then 'DB saved on disk'" saved_after_sigterm
}

echo "mode: $MODE"

# Run 1: with password
start "$PW" || exit 2
check "1. PING answers with the password" wait_ready "$PW"
check "2. CONFIG GET save returns '60 1'" [ "$(cli "$PW" CONFIG GET save | tr '\n' ' ')" = "save 60 1 " ]
NOW=$(date +%s)
check "3. SET k v within 60 s of start (took $((NOW - START_TS)) s)" [ $((NOW - START_TS)) -lt 55 ]
check "3. SET k v returns OK" [ "$(cli "$PW" SET k v)" = OK ]

if [ "$MODE" = native ]; then
  CMDLINE=$(tr '\0' '\n' < "/proc/$PID/cmdline" 2> /dev/null)
  check "13. password not in /proc/\$!/cmdline" bash -c '! grep -qF -- "$1" <<< "$2"' _ "$PW" "$CMDLINE"
fi
LPID=$(logged_pid)
if [ "$MODE" = native ]; then WANT_PID=$PID; else WANT_PID=1; fi
check "8. log pid ($LPID) is the signalled PID ($WANT_PID)" [ "$LPID" = "$WANT_PID" ]
echo "assertion 4: SIGTERM sent (docker stop / kill -TERM \$!)"
stop_server
stop_ok "5-7."
if [ "$MODE" = native ]; then
  check "9. no server left (pid $LPID)" bash -c '! kill -0 "$1" 2> /dev/null' _ "$LPID"
else
  check "9. container has exited" [ "$(docker ps -q -f name="$CNAME" | wc -l | tr -d " ")" = 0 ]
fi

# Run 2: same data dir
start "$PW" || exit 2
check "10. second start answers PING" wait_ready "$PW"
check "10. second start returns v for GET k" [ "$(cli "$PW" GET k)" = v ]
check "10. second start loaded the dump" log_has "DB loaded from disk"
check "12. wrong password gives WRONGPASS" bash -c 'grep -q WRONGPASS <<< "$1"' _ "$(cli wrong-password PING)"
stop_server
stop_ok "10."
[ "$MODE" = native ] && [ -n "$PID" ] && check "9. no server left after second stop" bash -c '! kill -0 "$1" 2> /dev/null' _ "$(logged_pid)"

# Run 3: no PASSWORD, fresh data dir semantics are not needed; AUTH must be off
start "" || exit 2
check "11. PING answers without PASSWORD set" wait_ready ""
stop_server

# 13: the password appears nowhere
ALL=$(cat "$WORK"/server-*.log)
check "13. password not in any log or captured output" bash -c '! grep -qF -- "$1" <<< "$2"' _ "$PW" "$ALL"
if [ "$MODE" = native ]; then
  check "13. password not in any file under the data dir or /dev/shm" bash -c '! grep -rqF -- "$1" "$2" /dev/shm 2> /dev/null' _ "$PW" "$DATA"
fi

echo
if [ "$FAILS" = 0 ]; then echo "ALL ASSERTIONS PASSED ($MODE mode)"; exit 0; fi
echo "$FAILS ASSERTION(S) FAILED ($MODE mode)"
exit 1
