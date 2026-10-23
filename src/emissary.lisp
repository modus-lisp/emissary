;;;; emissary.lisp -- an identity, the principals it serves, its transports, one loop.
;;;;
;;;; An EMISSARY is a key that acts for the principals on its allowlist.  Requests
;;;; arrive on its transports -- NIP-17 DMs (dm.lisp), Marmot groups (marmot.lisp),
;;;; FIPS (fips.lisp) -- and every one carries a sender the transport AUTHENTICATED:
;;;; the key that signed a gift wrap's seal, a Marmot message's MLS sender, a FIPS
;;;; session's static key.  A request from a principal goes to the HANDLER, whose
;;;; answer goes back the way the request came; anyone else gets silence and a log
;;;; line (the emissary does not confirm it exists to strangers).  One key serves
;;;; every transport, so one allowlist entry covers a person everywhere.
;;;;
;;;; ONE THREAD drives it: EMISSARY-STEP pumps the relays (CL-NOSTR.RELAY:PUMP),
;;;; steps the other transports, then handles what came in.  On modus that is not a
;;;; choice -- a connection belongs to the thread that drives it -- and on SBCL,
;;;; where cl-nostr's relay threads deliver, the queue they deliver into is locked.

(in-package #:emissary)

(defstruct (request (:constructor %make-request))
  transport          ; :dm, :marmot or :fips
  sender             ; the authenticated sender's x-only pubkey, 64 hex
  text               ; what they sent
  created            ; unix time the sender stamped it, when the transport has one
  data)              ; the transport's own reply information (a plist)

(defstruct (emissary (:constructor %make-emissary))
  dir                ; key, allowlist, state, the sandbox core
  keypair            ; cl-nostr keypair: the secret lives in fixed memory
  pubkey             ; x-only public key, 64 hex
  (principals (make-hash-table :test 'equal))   ; pubkey hex -> how it was named
  (handler 'sandboxed-eval)                       ; (function request) -> reply text or NIL
  (relays '())       ; relay URLs for DMs
  pool               ; cl-nostr pool, once started with relays
  (queue '())        ; requests not yet handled, oldest first
  (lock (bt:make-lock "emissary"))
  (seen (make-hash-table :test 'equal))          ; request ids already queued
  (transports '())   ; (name . step-function)
  (repliers '())     ; (name . reply-function)
  (stoppers '())     ; functions run by EMISSARY-STOP
  (floor 0)          ; DMs: ignore rumors stamped before this (fixed at start)
  (watermark 0)      ; DMs: newest rumor answered; persisted for the next start's FLOOR
  (running nil)
  (on-log nil))      ; (function string), or NIL to print

(defun log-line (e fmt &rest args)
  (let ((line (format nil "~?" fmt args)))
    (if (emissary-on-log e)
        (ignore-errors (funcall (emissary-on-log e) line))
        (progn (format t "~&[emissary] ~a~%" line) (finish-output)))))

(defun emissary-npub (e) (bech32:npub-encode (emissary-pubkey e)))
(defun emissary-running-p (e) (emissary-running e))

;;; ---- principals ------------------------------------------------------------

(defun %hex-key (s)
  "A key given as npub or hex, as lowercase hex; NIL if it is neither."
  (let ((s (string-trim '(#\Space #\Tab #\Return #\Newline) s)))
    (cond ((and (> (length s) 5) (string= "npub1" (subseq s 0 5)))
           (ignore-errors (let ((k (bech32:npub-decode s)))
                            (if (stringp k) (string-downcase k) (u:bytes->hex k)))))
          ((and (= (length s) 64) (every (lambda (c) (digit-char-p c 16)) s))
           (string-downcase s))
          (t nil))))

(defun allow (e who)
  "Add WHO -- an npub, a hex pubkey, or a NIP-05 address (resolved now) -- to E's
principals.  Returns the pubkey, or NIL (logged) if WHO names none."
  (let ((key (or (%hex-key who)
                 (and (find #\@ who)
                      (ignore-errors (let ((k (nip05:resolve-pubkey who))) (and k (string-downcase k))))))))
    (if key
        (setf (gethash key (emissary-principals e)) who)
        (log-line e "allow: ~a names no key; skipped" who))
    key))

(defun load-allowlist (e path)
  "Principals from PATH: one npub, hex key or NIP-05 address per line; # comments."
  (when (probe-file path)
    (with-open-file (in path)
      (loop for line = (read-line in nil) while line
            do (let* ((spec (string-trim '(#\Space #\Tab #\Return) (subseq line 0 (position #\# line)))))
                 (when (plusp (length spec)) (allow e spec))))))
  (hash-table-count (emissary-principals e)))

(defun principals (e)
  (loop for k being the hash-keys of (emissary-principals e) collect k))

(defun authorized-p (e pubkey-hex)
  (and pubkey-hex (gethash (string-downcase pubkey-hex) (emissary-principals e)) t))

;;; ---- identity --------------------------------------------------------------

(defun %load-keypair (dir)
  "The emissary's keypair, from DIR/emissary.key (hex, made on first use, mode 0600).
The secret goes straight into fixed memory; the hex text read from the file is
overwritten once it has been decoded."
  (let ((path (merge-pathnames "emissary.key" dir)))
    (unless (probe-file path)
      (let* ((kp (keys:generate-keypair)) (hex (keys:secret-hex kp)))   ; an explicit export, to the file
        (with-open-file (o path :direction :output)
          (write-line hex o))
        (fill hex #\0) (keys:keypair-wipe kp)
        (ignore-errors (uiop:run-program (list "chmod" "600" (namestring path))))))
    (let ((line (with-open-file (in path) (read-line in))))
      (unwind-protect (keys:keypair-from-secret (string-trim '(#\Space #\Newline #\Return) line))
        (fill line #\0)))))

(defun make-emissary (&key (dir (merge-pathnames ".emissary/" (user-homedir-pathname)))
                           relays allow (handler 'sandboxed-eval) on-log)
  "An emissary working in DIR: its key (emissary.key, made on first use), its
principals (DIR/allow.txt, plus ALLOW, a list of npubs / hex keys / NIP-05
addresses), and, for the default handler, its sandbox core.  RELAYS: relay URLs
for DMs; without them DMs are off.  Call EMISSARY-START, then EMISSARY-RUN or
EMISSARY-STEP from your own loop."
  (let* ((dir (uiop:ensure-directory-pathname dir))
         (kp (progn (ensure-directories-exist dir) (%load-keypair dir)))
         (e (%make-emissary :dir dir :keypair kp
                            :pubkey (keys:public-hex kp)
                            :handler handler :relays relays :on-log on-log)))
    (setf *work-dir* dir)
    (load-allowlist e (merge-pathnames "allow.txt" dir))
    (dolist (who allow) (allow e who))
    e))

;;; ---- the queue and the loop -----------------------------------------------

(defun enqueue (e request &optional id)
  "Queue REQUEST (once per ID).  Safe from any thread."
  (bt:with-lock-held ((emissary-lock e))
    (unless (and id (gethash id (emissary-seen e)))
      (when id (setf (gethash id (emissary-seen e)) t))
      (setf (emissary-queue e) (append (emissary-queue e) (list request))))))

(defun %next (e)
  (bt:with-lock-held ((emissary-lock e)) (pop (emissary-queue e))))

(defun %handle (e request)
  (let ((sender (request-sender request))
        (transport (request-transport request)))
    (if (not (authorized-p e sender))
        (log-line e "~a: refused ~a (not a principal)" transport sender)
        (let* ((t0 (get-internal-real-time))
               (reply (handler-case (funcall (emissary-handler e) request)
                        (serious-condition (c) (format nil "error: ~a" c))))
               (send (cdr (assoc transport (emissary-repliers e)))))
          (log-line e "~a: ~a  answered in ~d ms" transport (subseq sender 0 12)
                    (round (* 1000 (- (get-internal-real-time) t0)) internal-time-units-per-second))
          (when (and reply send)
            (handler-case (funcall send e request reply)
              (serious-condition (c) (log-line e "~a: reply failed: ~a" transport c))))
          (when (eq transport :dm) (%dm-advance e request))))))

(defun emissary-step (e &optional (wait 0.1))
  "One turn: service the relays and the other transports, then handle what came in."
  (if (emissary-pool e) (relay:pump wait) (when (null (emissary-transports e)) (sleep wait)))
  (dolist (tr (emissary-transports e))
    (let ((t0 (get-internal-real-time)))
      (handler-case (funcall (cdr tr) e)
        (serious-condition (c) (log-line e "~a: step failed: ~a" (car tr) c)))
      (let ((ms (round (* 1000 (- (get-internal-real-time) t0)) internal-time-units-per-second)))
        (when (> ms 500) (log-line e "~a: one step took ~d ms" (car tr) ms)))))
  (loop for r = (%next e) while r do (%handle e r)))

(defun emissary-start (e)
  "Connect E's DM relays (when it has any) and start listening.  Returns E."
  (when (emissary-relays e) (%dm-start e))
  (setf (emissary-running e) t)
  (log-line e "~a  ~d principal~:p  relays ~a" (emissary-npub e)
            (hash-table-count (emissary-principals e))
            (and (emissary-pool e) (pool:pool-relay-urls (emissary-pool e))))
  e)

(defun emissary-run (e &key until)
  "Step E until EMISSARY-STOP, or until UNTIL (a function of no arguments) is true."
  (loop while (emissary-running e)
        do (emissary-step e)
           (when (and until (funcall until)) (return)))
  e)

(defun emissary-stop (e)
  (setf (emissary-running e) nil)
  (dolist (f (emissary-stoppers e)) (ignore-errors (funcall f)))
  (when (emissary-pool e) (ignore-errors (pool:close-pool (emissary-pool e))))
  (setf (emissary-pool e) nil)
  e)
