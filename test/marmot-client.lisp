;;;; test/marmot-client.lisp -- an SBCL cl-marmot member: invite the agent into a
;;;; group and send it forms there.   CLIENT_KEY (hex), AGENT_PUB (hex), AGENT_RELAY, CLIENT_HOME
(load "/home/claude/peek-2026-10-13/modus-agent/test/deps.lisp")
(asdf:load-system "cl-marmot")
(defpackage :mclient (:use :cl))
(in-package :mclient)
(defvar *checks* 0) (defvar *fails* 0)
(defun chk (name ok) (incf *checks*) (format t "~&  ~a ~a~%" (if ok "ok  " "FAIL") name) (unless ok (incf *fails*)))
(defvar *agent* (uiop:getenv "AGENT_PUB"))
(defvar *c* (marmot:create-account :home (uiop:getenv "CLIENT_HOME") :relays (list (uiop:getenv "AGENT_RELAY"))
                                    :name "test client"
                                    :nsec (cl-nostr.bech32:nsec-encode (uiop:getenv "CLIENT_KEY"))))
(defvar *chat* (marmot:create-chat *c* (list *agent*) :name "eval"))
(format t "~&  chat created, agent invited~%")
(defun replies ()
  (remove-if (lambda (m) (marmot:message-own-p m)) (marmot:chat-messages (marmot:find-chat *c* (marmot:chat-id *chat*)))))
(defun await (n secs)
  (loop repeat secs do (marmot:sync *c*) (when (>= (length (replies)) n) (return)) (sleep 1))
  (mapcar #'marmot:message-content (replies)))
(defvar *t0* (get-internal-real-time))
(marmot:send *c* *chat* "(+ 1 2)")
(let ((r (await 1 60))) (chk (format nil "group request (+ 1 2) -> ~s" (first r)) (equal (first r) "3")))
(chk "the reply's MLS sender is the agent"
     (let ((m (first (replies)))) (and m (equalp (marmot:message-sender m) *agent*))))
(marmot:send *c* *chat* "(list (lisp-implementation-type) (* 6 7))")
(let ((r (await 2 60))) (chk (format nil "second request -> ~s" (second r)) (equal (second r) "(\"Modus\" 42)")))
(format t "~&MARMOT CLIENT: ~a checks, ~a failed  (~,1f s)~%" *checks* *fails*
        (/ (- (get-internal-real-time) *t0*) internal-time-units-per-second))
(sb-ext:exit :code (if (zerop *fails*) 0 1) :abort t)
