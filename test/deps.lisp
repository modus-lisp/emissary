;;;; test/deps.lisp -- make emissary's dependencies loadable, on SBCL or modus.
;;;;
;;;; The modus-lisp libraries (natrium, secp256k1-fast, seal, cl-nostr, json-simple,
;;;; and for the optional transports cl-marmot, cl-fips, cl-transport) are looked for
;;;; in $MODUS_LISP and beside this checkout.  The few third-party systems
;;;; (bordeaux-threads and what it needs) come from Quicklisp on SBCL when it is
;;;; installed, or from the subdirectories of $EMISSARY_EXTRA (colon-separated).
(require :asdf)
#+sbcl (require :sb-bsd-sockets)
(let* ((here (make-pathname :name nil :type nil
                            :defaults (or *load-truename* *default-pathname-defaults*)))
       (repo (merge-pathnames "../" here))
       (roots (remove nil (list (let ((e (uiop:getenv "MODUS_LISP")))
                                  (and e (plusp (length e)) (uiop:ensure-directory-pathname e)))
                                (merge-pathnames "../" repo)))))
  (dolist (root roots)
    (dolist (lib '("natrium" "secp256k1-fast" "seal" "cl-nostr" "json-simple"
                   "cl-marmot" "cl-fips" "cl-transport"))
      (let ((dir (merge-pathnames (concatenate 'string lib "/") root)))
        (when (probe-file (merge-pathnames (concatenate 'string lib ".asd") dir))
          (pushnew dir asdf:*central-registry* :test #'equal)))))
  (pushnew (truename repo) asdf:*central-registry* :test #'equal)
  (let ((extra (uiop:getenv "EMISSARY_EXTRA")))
    (when (and extra (plusp (length extra)))
      (dolist (d (uiop:split-string extra :separator ":"))
        (dolist (sub (directory (merge-pathnames "*/" (uiop:ensure-directory-pathname d))))
          (push sub asdf:*central-registry*))))))
#+sbcl
(let ((ql (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
  (when (and (probe-file ql) (not (uiop:getenv "EMISSARY_EXTRA")))
    (load ql)))
