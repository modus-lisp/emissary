;;;; agent.lisp -- the agent: an identity, an allowlist, its transports, one loop.
;;;;
;;;; ONE THREAD.  On modus a connection belongs to the thread that drives it, so the
;;;; loop pumps the relays (CL-NOSTR.RELAY:PUMP), steps the other transports, and
;;;; evaluates queued requests -- each in a fresh child process (EVALUATE), so a
;;;; request cannot hold the loop longer than *EVAL-TIMEOUT*.

(in-package #:modus-agent)

(defstruct (agent (:constructor %make-agent))
  dir                ; work directory: key, allowlist, core
  secret             ; secret key, 64 hex
  pubkey             ; x-only public key, 64 hex
  allow              ; hash table of allowed pubkey hex -> T
  pool               ; cl-nostr pool
  (queue '())        ; requests not yet evaluated, oldest last
  (seen (make-hash-table :test 'equal))  ; request ids already handled
  (transports '())   ; (name . step-function) for transports other than relays
  (repliers '())     ; (name . reply-function)
  (log *standard-output*))

(defun log-line (agent fmt &rest args)
  (let ((s (agent-log agent)))
    (format s "~&[agent] ~?~%" fmt args)
    (finish-output s)))

(defun agent-npub (agent) (bech32:npub-encode (agent-pubkey agent)))

(defun %hex-key (s)
  "A pubkey given as npub or hex, as lowercase hex; NIL if neither."
  (let ((s (string-trim '(#\Space #\Tab #\Return #\Newline) s)))
    (cond ((and (> (length s) 5) (string= "npub1" (subseq s 0 5)))
           (ignore-errors (let ((k (bech32:npub-decode s)))
                            (if (stringp k) (string-downcase k) (cl-nostr.util:bytes->hex k)))))
          ((and (= (length s) 64) (every (lambda (c) (digit-char-p c 16)) s))
           (string-downcase s))
          (t nil))))

(defun load-allowlist (path)
  "Keys (npub or hex), one per line; # starts a comment."
  (let ((h (make-hash-table :test 'equal)))
    (when (probe-file path)
      (with-open-file (in path)
        (loop for line = (read-line in nil) while line
              do (let* ((cut (position #\# line))
                        (k (%hex-key (subseq line 0 cut))))
                   (when k (setf (gethash k h) t))))))
    h))

(defun authorized-p (agent pubkey-hex)
  (and pubkey-hex (gethash (string-downcase pubkey-hex) (agent-allow agent)) t))

(defun %key-file (dir)
  "The agent's secret, made (mode 0600 by umask is not guaranteed: chmod) on first run."
  (let ((path (merge-pathnames "agent.key" dir)))
    (unless (probe-file path)
      (let ((kp (keys:generate-keypair)))
        (with-open-file (o path :direction :output)
          (write-line (keys:secret-hex kp) o))
        (ignore-errors (uiop:run-program (list "chmod" "600" (namestring path))))))
    (with-open-file (in path) (string-trim '(#\Space #\Newline #\Return) (read-line in)))))

(defun make-agent (&key (dir (merge-pathnames ".modus-agent/" (user-homedir-pathname)))
                        relays (log *standard-output*))
  "An agent working in DIR: its key (agent.key, made on first use), its
allowlist (allow.txt) and the evaluation core.  RELAYS: relay URLs for gift wraps."
  (let* ((dir (uiop:ensure-directory-pathname dir))
         (_ (ensure-directories-exist dir))
         (secret (%key-file dir))
         (kp (keys:keypair-from-secret secret))
         (agent (%make-agent :dir dir :secret secret :pubkey (keys:public-hex kp)
                             :allow (load-allowlist (merge-pathnames "allow.txt" dir))
                             :log log)))
    (declare (ignore _))
    (setf *work-dir* dir)
    (ensure-core)
    (when relays
      (setf (agent-pool agent) (pool:make-pool relays :timeout 15))
      (giftwrap-subscribe agent)
      (push (cons :giftwrap #'giftwrap-reply) (agent-repliers agent)))
    (log-line agent "~a  allowlist ~d key(s)  relays ~a"
              (agent-npub agent) (hash-table-count (agent-allow agent))
              (and (agent-pool agent) (pool:pool-relay-urls (agent-pool agent))))
    agent))

(defun enqueue (agent request)
  (let ((id (getf request :id)))
    (unless (and id (gethash id (agent-seen agent)))
      (when id (setf (gethash id (agent-seen agent)) t))
      (setf (agent-queue agent) (append (agent-queue agent) (list request))))))

(defun %handle (agent request)
  (let ((sender (getf request :sender))
        (transport (getf request :transport)))
    (if (not (authorized-p agent sender))
        (log-line agent "~a: refused ~a (not on the allowlist)" transport sender)
        (let* ((t0 (get-internal-real-time))
               (result (evaluate (getf request :text)))
               (text (format-result result))
               (reply (cdr (assoc transport (agent-repliers agent)))))
          (log-line agent "~a: ~a  ~a in ~d ms" transport (subseq sender 0 12) (first result)
                    (round (* 1000 (- (get-internal-real-time) t0)) internal-time-units-per-second))
          (if reply
              (handler-case (funcall reply agent request text)
                (error (e) (log-line agent "~a: reply failed: ~a" transport e)))
              (log-line agent "~a: no way to reply" transport))))))

(defun agent-step (agent &optional (wait 0.1))
  "One turn: service the relays and the other transports, then handle what came in."
  (when (agent-pool agent) (relay:pump wait))
  (dolist (tr (agent-transports agent)) (ignore-errors (funcall (cdr tr) agent)))
  (loop while (agent-queue agent)
        do (%handle agent (pop (agent-queue agent)))))

(defun run-agent (agent &key until)
  "Run AGENT's loop forever, or until UNTIL (a function of no arguments) is true."
  (loop (agent-step agent)
        (when (and until (funcall until)) (return agent))))
