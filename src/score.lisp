;;; Copyright (c) 2013-2014 Tito Latini
;;;
;;; This program is free software; you can redistribute it and/or modify
;;; it under the terms of the GNU General Public License as published by
;;; the Free Software Foundation; either version 2 of the License, or
;;; (at your option) any later version.
;;;
;;; This program is distributed in the hope that it will be useful,
;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;; GNU General Public License for more details.
;;;
;;; You should have received a copy of the GNU General Public License
;;; along with this program; if not, write to the Free Software
;;; Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA

(in-package :incudine)

;;; A score file can contain time-tagged lisp functions, lisp statements,
;;; arbitrary score statements and lisp tags.
;;;
;;; The syntax of a time-tagged lisp function is:
;;;
;;;     start-time-in-beats   function-name   [arg1]   [arg2]   ...
;;;

(defvar *score-statements* (make-hash-table :test #'equal))
(declaim (type hash-table *score-statements*))

;;; Define an arbitrary score statement.
;;; The statement is formed by the elements of the returned list.
;;;
;;; Example:
;;;
;;;     (defscore-statement i1 (time dur freq amp)
;;;       `(,time my-func (dur ,dur) ,freq ,amp))
;;;
;;; where the Csound score statement
;;;
;;;     i1 3.4 1.75 440 .3
;;;
;;; will be expanded in a time tagged lisp function
;;;
;;;     3.4 my-func (dur 1.75) 440 0.3
;;;
(defmacro defscore-statement (name args &rest body)
  (multiple-value-bind (decl rest)
      (incudine.util::separate-declaration body)
    `(progn
       (setf (gethash (symbol-name ',name) *score-statements*)
             (lambda ,args ,@decl
               (let* ((*print-pretty* nil)
                      (str (format nil "~S" (progn ,@rest)))
                      (len (length str)))
                 (if (< len 2)
                     ""
                     (subseq str 1 (1- len))))))
       ',name)))

(declaim (inline delete-score-statement))
(defun delete-score-statement (name)
  "Delete the score statement defined by DEFSCORE-STATEMENT."
  (remhash (symbol-name name) *score-statements*))

(declaim (inline score-statement-name))
(defun score-statement-name (str)
  (let ((name-endpos (position-if #'blank-char-p str)))
    (values (string-upcase (subseq str 0 name-endpos))
            name-endpos)))

(declaim (inline score-statement-args))
(defun score-statement-args (str name-endpos)
  (read-from-string
    (concatenate 'string "(" (subseq str name-endpos) ")")))

(defun expand-score-statement (str)
  (declare (type string str))
  (multiple-value-bind (name name-endpos)
      (score-statement-name str)
    (when name
      (let ((fn (gethash name *score-statements*)))
        (declare (type (or function null) fn))
        (when fn
          (apply fn (when name-endpos
                      (score-statement-args str name-endpos))))))))

(declaim (inline blank-char-p))
(defun blank-char-p (c)
  (member c '(#\space #\tab)))

(declaim (inline line-parse-skip-string))
(defun line-parse-skip-string (str index end)
  (declare (type string str) (type non-negative-fixnum index end))
  (labels ((skip-p (i)
             (if (>= i end)
                 i
                 (case (char str i)
                   (#\" i)
                   (#\\ (skip-p (+ i 2)))
                   (otherwise (skip-p (1+ i)))))))
    (skip-p (1+ index))))

(defun %time-tagged-function-p (s)
  (declare (type string s))
  (let* ((slen (length s))
         (last (1- slen)))
    (declare (type non-negative-fixnum slen last))
    (or (char/= (char s last) #\))
        (labels ((stmt-p (i unmatched-parens)
                   (when (< i slen)
                     (if (zerop unmatched-parens)
                         (find-if-not #'blank-char-p s :start i)
                         (case (char s i)
                           (#\" (stmt-p (line-parse-skip-string s i slen)
                                        unmatched-parens))
                           (#\) (stmt-p (1+ i) (1- unmatched-parens)))
                           (#\( (stmt-p (1+ i) (1+ unmatched-parens)))
                           (otherwise (stmt-p (1+ i) unmatched-parens)))))))
          (stmt-p 1 1)))))

(declaim (inline time-tagged-function-p))
(defun time-tagged-function-p (string)
  (declare (type string string))
  (if (char= (char string 0) #\()
      (%time-tagged-function-p string)
      (let ((space-pos (position-if #'blank-char-p string)))
        (declare (type (or non-negative-fixnum null) space-pos))
        (when space-pos
          (find-if-not #'blank-char-p string :start space-pos)))))

(declaim (inline score-skip-line-p))
(defun score-skip-line-p (line)
  (declare (type string line))
  (let ((non-blank (find-if-not #'blank-char-p line)))
    (or (null non-blank) (char= non-blank #\;))))

(defmacro %at-sample (at-fname beats func-symbol &rest args)
  `(,at-fname ,beats ,func-symbol ,@args))

(defun score-line->sexp (line at-fname)
  (declare (type string line))
  (let ((line (or (expand-score-statement line) line))
        (*read-default-float-format* *sample-type*))
    (declare (type string line))
    (if (time-tagged-function-p line)
        (macroexpand-1
          (read-from-string
           (format nil "(INCUDINE::%AT-SAMPLE ~A ~A)" at-fname line)))
        ;; Tag or lisp statement
        (read-from-string (string-left-trim '(#\space #\tab) line)))))

(declaim (inline score-lines->sexp))
(defun score-lines->sexp (stream at-fname)
  (declare (type stream stream))
  (loop for line of-type (or string null)
                 = (read-score-line stream)
        while line
        unless (score-skip-line-p line)
        collect (score-line->sexp line at-fname)))

(defun find-score-local-bindings (stream at)
  (declare (type stream stream) (type symbol at))
  (labels ((score-bindings-p (line)
             (string-equal (subseq line 0 (min 5 (length line))) "with "))
           (format-bindings (line)
             (concatenate 'string "((" (subseq line 5) "))"))
           (first-score-stmt (line)
             (declare (type (or string null) line))
             (when line
               (cond ((score-skip-line-p line)
                      (first-score-stmt (read-score-line stream)))
                     ((score-bindings-p line)
                      ;; Local bindings at the beginning of the score
                      (read-from-string (format-bindings line)))
                     (t ;; There aren't local bindings
                      (list nil (score-line->sexp line at)))))))
    (first-score-stmt (read-score-line stream))))

(defun read-score-line (stream)
  (declare (type stream stream))
  (flet ((remove-comment (str)
           ;; A comment starts with `;'
           (subseq str 0 (position #\; str)))
         (line-break-p (str strlen)
           ;; Line continuation with `\' at the end
           (and (> strlen 1)
                (char=  (char str (- strlen 1)) #\\)
                (char/= (char str (- strlen 2)) #\\))))
    (let ((line (read-line stream nil nil)))
      (declare (type (or string null) line))
      (when line
        (let* ((s (remove-comment (string-trim '(#\space #\tab) line)))
               (slen (length s)))
          (declare (type non-negative-fixnum slen))
          (if (line-break-p s slen)
              (concatenate 'string
                           (subseq s 0 (- slen 2))
                           " "
                           (read-score-line stream))
              s))))))

(defmacro at-last-time (now function)
  `(at (+ ,now 1e-10)
       (lambda ()
         (at (+ (incudine.edf:last-time)
                ;; We use a small fractional number to schedule a new event
                ;; after the last but possibly at the same time. If we use
                ;; the last scheduled time without this offset, the next
                ;; function is called before the last event and it is not
                ;; what we want.
                1e-10)
             ,function))))

;;; Extend the last time if there is a pending event.
;;; Note: the duration of an event is known only if it uses the local
;;; function DUR (see REGOFILE->SEXP).
(defmacro maybe-extend-time (now time-var dur sched-func c-array tempo-env)
  ``(when (nrt-edf-heap-p)
      (at-last-time ,,now
        (lambda ()
          (flet ((end-of-rego (&optional arg)
                   (declare (ignorable arg))
                   (free (list ,,c-array ,,tempo-env))
                   (nrt-msg info "end of rego")))
            (cond ((and (plusp ,,dur)
                        (> (incf ,,time-var ,,dur) ,,now))
                   (,,sched-func ,,time-var #'end-of-rego))
                  ((rt-thread-p) (nrt-funcall #'end-of-rego))
                  (t (end-of-rego))))))))

(declaim (inline default-tempo-envelope))
(defun default-tempo-envelope ()
  (make-tempo-envelope (list *default-bpm* *default-bpm*) '(0)))

;;; Symbols with complex names used in the code generated by a rego file.
;;; *PRINT-GENSYM* is NIL in REGOFILE->LISPFILE
(defmacro with-complex-gensyms (names &body forms)
  `(let ,(mapcar (lambda (name)
                   `(,name (gensym ,(format nil "%%%~A%%%" name))))
                 names)
     ,@forms))

(declaim (inline ensure-complex-gensym))
(defun ensure-complex-gensym (name)
  (ensure-symbol (symbol-name (gensym (format nil "%%%~A%%%" (string name))))))

(defmacro with-rego-function ((fname compile-rego-p) &body body)
  `(,@(if fname `(defun ,fname) '(lambda)) ()
      (,(if compile-rego-p 'progn 'incudine.util::cudo-eval) ,@body)))

;;; Foreign memory to reduce consing.
(defmacro with-rego-samples ((foreign-array-name time-var sched-var
                              last-time-var last-dur-var) &body body)
  (with-complex-gensyms (c-array)
    (let ((var-names (list time-var sched-var last-time-var last-dur-var)))
      `(let* ((,foreign-array-name (make-foreign-array ,(length var-names)
                                                       'sample :zero-p t))
              (,c-array (foreign-array-data ,foreign-array-name)))
         (symbol-macrolet ,(loop for var in var-names for i from 0
                                 collect `(,var (smp-ref ,c-array ,i)))
           (setf ,time-var (if (incudine::nrt-edf-heap-p)
                               (now)
                               +sample-zero+))
           ,@body)))))

(defun %write-regofile (path at-fname time-var dur-var sched-func c-array
                        tempo-env)
  `(prog*
     ,@(with-open-file (score path)
         (append
           (find-score-local-bindings score at-fname)
           (score-lines->sexp score at-fname)
           (list (maybe-extend-time at-fname time-var dur-var sched-func
                                    c-array tempo-env))))))

;;; Local variables usable inside the rego file:
;;;
;;;     TIME          initial time in samples
;;;     TEMPO-ENV     temporal envelope of the events
;;;
;;; It is possible to define other local variables by inserting
;;; the bindings after WITH, at the beginning of the score.
;;; For example:
;;;
;;;     ;;; test.rego
;;;     with (id 1) (last 4)
;;;
;;;     ;; simple oscillators
;;;     0          simple 440 .2 :id id
;;;     1          simple 448 .2 :id (+ id 1)
;;;     (1- last)  simple 661 .2 :id (+ id 2)
;;;     last       free 0
;;;
;;; We can also add a DECLARE expression after the bindings.
;;;
;;; DUR is a local function to convert the duration from
;;; beats to seconds with respect to TEMPO-ENV.
;;;
;;; TEMPO is a local macro to change the tempo of the score.
;;; The syntax is
;;;
;;;     (tempo bpm)
;;;     (tempo bpms beats &key curve loop-node release-node
;;;                            restart-level real-time-p)
;;;
(defun regofile->sexp (path &optional fname compile-rego-p)
  (declare (type (or pathname string)))
  (with-ensure-symbol (time dur tempo tempo-env)
    (let ((%sched (ensure-complex-gensym "AT"))
          (sched (ensure-complex-gensym "AT")))
      (with-complex-gensyms (beats last-time last-dur c-array-wrap)
        `(with-rego-function (,fname ,compile-rego-p)
           (with-rego-samples (,c-array-wrap ,time ,sched ,last-time ,last-dur)
             (let ((,tempo-env (default-tempo-envelope)))
               (incudine.edf::with-schedule
                 (flet ((,dur (,beats)
                          (setf ,last-time ,sched)
                          (setf ,last-dur (sample ,beats))
                          (time-at ,tempo-env ,beats ,sched))
                        (,%sched (beats fn)
                          (incudine.edf::%at
                            (+ ,time
                               (* *sample-rate*
                                  (%time-at ,tempo-env
                                            (setf ,sched (sample beats)))))
                            fn (list beats))))
                   (declare (ignorable (function ,dur)))
                   (macrolet ((,tempo (&rest args)
                                `(set-tempo-envelope ,',tempo-env
                                   ,@(if (cdr args)
                                         args
                                         ;; Constant tempo
                                         `((list ,(car args) ,(car args)) '(0)))))
                              (,sched (beats fn &rest args)
                                (with-gensyms (x)
                                  `(,',%sched ,beats
                                              (lambda (,x)
                                                (setf ,',sched (sample ,x))
                                                (,fn ,@args))))))
                     ,(%write-regofile path sched last-time last-dur %sched
                                       c-array-wrap tempo-env)))))))))))

(declaim (inline regofile->function))
(defun regofile->function (path &optional fname compile-rego-p)
  (eval (regofile->sexp path fname compile-rego-p)))

(defun regofile->lispfile (rego-file &optional fname lisp-file compile-rego-p)
  (declare (type (or pathname string null) rego-file lisp-file))
  (let ((lisp-file (or lisp-file (make-pathname :defaults rego-file
                                                :type "cudo"))))
    (with-open-file (lfile lisp-file :direction :output :if-exists :supersede)
      (write (regofile->sexp rego-file fname compile-rego-p)
             :stream lfile :gensym nil)
      (terpri lfile)
      (msg debug "convert ~A -> ~A" rego-file lisp-file)
      lisp-file)))
