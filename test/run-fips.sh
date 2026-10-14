#!/bin/bash
# test/run-fips.sh [MODUS] -- the agent on modus runs a FIPS node; an SBCL cl-fips
# node dials it over UDP on localhost and sends forms as DataPackets.
set -u
M=$(readlink -f "${1:-modus}")
# EMISSARY_LISP=sbcl runs the emissary itself on SBCL (children are still modus)
if [ "${EMISSARY_LISP:-modus}" = sbcl ]; then RUN="sbcl --dynamic-space-size 4096 --script"; else RUN="$M --script"; fi
W=$(mktemp -d /tmp/emissary-fips.XXXXXX)
UPORT=$(python3 -c 'import socket; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
trap 'touch $W/stop; sleep 2; kill $AGENT_PID 2>/dev/null' EXIT
keys=$(sbcl --script <(echo '(require :asdf) (load "/home/claude/peek-2026-10-13/emissary/test/deps.lisp") (asdf:load-system "cl-nostr")
  (dolist (i (list 1 2 3)) (let ((k (cl-nostr.keys:generate-keypair))) (format t "~a ~a ~a~%" (cl-nostr.keys:secret-hex k) (cl-nostr.keys:public-hex k) (cl-nostr.bech32:npub-encode (cl-nostr.keys:public-hex k)))))') 2>/dev/null)
read AGENT_SEC AGENT_PUB AGENT_NPUB CLIENT_SEC CLIENT_PUB CLIENT_NPUB STRANGER_SEC STRANGER_PUB STRANGER_NPUB <<< $(echo $keys)
mkdir -p $W/agent
echo $AGENT_SEC > $W/agent/emissary.key
echo "$CLIENT_NPUB" > $W/agent/allow.txt
EMISSARY_DIR=$W/agent/ EMISSARY_STOP=$W/stop MODUS_BIN=$M EMISSARY_TIMEOUT=5 EMISSARY_FIPS_UDP=127.0.0.1:$UPORT \
  $RUN test/run-emissary.lisp > $W/agent.log 2>&1 &
AGENT_PID=$!
for i in $(seq 1 300); do [ -f $W/agent/ready ] && break; sleep 1; done
[ -f $W/agent/ready ] || { echo "FAIL: agent never came up"; grep -av WARN $W/agent.log | tail -20; exit 1; }
echo "agent up: $(cat $W/agent/ready) on udp $UPORT"
CLIENT_KEY=$CLIENT_SEC STRANGER_KEY=$STRANGER_SEC AGENT_NPUB=$AGENT_NPUB AGENT_ADDR=127.0.0.1:$UPORT \
  sbcl --script test/fips-client.lisp 2>&1 | grep -av "^;\|^WARNING\|^$"
rc=${PIPESTATUS[0]}
echo "--- agent log:"; grep -a "\[emissary\]" $W/agent.log
# "no reply" proves nothing unless the stranger's request REACHED the agent and was refused
if grep -aq "FIPS: refused $STRANGER_PUB" $W/agent.log; then echo "  ok   the agent saw the stranger's request and refused it"
else echo "  FAIL the stranger's request never reached the agent's allowlist check"; rc=1; fi
exit $rc
