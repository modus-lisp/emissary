;;;; emissary.asd

(defsystem "emissary"
  :description "Authenticated execution over Nostr: a key that answers requests from
                the principals it serves -- gift-wrapped DMs (NIP-17), Marmot (MLS)
                groups, FIPS -- by an authenticated sender, with a pluggable handler
                (by default each request is evaluated in a fresh, killable modus
                process)."
  :version "0.1.0"
  :author "ynniv"
  :license "MIT"
  :depends-on ("cl-nostr" "bordeaux-threads")
  :serial t
  :components ((:module "src"
                :serial t
                :components ((:file "package")
                             (:file "util")
                             (:file "sandbox")
                             (:file "emissary")
                             (:file "dm")
                             (:file "marmot")
                             (:file "fips")))))
