#!/bin/bash
# test/run-all.sh [MODUS] -- ONE agent on modus serving all three transports at
# once (gift-wrapped DMs, a Marmot group, FIPS) to SBCL clients, against a
# throwaway nak relay.  The Marmot Welcome also reaches the DM subscription (it is
# a gift wrap to the same key): it must be ignored there, not evaluated.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd); cd "$HERE"
M=$(readlink -f "${1:-modus}")
# EMISSARY_LISP=sbcl runs the emissary itself on SBCL (children are still modus)
if [ "${EMISSARY_LISP:-modus}" = sbcl ]; then RUN="sbcl --dynamic-space-size 4096 --script"; else RUN="$M --script"; fi
W=$(mktemp -d /tmp/emissary-all.XXXXXX)
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
UPORT=$(python3 -c 'import socket; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
RELAY="ws://127.0.0.1:$PORT"
nak serve --hostname 127.0.0.1 --port $PORT -q > $W/relay.log 2>&1 &
RELAY_PID=$!
trap 'touch $W/stop; sleep 2; kill $RELAY_PID $AGENT_PID 2>/dev/null' EXIT
keys=$(sbcl --script <(echo '(require :asdf) (load "'"$HERE"'/test/deps.lisp") (asdf:load-system "cl-nostr")
  (dolist (i (list 1 2 3)) (let ((k (cl-nostr.keys:generate-keypair))) (format t "~a ~a ~a~%" (cl-nostr.keys:secret-hex k) (cl-nostr.keys:public-hex k) (cl-nostr.bech32:npub-encode (cl-nostr.keys:public-hex k)))))') 2>/dev/null)
read AGENT_SEC AGENT_PUB AGENT_NPUB CLIENT_SEC CLIENT_PUB CLIENT_NPUB STRANGER_SEC STRANGER_PUB STRANGER_NPUB <<< $(echo $keys)
mkdir -p $W/agent
echo $AGENT_SEC > $W/agent/emissary.key
echo "$CLIENT_NPUB   # the one allowlisted person, on every transport" > $W/agent/allow.txt
EMISSARY_DIR=$W/agent/ EMISSARY_RELAY=$RELAY EMISSARY_STOP=$W/stop MODUS_BIN=$M EMISSARY_TIMEOUT=3 \
  EMISSARY_MARMOT=1 EMISSARY_FIPS_UDP=127.0.0.1:$UPORT \
  $RUN test/run-emissary.lisp > $W/agent.log 2>&1 &
AGENT_PID=$!
for i in $(seq 1 300); do [ -f $W/agent/ready ] && break; sleep 1; done
[ -f $W/agent/ready ] || { echo "FAIL: agent never came up"; grep -av WARN $W/agent.log | tail -20; exit 1; }
echo "agent up: $AGENT_NPUB  relay $RELAY  fips udp $UPORT"
rc=0
echo "== Marmot"
CLIENT_KEY=$CLIENT_SEC AGENT_PUB=$AGENT_PUB AGENT_RELAY=$RELAY CLIENT_HOME=$W/client/ \
  sbcl --dynamic-space-size 4096 --script test/marmot-client.lisp 2>&1 | grep -a "ok\|FAIL\|CLIENT"
[ ${PIPESTATUS[0]} = 0 ] || rc=1
echo "== gift-wrapped DMs"
CLIENT_KEY=$CLIENT_SEC STRANGER_KEY=$STRANGER_SEC AGENT_PUB=$AGENT_PUB AGENT_RELAY=$RELAY \
  sbcl --script test/client.lisp 2>&1 | grep -a "ok\|FAIL\|CLIENT"
[ ${PIPESTATUS[0]} = 0 ] || rc=1
echo "== FIPS"
CLIENT_KEY=$CLIENT_SEC STRANGER_KEY=$STRANGER_SEC AGENT_NPUB=$AGENT_NPUB AGENT_ADDR=127.0.0.1:$UPORT \
  sbcl --script test/fips-client.lisp 2>&1 | grep -a "ok\|FAIL\|CLIENT"
[ ${PIPESTATUS[0]} = 0 ] || rc=1
echo "== the agent"
grep -a "\[emissary\]" $W/agent.log
n=$(grep -ac "refused $STRANGER_PUB" $W/agent.log)
[ "$n" -ge 2 ] && echo "  ok   the stranger was refused on DMs and FIPS ($n)" || { echo "  FAIL stranger refusals: $n"; rc=1; }
grep -aq "MARMOT:.*answered" $W/agent.log && grep -aq "DM:.*answered" $W/agent.log && grep -aq "FIPS:.*answered" $W/agent.log \
  && echo "  ok   one agent answered on all three transports" || { echo "  FAIL not all three transports answered"; rc=1; }

echo "ALL: $([ $rc = 0 ] && echo PASS || echo FAIL)"
exit $rc
