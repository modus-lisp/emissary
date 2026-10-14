;;;; modus-agent.asd

(defsystem "modus-agent"
  :description "Evaluate Lisp forms sent by authorized Nostr keys -- gift-wrapped
                DMs, Marmot groups, FIPS -- each in a fresh, killable modus process."
  :version "0.1.0"
  :author "ynniv"
  :license "MIT"
  :depends-on ("cl-nostr")
  :serial t
  :components ((:module "src"
                :serial t
                :components ((:file "package")
                             (:file "evaluator")
                             (:file "agent")
                             (:file "giftwrap")
                             (:file "marmot")
                             (:file "fips")))))
