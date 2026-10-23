;;;; fips.lisp -- requests and replies as FIPS DataPackets.
;;;;
;;;; The emissary runs a FIPS node under its own key, so its FIPS npub is its Nostr
;;;; npub.  A request is a DataPacket to *FIPS-PORT*; its sender is the static key the
;;;; FSP session AUTHENTICATED (cl-fips refuses a session whose source address does
;;;; not match that key), and the reply goes back to the port it came from.  A
;;;; packet is one datagram: a request must fit FIPS's MTU (1280 on UDP) and a reply
;;;; is cut to *FIPS-MAX-REPLY* bytes.  cl-fips is optional: loaded only when FIPS is
;;;; attached.

(in-package #:emissary)

(defvar *fips-port* 4601 "The FIPS port the emissary answers on.")
(defvar *fips-max-reply* 1000 "Bytes of reply text in one DataPacket.")

(defun %fips (name &rest args)
  (apply (or (find-symbol name "CL-FIPS.DAEMON") (error "emissary: cl-fips/daemon is not loaded")) args))

(defun %fips-peer-key (daemon src)
  "The 33-byte key the session with node address SRC authenticated, or NIL."
  (let ((fi (funcall (find-symbol "NODE-SESSION" "CL-FIPS") (%fips "DAEMON-NODE" daemon) src)))
    (and fi (funcall (find-symbol "FSP-INITIATOR-PEER-STATIC" "CL-FIPS") fi))))

(defun %fit (text max)
  (let ((b (u:string->utf8 text)))
    (if (> (length b) max) (subseq b 0 max) b)))

(defun attach-fips (e &key (udp "0.0.0.0:2121") peers (port *fips-port*))
  "Run a FIPS node for E under its key, listening on UDP (\"host:port\"), dialling
PEERS (cl-fips config entries), and handle DataPackets to PORT from principals.
Returns the daemon."
  (let* ((kp (funcall (find-symbol "KEYPAIR-FROM-SECRET" "SECP256K1-FAST.ECDH")
                      (keys:secret-key-of (emissary-keypair e))))   ; copied into the FIPS keypair
         (d (%fips "MAKE-DAEMON" (list :udp (list :bind udp) :peers peers)
                   :keypair kp :log (make-broadcast-stream)
                   :on-event
                   (lambda (daemon ev)
                     (when (and (eq (first ev) :data) (eql (fourth ev) port))
                       (destructuring-bind (src sp dp data ts) (rest ev)
                         (declare (ignore dp))
                         (let ((key (%fips-peer-key daemon src)))
                           (if (null key)
                               (log-line e "fips: a packet with no authenticated session; dropped")
                               (enqueue e (%make-request :transport :fips
                                                         :sender (u:bytes->hex (subseq key 1))
                                                         :text (u:utf8->string data)
                                                         :created ts
                                                         :data (list :peer-key key :src-port sp)))))))))))
    (%fips "DAEMON-START" d)
    (push (cons :fips (lambda (e) (declare (ignore e)) (%fips "DAEMON-STEP" d :max-wait-ms 20)))
          (emissary-transports e))
    (push (cons :fips (lambda (e request text) (declare (ignore e))
                        (let ((data (request-data request)))
                          (%fips "DAEMON-SEND" d (getf data :peer-key) (%fit text *fips-max-reply*)
                                 :src-port port :dst-port (getf data :src-port)))))
          (emissary-repliers e))
    (push (lambda () (%fips "DAEMON-STOP" d)) (emissary-stoppers e))
    (log-line e "fips: node on udp port ~a, answering port ~a" (%fips "DAEMON-UDP-PORT" d) port)
    d))
