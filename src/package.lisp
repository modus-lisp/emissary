;;;; package.lisp

(defpackage #:modus-agent
  (:use #:cl)
  (:nicknames #:agent)
  (:local-nicknames (#:keys #:cl-nostr.keys)
                    (#:bech32 #:cl-nostr.bech32)
                    (#:event #:cl-nostr.event)
                    (#:filter #:cl-nostr.filter)
                    (#:relay #:cl-nostr.relay)
                    (#:pool #:cl-nostr.pool)
                    (#:nip59 #:cl-nostr.nip59))
  (:export
   ;; the evaluator
   #:ensure-core #:evaluate #:*modus-binary* #:*eval-timeout* #:*max-reply*
   ;; the agent
   #:agent #:make-agent #:agent-npub #:agent-pubkey #:run-agent #:agent-step
   #:load-allowlist #:authorized-p
   ;; transports beyond gift wraps
   #:attach-marmot #:*marmot-interval*))
