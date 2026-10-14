;;;; util.lisp

(in-package #:emissary)

(defun unix-now () (- (get-universal-time) 2208988800))

(defvar *chunk-chars* 1800 "Most characters in one outgoing DM; a longer reply is split.")
(defvar *max-chunks* 8 "Most DMs one reply is split into; the rest is elided, and says so.")

(defun %break-point (s max)
  "Index to cut S at so the chunk before it is at most MAX characters once its
trailing whitespace is trimmed: a paragraph, line, sentence or word boundary near
the end of the window, or MAX if there is none.  The separator may sit just PAST
the window -- a word that ends exactly at MAX is kept, not pushed to the next
chunk (the boundary search used to stop one short of it)."
  (let* ((n (length s))
         (limit (min max n))
         (win (max 0 (- limit 500))))
    (labels ((rfind (needle reach)
               (search needle s :from-end t :start2 win :end2 (min n (+ limit reach)))))
      (cond ((let ((p (rfind (format nil "~%~%") 2))) (and p (+ p 2))))
            ((let ((p (rfind (string #\Newline) 1))) (and p (+ p 1))))
            ((let ((p (rfind ". " 1))) (and p (+ p 2))))
            ((let ((p (rfind " " 1))) (and p (+ p 1))))
            (t limit)))))

(defun split-text (text &optional (max *chunk-chars*))
  "TEXT in chunks of at most MAX characters, cut at natural boundaries."
  (let ((out '()) (s (string-trim '(#\Space #\Newline) text)))
    (loop
      (when (<= (length s) max) (when (plusp (length s)) (push s out)) (return))
      (let ((cut (%break-point s max)))
        (push (string-right-trim '(#\Space #\Newline) (subseq s 0 cut)) out)
        (setf s (string-left-trim '(#\Space #\Newline) (subseq s cut)))))
    (nreverse out)))

(defun numbered-chunks (text &key (max *chunk-chars*) (max-chunks *max-chunks*))
  "TEXT as a list of message bodies: split, capped at MAX-CHUNKS (the last says how
much was left out), and numbered (i/n) when there is more than one."
  (let* ((chunks (split-text text max))
         (chunks (if (> (length chunks) max-chunks)
                     (append (subseq chunks 0 (1- max-chunks))
                             (list (format nil "...[~a more part~:p elided]"
                                           (- (length chunks) (1- max-chunks)))))
                     chunks))
         (n (length chunks)))
    (if (> n 1)
        (loop for c in chunks for i from 1 collect (format nil "(~a/~a) ~a" i n c))
        chunks)))
