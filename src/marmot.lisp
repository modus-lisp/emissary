;;;; marmot.lisp -- requests and replies in Marmot (MLS over Nostr) groups.
;;;;
;;;; The agent's Marmot account uses the agent's own key, so one npub is invited to
;;;; groups and messaged directly.  Anyone may invite it (a Welcome is just a gift
;;;; wrap), but only a message whose MLS-authenticated sender is on the allowlist
;;;; is evaluated, and the answer goes to the same group.  On modus cl-marmot talks
;;;; to relays with its :DIRECT transport on the calling thread, so MARMOT:SYNC runs
;;;; inside the agent's loop, every *MARMOT-INTERVAL* seconds.

(in-package #:modus-agent)

(defvar *marmot-interval* 2 "Seconds between Marmot syncs.")

(defun %pkg-sym (name pkg) (find-symbol name pkg))
(defun %marmot (name &rest args)
  "Call MARMOT:NAME (cl-marmot is optional: loaded only when Marmot is used)."
  (apply (or (%pkg-sym name "MARMOT") (error "cl-marmot is not loaded")) args))

(defun attach-marmot (agent relays &key (interval *marmot-interval*))
  "Give AGENT a Marmot account (in its directory, under its key), publish a
KeyPackage so it can be invited, and serve group messages from allowlisted
members.  Requires cl-marmot to be loaded."
  (let* ((home (namestring (merge-pathnames "marmot/" (agent-dir agent))))
         (client (if (probe-file (concatenate 'string home "account.sexp"))
                     (%marmot "OPEN-ACCOUNT" home)
                     (%marmot "CREATE-ACCOUNT" :home home :relays relays :name "modus agent"
                              :nsec (bech32:nsec-encode (agent-secret agent))))))
    (%marmot "PUBLISH-KEY-PACKAGE" client)
    (%marmot "ADD-HANDLER" client
             (lambda (e)
               (when (eq (%marmot "EVENT-TYPE" e) :message)
                 (let ((m (%marmot "EVENT-MESSAGE" e)))
                   (unless (%marmot "MESSAGE-OWN-P" m)
                     (enqueue agent (list :transport :marmot
                                          :sender (%marmot "MESSAGE-SENDER" m)
                                          :text (%marmot "MESSAGE-CONTENT" m)
                                          :chat (%marmot "EVENT-CHAT" e)
                                          :id (%marmot "MESSAGE-ID" m))))))))
    (let ((next 0))
      (push (cons :marmot
                  (lambda (agent)
                    (declare (ignore agent))
                    (when (>= (get-universal-time) next)
                      (setf next (+ (get-universal-time) interval))
                      (%marmot "SYNC" client))))
            (agent-transports agent)))
    (push (cons :marmot (lambda (agent request text)
                          (declare (ignore agent))
                          (%marmot "SEND" client (getf request :chat) text)))
          (agent-repliers agent))
    (log-line agent "marmot: account ready, KeyPackage published to ~a" relays)
    client))
