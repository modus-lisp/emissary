;;;; test/unit.lisp -- emissary without a network: chunking, principals, dispatch.
;;;;   sbcl --script test/unit.lisp      (or: modus --script test/unit.lisp)
;;;; With MODUS_BIN set, also one request through the sandbox.
(load (merge-pathnames "deps.lisp" (make-pathname :name nil :type nil :defaults *load-truename*)))
(asdf:load-system "emissary")
(defpackage :unit (:use :cl))
(in-package :unit)
(defvar *checks* 0) (defvar *fails* 0)
(defun chk (name got want)
  (incf *checks*)
  (unless (equal got want) (incf *fails*) (format t "~&FAIL ~a~%   got  ~s~%   want ~s~%" name got want)))

;; chunking
(chk "short text is one chunk" (emissary:split-text "hello" 10) '("hello"))
(chk "splits at a word" (emissary:split-text "aaaa bbbb cccc" 9) '("aaaa bbbb" "cccc"))
(chk "prefers a paragraph" (emissary:split-text (format nil "one two~%~%three four") 15)
     (list "one two" "three four"))
(chk "numbered when split" (emissary::numbered-chunks "aaaa bbbb cccc" :max 9) '("(1/2) aaaa bbbb" "(2/2) cccc"))
(chk "capped, and says so" (length (emissary::numbered-chunks (make-string 100 :initial-element #\a) :max 10 :max-chunks 3)) 3)
(chk "the cap names what it left out"
     (and (search "elided" (third (emissary::numbered-chunks (make-string 100 :initial-element #\a) :max 10 :max-chunks 3))) t) t)

;; every chunk within the limit, and nothing lost, on a long mixed text
(let* ((words (loop for i below 400 collect (make-string (1+ (mod (* i 7) 13)) :initial-element #\w)))
       (text (format nil "~{~a~^ ~}" words))
       (chunks (emissary:split-text text 50)))
  (chk "no chunk over the limit" (every (lambda (c) (<= (length c) 50)) chunks) t)
  (chk "nothing lost" (remove #\Space (apply #'concatenate 'string chunks)) (remove #\Space text)))

;; principals
(defvar *dir* (format nil "/tmp/emissary-unit-~d-~d/" (get-universal-time) (random 1000000 (make-random-state t))))
(ensure-directories-exist *dir*)
(defvar *a* (cl-nostr.keys:generate-keypair))
(defvar *b* (cl-nostr.keys:generate-keypair))
(defvar *c* (cl-nostr.keys:generate-keypair))
(with-open-file (o (concatenate 'string *dir* "allow.txt") :direction :output :if-exists :supersede)
  (format o "# principals~%~a   # alice, by npub~%~a~%not-a-key~%~%"
          (cl-nostr.bech32:npub-encode (cl-nostr.keys:public-hex *a*))
          (string-upcase (cl-nostr.keys:public-hex *b*))))
(defvar *e* (emissary:make-emissary :dir *dir*))
(chk "two principals from allow.txt (npub, upper-case hex; garbage skipped)" (length (emissary:principals *e*)) 2)
(chk "an npub principal" (emissary:authorized-p *e* (cl-nostr.keys:public-hex *a*)) t)
(chk "a hex principal, any case" (emissary:authorized-p *e* (cl-nostr.keys:public-hex *b*)) t)
(chk "a stranger" (emissary:authorized-p *e* (cl-nostr.keys:public-hex *c*)) nil)
(chk "the key persists" (emissary:emissary-pubkey (emissary:make-emissary :dir *dir*)) (emissary:emissary-pubkey *e*))
(emissary:allow *e* (cl-nostr.keys:public-hex *c*))
(chk "ALLOW adds one" (emissary:authorized-p *e* (cl-nostr.keys:public-hex *c*)) t)

;; dispatch: a handler, a fake transport, a principal and a stranger
(defvar *e2* (emissary:make-emissary :dir *dir* :handler (lambda (r) (string-upcase (emissary:request-text r)))))
(defvar *sent* '())
(push (cons :test (lambda (e r text) (declare (ignore e)) (push (list (emissary:request-sender r) text) *sent*)))
      (emissary::emissary-repliers *e2*))
(emissary::enqueue *e2* (emissary::%make-request :transport :test :sender (cl-nostr.keys:public-hex *a*) :text "hi") "id1")
(emissary::enqueue *e2* (emissary::%make-request :transport :test :sender (cl-nostr.keys:public-hex *a*) :text "hi") "id1")
(emissary::enqueue *e2* (emissary::%make-request :transport :test :sender (cl-nostr.keys:public-hex *c*) :text "no") "id2")
(setf (emissary::emissary-on-log *e2*) (lambda (line) (declare (ignore line))))
(emissary:emissary-step *e2* 0)
(chk "the principal is answered once (ids deduplicate), the stranger not at all"
     *sent* (list (list (cl-nostr.keys:public-hex *a*) "HI")))

;; the sandbox, when there is a modus to run -- including over a core some other
;; modus binary saved, which must be re-made rather than fail every request
(when (uiop:getenv "MODUS_BIN")
  (setf emissary:*modus-binary* (uiop:getenv "MODUS_BIN"))
  (chk "the sandbox evaluates" (emissary:format-result (emissary:sandbox-evaluate "(* 6 7)")) "42")
  (with-open-file (o (concatenate 'string *dir* "eval.core") :direction :output
                     :if-exists :supersede :element-type '(unsigned-byte 8))
    (dotimes (i 4096) (write-byte 0 o)))
  (setf emissary::*core-checked* nil)
  (chk "a core this binary will not restore is re-made"
       (emissary:format-result (emissary:sandbox-evaluate "(+ 40 2)")) "42"))

(format t "~&UNIT: ~a checks, ~a failed~%" *checks* *fails*)
#+sbcl (sb-ext:exit :code (if (zerop *fails*) 0 1))
#-sbcl (sys-exit (if (zerop *fails*) 0 1))
