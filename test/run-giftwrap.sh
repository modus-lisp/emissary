#!/bin/bash
# test/run-giftwrap.sh [MODUS] -- the agent on modus, an SBCL client, a throwaway
# nak relay on localhost: gift-wrapped requests in, gift-wrapped replies out.
set -u
M=$(readlink -f "${1:-modus}")
W=$(mktemp -d /tmp/modus-agent.XXXXXX)
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
RELAY="ws://127.0.0.1:$PORT"
nak serve --hostname 127.0.0.1 --port $PORT -q > $W/relay.log 2>&1 &
RELAY_PID=$!
trap 'touch $W/stop; sleep 2; kill $RELAY_PID $AGENT_PID 2>/dev/null' EXIT
keys=$(sbcl --script <(echo '(require :asdf) (load "/home/claude/peek-2026-10-13/modus-agent/test/deps.lisp") (asdf:load-system "cl-nostr")
  (dolist (i (list 1 2 3)) (let ((k (cl-nostr.keys:generate-keypair))) (format t "~a ~a~%" (cl-nostr.keys:secret-hex k) (cl-nostr.keys:public-hex k))))') 2>/dev/null)
read AGENT_SEC AGENT_PUB CLIENT_SEC CLIENT_PUB STRANGER_SEC STRANGER_PUB <<< $(echo $keys)
mkdir -p $W/agent
echo $AGENT_SEC > $W/agent/agent.key
echo "$CLIENT_PUB   # the test client" > $W/agent/allow.txt
AGENT_DIR=$W/agent/ AGENT_RELAY=$RELAY AGENT_STOP=$W/stop MODUS_BIN=$M AGENT_TIMEOUT=3 \
  $M --script test/run-agent.lisp > $W/agent.log 2>&1 &
AGENT_PID=$!
for i in $(seq 1 120); do [ -f $W/agent/ready ] && break; sleep 1; done
[ -f $W/agent/ready ] || { echo "FAIL: agent never came up"; grep -v WARN $W/agent.log | tail; exit 1; }
echo "agent up: $(cat $W/agent/ready)"
CLIENT_KEY=$CLIENT_SEC STRANGER_KEY=$STRANGER_SEC AGENT_PUB=$AGENT_PUB AGENT_RELAY=$RELAY \
  sbcl --script test/client.lisp 2>&1 | grep -v "^;"
rc=${PIPESTATUS[0]}
echo "--- agent log:"; grep -a "\[agent\]" $W/agent.log
exit $rc
