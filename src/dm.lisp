;;;; dm.lisp -- requests and replies as NIP-17 private messages (NIP-59 gift wraps).
;;;;
;;;; The sender is the key that SIGNED THE SEAL: UNWRAP-RUMOR fails closed unless the
;;;; wrap, the seal and the rumor all verify and the rumor's author is the seal's
;;;; signer.  Only kind-14 rumors are messages -- a Marmot Welcome is a kind-444
;;;; rumor in a wrap to the same key, and must not be read as a request.
;;;;
;;;; RESTARTS.  A rumor stamped before the FLOOR is not answered.  The floor is fixed
;;;; at start: the newest rumor answered last time (DIR/dm.state), or now.  It does
;;;; not advance during a session, so a wrap that arrives out of order is not
;;;; skipped; within a session the wrap's id deduplicates.  Wraps may be backdated
;;;; by up to two days (NIP-59), so the subscription reaches back that far.
;;;;
;;;; RELAYS.  The emissary publishes its kind-10050 list (where to DM it) and adds
;;;; each principal's -- and, for a principal named by NIP-05, the relays that names
;;;; -- so a reply reaches a relay the principal reads.

(in-package #:emissary)

(defconstant +dm-relays-kind+ 10050)

(defun %state-file (e) (merge-pathnames "dm.state" (emissary-dir e)))

(defun %read-watermark (e)
  (ignore-errors
    (with-open-file (in (%state-file e))
      (let ((v (read in nil nil))) (and (integerp v) v)))))

(defun %dm-advance (e request)
  (let ((c (request-created request)))
    (when (and (integerp c) (> c (emissary-watermark e)))
      (setf (emissary-watermark e) c)
      (ignore-errors
        (with-open-file (o (%state-file e) :direction :output :if-exists :supersede)
          (format o "~d~%" c))))))

(defun %principal-relays (e)
  "Relays the principals name: NIP-05 relay hints and their kind-10050 lists."
  (let ((out '()))
    (loop for spec being the hash-values of (emissary-principals e)
          when (find #\@ spec)
            do (dolist (r (ignore-errors (nth-value 1 (nip05:resolve spec)))) (push r out)))
    (ignore-errors
      (dolist (ev (pool:fetch-events (emissary-pool e)
                                     (list (filter:make-filter :kinds (list +dm-relays-kind+)
                                                               :authors (principals e)))
                                     :timeout 5))
        (dolist (r (event:tag-values ev "relay")) (push r out))))
    (remove-duplicates out :test #'string=)))

(defun %dm-start (e)
  (setf (emissary-floor e) (or (%read-watermark e) (unix-now))
        (emissary-watermark e) (emissary-floor e))
  (let ((p (pool:make-pool (emissary-relays e) :timeout 15)))
    (setf (emissary-pool e) p)
    (ignore-errors
      (pool:pool-publish p (event:build-event (keys:keypair-from-secret (emissary-secret e))
                                              +dm-relays-kind+ ""
                                              :tags (mapcar (lambda (r) (list "relay" r))
                                                            (emissary-relays e)))))
    (dolist (r (%principal-relays e))
      (unless (member r (pool:pool-relay-urls p) :test #'string=)
        (ignore-errors (pool:add-relay p r))))
    (pool:pool-subscribe
     p (list (filter:make-filter :kinds '(1059)
                                 :tags (list (cons "p" (list (emissary-pubkey e))))
                                 :since (- (emissary-floor e) (* 2 86400))))
     :on-event (lambda (wrap relay) (declare (ignore relay)) (%on-wrap e wrap)))
    (push (cons :dm #'%dm-reply) (emissary-repliers e))))

(defun %on-wrap (e wrap)
  (handler-case
      (let ((rumor (nip59:unwrap-rumor (emissary-secret e) wrap)))
        (when (and (eql (event:event-kind rumor) 14)
                   (> (event:event-created-at rumor) (emissary-floor e)))
          (enqueue e (%make-request :transport :dm
                                    :sender (event:event-pubkey rumor)
                                    :text (event:event-content rumor)
                                    :created (event:event-created-at rumor))
                   (event:event-id wrap))))
    ;; a wrap we cannot open is not for us (spam, a mistargeted p tag)
    (error (c) (log-line e "dm: could not open ~a: ~a" (event:event-id wrap) c))))

(defun %dm-publish (e recipient text after)
  "Send TEXT to RECIPIENT (hex) as numbered DMs in order, the first stamped after
AFTER.  Returns the last one's created_at."
  (dolist (body (numbered-chunks text) after)
    (let ((wrap (if after
                    (nip59:build-giftwrap (emissary-secret e) recipient body :after after)
                    (nip59:build-giftwrap (emissary-secret e) recipient body))))
      (pool:pool-publish (emissary-pool e) wrap)
      (setf after (event:event-created-at wrap)))))

(defun %dm-reply (e request text)
  (%dm-publish e (request-sender request) text (request-created request)))

(defun send-dm (e who text)
  "DM TEXT to WHO (an npub, hex key or NIP-05 address) unprompted -- a greeting, a
notice.  Needs the DM relays started."
  (let ((key (or (%hex-key who)
                 (and (find #\@ who) (ignore-errors (nip05:resolve-pubkey who))))))
    (unless key (error "emissary: ~a names no key" who))
    (unless (emissary-pool e) (error "emissary: no DM relays (start it with :relays)"))
    (%dm-publish e (string-downcase key) text nil)
    t))
