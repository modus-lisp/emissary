;;;; fips.lisp -- requests and replies as FIPS DataPackets.
;;;;
;;;; The agent runs a FIPS node under its own key, so its FIPS npub is its Nostr npub
;;;; and one allowlist entry covers a person on every transport.  A request is a
;;;; DataPacket to *FIPS-PORT*; its sender is the peer key the FSP session
;;;; AUTHENTICATED (cl-fips refuses a session whose source address does not match
;;;; that key), and the reply goes back to the port it came from.  A packet is one
;;;; datagram: a request must fit FIPS's MTU (1280 on UDP), and a reply is cut to
;;;; *FIPS-MAX-REPLY* bytes.  cl-fips is optional: loaded only when FIPS is used.

(in-package #:modus-agent)

(defvar *fips-port* 4601 "The FIPS port the agent answers on.")
(defvar *fips-max-reply* 1000 "Bytes of reply text in one DataPacket.")

(defun %fips (name &rest args)
  (apply (or (find-symbol name "CL-FIPS.DAEMON") (error "cl-fips/daemon is not loaded")) args))

(defun %fips-peer-key (daemon src)
  "The 33-byte key the session with node address SRC authenticated, or NIL."
  (let* ((node (%fips "DAEMON-NODE" daemon))
         (fi (funcall (find-symbol "NODE-SESSION" "CL-FIPS") node src)))
    (and fi (funcall (find-symbol "FSP-INITIATOR-PEER-STATIC" "CL-FIPS") fi))))

(defun %fit (text max)
  "TEXT's UTF-8 bytes, cut to MAX."
  (let ((b (cl-nostr.util:string->utf8 text)))
    (if (> (length b) max) (subseq b 0 max) b)))

(defun attach-fips (agent &key (udp "0.0.0.0:2121") peers (port *fips-port*))
  "Run a FIPS node for AGENT under its key, listening on UDP (\"host:port\"),
dialling PEERS (cl-fips config entries), and answer DataPackets to PORT from
allowlisted peers.  Requires cl-fips/daemon to be loaded.  Returns the daemon."
  (let* ((kp (funcall (find-symbol "KEYPAIR-FROM-SECRET" "SECP256K1-FAST.ECDH")
                      (cl-nostr.util:hex->bytes (agent-secret agent))))
         (d nil))
    (setf d (%fips "MAKE-DAEMON" (list :udp (list :bind udp) :peers peers)
                   :keypair kp :log (make-broadcast-stream)
                   :on-event
                   (lambda (daemon ev)
                     (when (and (eq (first ev) :data) (eql (fourth ev) port))
                       (destructuring-bind (src sp dp data ts) (rest ev)
                         (declare (ignore dp ts))
                         (let ((key (%fips-peer-key daemon src)))
                           (if (null key)
                               (log-line agent "fips: a packet with no authenticated session; dropped")
                               (enqueue agent
                                        (list :transport :fips
                                              :sender (cl-nostr.util:bytes->hex (subseq key 1))
                                              :text (cl-nostr.util:utf8->string data)
                                              :peer-key key :src-port sp)))))))))
    (%fips "DAEMON-START" d)
    (push (cons :fips (lambda (agent) (declare (ignore agent))
                        (%fips "DAEMON-STEP" d :max-wait-ms 20)))
          (agent-transports agent))
    (push (cons :fips (lambda (agent request text)
                        (declare (ignore agent))
                        (%fips "DAEMON-SEND" d (getf request :peer-key)
                               (%fit text *fips-max-reply*)
                               :src-port port :dst-port (getf request :src-port))))
          (agent-repliers agent))
    (log-line agent "fips: node ~a on udp port ~a, answering port ~a"
              (%fips "DAEMON-NPUB" d) (%fips "DAEMON-UDP-PORT" d) port)
    d))
