;;;; giftwrap.lisp -- requests and replies as NIP-17 private messages (NIP-59
;;;; gift wraps) through a relay pool.
;;;;
;;;; The sender is the key that SIGNED THE SEAL (UNWRAP-GIFTWRAP checks the seal and
;;;; that the rumor names the same author), so the allowlist is checked against an
;;;; authenticated identity, not a claim.  A wrap from anyone else is dropped with a
;;;; log line and no reply: the agent does not confirm it exists to strangers.

(in-package #:modus-agent)

(defun %unix-now () (- (get-universal-time) 2208988800))

(defun giftwrap-subscribe (agent)
  "Subscribe AGENT's pool to gift wraps addressed to it.  NIP-59 backdates the
SEAL, not the wrap, so a small SINCE window is enough."
  (pool:pool-subscribe
   (agent-pool agent)
   (list (filter:make-filter :kinds '(1059)
                             :tags (list (cons "p" (list (agent-pubkey agent))))
                             :since (- (%unix-now) 120)))
   :on-event (lambda (wrap relay)
               (declare (ignore relay))
               (handler-case
                   (multiple-value-bind (text sender created)
                       (nip59:unwrap-giftwrap (agent-secret agent) wrap)
                     (enqueue agent (list :transport :giftwrap :sender sender
                                          :text text :created created
                                          :id (event:event-id wrap))))
                 (error (e) (log-line agent "giftwrap: could not open ~a: ~a"
                                      (event:event-id wrap) e))))))

(defun giftwrap-reply (agent request text)
  (pool:pool-publish (agent-pool agent)
                     (nip59:build-giftwrap (agent-secret agent) (getf request :sender) text
                                           :after (getf request :created))))
