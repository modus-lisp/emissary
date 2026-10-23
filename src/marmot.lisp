;;;; marmot.lisp -- requests and replies in Marmot (MLS over Nostr) groups.
;;;;
;;;; The emissary's Marmot account uses the emissary's own key, so one npub is invited
;;;; to groups and messaged directly.  Anyone may invite it (a Welcome is just a gift
;;;; wrap); only a message whose MLS-authenticated sender is a principal is handled,
;;;; and the answer goes to the same group.  On modus cl-marmot talks to relays with
;;;; its :DIRECT transport, on the calling thread, so its SYNC runs inside the
;;;; emissary's loop every *MARMOT-INTERVAL* seconds.  cl-marmot is optional: loaded
;;;; only when Marmot is attached.

(in-package #:emissary)

(defvar *marmot-interval* 2 "Seconds between Marmot syncs.")

(defun %marmot (name &rest args)
  (apply (or (find-symbol name "MARMOT") (error "emissary: cl-marmot is not loaded")) args))

(defun attach-marmot (e relays &key (interval *marmot-interval*))
  "Give E a Marmot account (in its directory, under its key) on RELAYS, publish a
KeyPackage so it can be invited, and handle group messages from principals."
  (let* ((home (namestring (merge-pathnames "marmot/" (emissary-dir e))))
         (client (if (probe-file (concatenate 'string home "account.sexp"))
                     (%marmot "OPEN-ACCOUNT" home)
                     (%marmot "CREATE-ACCOUNT" :home home :relays relays :name "emissary"
                                               :nsec (bech32:nsec-encode (keys:secret-key-of (emissary-keypair e)))))))
    (%marmot "PUBLISH-KEY-PACKAGE" client)
    (%marmot "ADD-HANDLER" client
             (lambda (ev)
               (when (eq (%marmot "EVENT-TYPE" ev) :message)
                 (let ((m (%marmot "EVENT-MESSAGE" ev)))
                   (unless (%marmot "MESSAGE-OWN-P" m)
                     (enqueue e (%make-request :transport :marmot
                                               :sender (%marmot "MESSAGE-SENDER" m)
                                               :text (%marmot "MESSAGE-CONTENT" m)
                                               :created (%marmot "MESSAGE-CREATED-AT" m)
                                               :data (list :chat (%marmot "EVENT-CHAT" ev)))
                              (%marmot "MESSAGE-ID" m)))))))
    (let ((next 0))
      (push (cons :marmot (lambda (e) (declare (ignore e))
                            (when (>= (get-universal-time) next)
                              (setf next (+ (get-universal-time) interval))
                              (%marmot "SYNC" client))))
            (emissary-transports e)))
    (push (cons :marmot (lambda (e request text) (declare (ignore e))
                          (%marmot "SEND" client (getf (request-data request) :chat) text)))
          (emissary-repliers e))
    (push (lambda () (%marmot "CLOSE-ACCOUNT" client)) (emissary-stoppers e))
    (log-line e "marmot: account ready, KeyPackage published to ~a" relays)
    client))
