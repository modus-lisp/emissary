;;;; test/deps.lisp -- put the sibling checkouts on ASDF's path.
(require :asdf)
#+sbcl (require :sb-bsd-sockets)
(let ((root #p"/home/claude/peek-2026-10-13/"))
  (dolist (d (append (directory "/home/claude/nostr-eval/deps/*/")
                     (mapcar (lambda (n) (merge-pathnames n root))
                             '("secp256k1-fast/" "seal/" "natrium-stock/" "cl-nostr/" "cl-marmot/" "cl-fips/" "cl-transport/" "modus-agent/"))
                     (list #p"/home/claude/modus-lisp/json-simple/")))
    (push d asdf:*central-registry*)))
