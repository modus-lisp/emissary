;;;; package.lisp

(defpackage #:emissary
  (:use #:cl)
  (:local-nicknames (#:keys #:cl-nostr.keys)
                    (#:bech32 #:cl-nostr.bech32)
                    (#:event #:cl-nostr.event)
                    (#:filter #:cl-nostr.filter)
                    (#:relay #:cl-nostr.relay)
                    (#:pool #:cl-nostr.pool)
                    (#:nip05 #:cl-nostr.nip05)
                    (#:nip59 #:cl-nostr.nip59)
                    (#:u #:cl-nostr.util))
  (:export
   ;; the emissary
   #:emissary #:make-emissary #:emissary-npub #:emissary-pubkey #:emissary-dir
   #:emissary-start #:emissary-step #:emissary-run #:emissary-stop #:emissary-running-p
   #:emissary-handler #:emissary-on-log
   ;; principals: who it serves
   #:allow #:authorized-p #:principals #:load-allowlist
   ;; requests, as a handler sees them
   #:request #:request-transport #:request-sender #:request-text #:request-created
   ;; saying something unprompted
   #:send-dm
   ;; transports beyond DMs
   #:attach-marmot #:*marmot-interval*
   #:attach-fips #:*fips-port* #:*fips-max-reply*
   ;; the default handler: a fresh, killable modus process per request
   #:sandboxed-eval #:sandbox-evaluate #:format-result #:ensure-core
   #:*modus-binary* #:*eval-timeout* #:*max-reply*
   ;; utilities
   #:split-text #:*chunk-chars* #:*max-chunks*))
