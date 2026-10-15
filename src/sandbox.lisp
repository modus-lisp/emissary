;;;; sandbox.lisp -- the default handler: one request, one fresh modus process.
;;;;
;;;; Every request runs in a NEW process restored from a saved core: it starts in
;;;; ~25 ms, it is killed at the deadline (coreutils `timeout`), a crash in it is
;;;; its own, and nothing one request defines is visible to the next -- the agent
;;;; serves several people, and none of them should see another's state.  The core
;;;; is the plain modus image, saved once by a child process (ENSURE-CORE).
;;;;
;;;; The form text travels to the child inside the script it runs (a string
;;;; literal), because modus has no argv and the child reads its script, not its
;;;; environment.  The child reads it with *READ-EVAL* off, evaluates each form, and
;;;; prints one line, @@RESULT followed by a readable plist, which is all the parent
;;;; parses: everything else the child writes is ignored.

(in-package #:emissary)

(defvar *modus-binary* (or (uiop:getenv "MODUS_BIN") "modus")
  "The modus executable children run.")
(defvar *eval-timeout* 10 "Seconds a request may run before it is killed.")
(defvar *max-reply* 16000 "Characters of a result or of output sent back.")
(defvar *work-dir* nil "Where the core and the per-request scripts live (the emissary's directory).")

(defun %work-file (name)
  (merge-pathnames name *work-dir*))

(defun %run (argv)
  "Run ARGV; (values STDOUT EXIT-CODE)."
  (multiple-value-bind (out err code)
      (uiop:run-program argv :output :string :error-output nil :ignore-error-status t)
    (declare (ignore err))
    (values out code)))

(defvar *core-checked* nil "The core path ENSURE-CORE has checked in this process.")

(defun %core-restores-p (core)
  "True when the current *MODUS-BINARY* restores CORE.  A core holds addresses into
the binary that saved it, so one saved by another build is refused at start-up --
and every request would fail until it was re-made."
  (and (search "core-ok"
               (%run (list *modus-binary* "--core" core
                           "--eval" "(progn (princ \"core-ok\") (sys-exit 0))")))
       t))

(defun ensure-core (&key force)
  "The path of the saved core children restore: made by a child process if it is
not there, and re-made once per process if this modus binary does not restore it
(modus was upgraded under it)."
  (let ((core (namestring (%work-file "eval.core"))))
    (when (or force
              (not (probe-file core))
              (and (not (equal *core-checked* core)) (not (%core-restores-p core))))
      (%run (list *modus-binary* "--eval" (format nil "(save-and-die ~s)" core)))
      (unless (and (probe-file core) (%core-restores-p core))
        (error "emissary: could not save an evaluation core at ~a with ~a" core *modus-binary*)))
    (setf *core-checked* core)
    core))

(defun %lisp-string (s)
  "S as a Lisp string literal."
  (with-output-to-string (out)
    (write-char #\" out)
    (loop for c across s
          do (when (or (char= c #\") (char= c #\\)) (write-char #\\ out))
             (write-char c out))
    (write-char #\" out)))

(defun %request-script (text)
  (format nil "~
(let* ((text ~a)
       (out (make-string-output-stream))
       (result
         (handler-case
             (let ((*standard-output* out) (*read-eval* nil) (vals nil))
               (with-input-from-string (s text)
                 (loop (let ((form (read s nil s)))
                         (when (eq form s) (return nil))
                         (setq vals (multiple-value-list (eval form))))))
               (list :ok (mapcar (function prin1-to-string) vals)))
           (error (e) (list :error (princ-to-string e))))))
  (format t \"~~&@@RESULT ~~s~~%\" (append result (list :output (get-output-stream-string out)))))
" (%lisp-string text)))

(defun %truncate (s)
  (if (> (length s) *max-reply*)
      (concatenate 'string (subseq s 0 *max-reply*) " ...[truncated]")
      s))

(defun %parse-result (stdout)
  (let ((p (search "@@RESULT " stdout)))
    (when p
      (let ((*read-eval* nil))
        (ignore-errors (read-from-string stdout t nil :start (+ p 9)))))))

(defvar *request-counter* 0)

(defun sandbox-evaluate (text)
  "Evaluate the forms in TEXT in a fresh modus process.  Returns a plist:
(:OK (\"value\" ...) :OUTPUT \"...\"), (:ERROR \"message\" :OUTPUT \"...\"),
(:TIMEOUT SECONDS) or (:FAILED \"why\")."
  (let* ((core (ensure-core))
         (script (%work-file (format nil "req-~d.lisp" (incf *request-counter*)))))
    (with-open-file (o script :direction :output :if-exists :supersede)
      (write-string (%request-script text) o))
    (unwind-protect
         (multiple-value-bind (out code)
             (%run (list "timeout" "-k" "2" (princ-to-string *eval-timeout*)
                         *modus-binary* "--core" core "--script" (namestring script)))
           (cond ((member code '(124 137)) (list :timeout *eval-timeout*))
                 (t (or (%parse-result out)
                        (list :failed (format nil "exit ~a, no result" code))))))
      (ignore-errors (delete-file script)))))

(defun format-result (r)
  "A reply's text for result plist R."
  (%truncate
   (case (first r)
     (:ok (format nil "~{~a~^~%~}~@[~%--- output:~%~a~]"
                  (second r) (let ((o (getf (cddr r) :output))) (and o (plusp (length o)) o))))
     (:error (format nil "error: ~a~@[~%--- output:~%~a~]"
                     (second r) (let ((o (getf (cddr r) :output))) (and o (plusp (length o)) o))))
     (:timeout (format nil "timeout: stopped after ~a s" (second r)))
     (t (format nil "failed: ~a" (second r))))))

(defun sandboxed-eval (request)
  "The default handler: evaluate REQUEST's text as Lisp forms in a fresh modus
process and answer with the result.  See SANDBOX-EVALUATE."
  (format-result (sandbox-evaluate (request-text request))))
