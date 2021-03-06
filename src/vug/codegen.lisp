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

(in-package :incudine.vug)

(declaim (special *initialization-code*))

(defvar *common-code-in-local-functions-p* t)
(declaim (type boolean *common-code-in-local-functions-p*))

(declaim (inline add-initialization-code))
(defun add-initialization-code (form)
  (push form *initialization-code*))

(declaim (inline make-initialization-code-stack))
(defun make-initialization-code-stack ()
  (list 'progn))

(declaim (inline empty-initialization-code-stack-p))
(defun empty-initialization-code-stack-p ()
  (null (cdr *initialization-code*)))

(declaim (inline reorder-initialization-code))
(defun reorder-initialization-code ()
  (nreversef *initialization-code*)
  (values))

(declaim (inline vug-definition-p))
(defun vug-definition-p ()
  (null *initialization-code*))

(defun resolve-conditional-expansion (value)
  (cond ((vug-variable-p value)
         (when (and (not (vug-variable-init-time-p value))
                    (not (vug-variable-conditional-expansion value)))
           ;; An expansion of the code in the INITIALIZE block inhibits
           ;; the same expansion in the body of the performance function
           ;; during the process of the first sample.
           ;; The expansion is controlled by a new variable EXPAND-CODE-P
           ;; (the alternative is to compile a performance-time function for
           ;; the first sample and one for the subsequent samples).
           (let* ((var-name (gensym "EXPAND-CODE-P"))
                  (cond-expand-var (%make-vug-variable :name var-name
                                                       :value nil
                                                       :type 'boolean)))
             (setf (vug-variable-conditional-expansion value) var-name)
             (push cond-expand-var (vug-variables-bindings *vug-variables*)))))
        ((vug-function-p value)
         (mapc #'resolve-conditional-expansion (vug-function-inputs value)))))

(defun expand-setter-form (obj init-time-p initialize-body-p)
  (loop for i on (vug-function-inputs obj) by #'cddr
        for input = (first i) do
          (when (vug-variable-p input)
            (cond (init-time-p
                   (resolve-conditional-expansion (second i))
                   (setf (vug-variable-skip-init-set-p input) t))
                  (t (setf (vug-variable-to-set-p input) nil)
                     (recheck-variables input)))
            (unless (or initialize-body-p
                        (vug-variable-performance-time-p input))
              (setf (vug-variable-performance-time-p input) t)))))

(declaim (inline vug-variable-to-set-inside-body-p))
(defun vug-variable-to-set-inside-body-p (obj vug-body-p init-pass-p)
  (and (vug-variable-p obj)
       vug-body-p
       (vug-variable-to-set-p obj)
       (not (and init-pass-p (vug-variable-skip-init-set-p obj)))
       (not (vug-variable-init-time-p obj))))

(declaim (inline vug-variable-setter-name))
(defun vug-variable-setter-name (var)
  (format-symbol *package* "SET-~A" (vug-object-name var)))

(declaim (inline %update-vug-variable))
(defun %update-vug-variable (var)
  `(,(vug-variable-setter-name var)))

(defun set-vug-variable-inside-body (var init-pass-p conditional-expansion-p)
  (declare (type vug-variable var)
           (type boolean init-pass-p conditional-expansion-p))
  (no-vug-variable-to-set var init-pass-p)
  (let* ((cond-expand-var (and conditional-expansion-p
                               (not init-pass-p)
                               (vug-variable-conditional-expansion var)))
         (form (if (ugen-variable-p var)
                   (perf-modulated-ugen var)
                   (blockexpand (vug-variable-value var) nil t init-pass-p
                                (and conditional-expansion-p
                                     (null cond-expand-var)))))
         (set-form (if (and *common-code-in-local-functions-p*
                            (vug-variable-to-expand-multiple-times-p var))
                       (%update-vug-variable var)
                       `(setf ,(vug-object-name var) ,form))))
    (cond (cond-expand-var
           ;; COND-EXPAND-VAR is NIL during the process of the
           ;; first sample because the expansion of the code is
           ;; in the INITIALIZE block.
           `(if ,cond-expand-var
                ,set-form
                (progn (setq ,cond-expand-var t)
                       ,(vug-object-name var))))
          ((ugen-variable-p var) form)
          ((and (< (vug-variable-ref-count var) 2)
                (not (vug-variable-to-preserve-p var)))
           (replace-vug-variable var (vug-variable-value var))
           (msg-debug-delete-variable var "performance-time")
           form)
          (t set-form))))

(defun maybe-cached-vug-variable-value (var param-plist vug-body-p init-pass-p)
  (labels ((maybe-cached-val (obj)
             (multiple-value-bind (cached cached-p)
                 (vug-variable-replacement obj)
               (if cached-p
                   (if (vug-variable-p cached)
                       (if (vug-variable-deleted-p cached)
                           (maybe-cached-val cached)
                           (vug-object-name cached))
                       (blockexpand cached param-plist vug-body-p init-pass-p))
                   (vug-object-name obj)))))
    (maybe-cached-val var)))

(defun expand-set-local-pointer (obj param-plist vug-body-p init-pass-p
                                 conditional-expansion-p initialize-body-p)
  (let* ((inputs (vug-function-inputs obj))
         (var (car inputs)))
    (cond ((vug-variable-replacement var)
           ;; Replaced with the variables of the first FOREACH-FRAME loop.
           nil)
          ((zerop (vug-variable-ref-count var))
           ;; Unused variables.
           (replace-vug-variable var nil)
           (msg-debug-delete-variable var "performance-time"))
          (t (setf (vug-variable-to-set-p var) nil)
             `(setf ,@(blockexpand inputs param-plist vug-body-p
                                   init-pass-p
                                   conditional-expansion-p
                                   initialize-body-p))))))

(declaim (inline maybe-progn))
(defun maybe-progn (forms)
  (if (cdr forms) `(progn ,@forms) (car forms)))

;;; Transform a VUG block in lisp code.
(defun blockexpand (obj &optional param-plist vug-body-p init-pass-p
                    (conditional-expansion-p t) initialize-body-p)
  (declare (type list param-plist) (type boolean vug-body-p))
  (cond ((consp obj)
         (cons (blockexpand (car obj) param-plist vug-body-p init-pass-p
                            conditional-expansion-p initialize-body-p)
               (blockexpand (cdr obj) param-plist vug-body-p init-pass-p
                            conditional-expansion-p initialize-body-p)))
        ((vug-function-p obj)
         (when (and vug-body-p (setter-form-p (vug-object-name obj)))
           (expand-setter-form obj init-pass-p initialize-body-p))
         (cond ((consp (vug-object-name obj))
                (vug-object-name obj))
               ((vug-name-p obj 'initialize)
                (if (vug-definition-p)
                    (blockexpand (vug-function-inputs obj) param-plist
                                 vug-body-p init-pass-p conditional-expansion-p t)
                    (add-initialization-code
                      (maybe-progn (blockexpand (vug-function-inputs obj)
                                                param-plist vug-body-p t nil t))))
                (values))
               ((vug-name-p obj 'progn)
                (if (cdr (vug-function-inputs obj))
                    (maybe-progn (blockexpand (vug-function-inputs obj)
                                              param-plist vug-body-p
                                              init-pass-p conditional-expansion-p
                                              initialize-body-p))
                    (blockexpand (car (vug-function-inputs obj))
                                 param-plist vug-body-p
                                 init-pass-p conditional-expansion-p
                                 initialize-body-p)))
               ((vug-name-p obj 'ugen-run)
                `(ugen-run ,@(blockexpand (vug-function-inputs obj)
                                          param-plist vug-body-p
                                          init-pass-p conditional-expansion-p)))
               ((or (vug-name-p obj '%with-follow)
                    (vug-name-p obj 'without-follow))
                (maybe-progn (blockexpand (cdr (vug-function-inputs obj))
                                          param-plist vug-body-p init-pass-p
                                          conditional-expansion-p)))
               ((vug-name-p obj 'get-pointer)
                `(get-pointer
                   ,(vug-object-name (car (vug-function-inputs obj)))))
               ((or (vug-name-p obj 'set-local-io-pointer)
                    (vug-name-p obj 'set-local-now))
                (expand-set-local-pointer obj param-plist vug-body-p
                                          init-pass-p conditional-expansion-p
                                          initialize-body-p))
               ((null (vug-function-inputs obj))
                (list (vug-object-name obj)))
               ((vug-name-p obj 'lambda)
                (let ((inputs (vug-function-inputs obj)))
                  `(lambda ,(car inputs) ,@(blockexpand (cadr inputs)))))
               ((vug-name-p obj 'init-only)
                (maybe-progn (blockexpand (vug-function-inputs obj)
                                          param-plist vug-body-p
                                          init-pass-p conditional-expansion-p)))
               ((vug-name-p obj 'update)
                (let ((var (car (vug-function-inputs obj))))
                  (multiple-value-bind (cached cached-p)
                      (vug-variable-replacement var)
                    (when cached-p (setf var cached))
                    (cond ((vug-variable-p var)
                           (no-vug-variable-to-set var init-pass-p)
                           (if *common-code-in-local-functions-p*
                               (%update-vug-variable var)
                               `(setf ,(vug-object-name var)
                                      ,(blockexpand (vug-variable-value var)
                                                    nil t init-pass-p
                                                    conditional-expansion-p))))
                          (t (blockexpand cached param-plist t
                                          init-pass-p))))))
               (t (cons (vug-object-name obj)
                        (blockexpand (vug-function-inputs obj)
                                     param-plist vug-body-p
                                     init-pass-p conditional-expansion-p
                                     initialize-body-p)))))
        ((vug-parameter-p obj)
         (assert (not vug-body-p))
         (or (getf param-plist (vug-object-name obj))
             (vug-parameter-value obj)))
        ((vug-variable-to-set-inside-body-p obj vug-body-p init-pass-p)
         (if (vug-variable-deleted-p obj)
             (blockexpand (vug-variable-replacement obj) param-plist vug-body-p
                          init-pass-p)
             (set-vug-variable-inside-body obj init-pass-p
                                           conditional-expansion-p)))
        ((vug-variable-p obj)
         (cond ((vug-variable-temporary-p obj)
                ;; Ignore a temporary variable outside INITIALIZE construct
                ;; (i.e. see WITH-FOLLOW).
                (when initialize-body-p
                  (blockexpand (vug-variable-value obj) nil vug-body-p
                               init-pass-p conditional-expansion-p t)))
               (t (when (and (vug-variable-variables-to-recheck obj)
                             (vug-variable-performance-time-p obj))
                    (recheck-variables obj))
                  (maybe-cached-vug-variable-value obj param-plist vug-body-p
                                                   init-pass-p))))
        ((vug-symbol-p obj)
         (let ((name (vug-object-name obj)))
           (if (and *eval-some-specials-p* (special-var-to-eval-p name))
               (eval name)
               name)))
        (t obj)))

(defmacro with-vug-arguments ((args types) &body body)
  `(let ,(mapcar (lambda (name type)
                   `(,name (make-vug-parameter ',name ,name ',type)))
                 args types)
     ,@body))

(declaim (inline foreign-object-p))
(defun foreign-object-p (var)
  (foreign-type-p (vug-object-type var)))

(declaim (inline integer-has-zero-p))
(defun integer-has-zero-p (type) (typep 0 type))

(defmacro with-ugen-name-and-args ((ugen-var name-var args-var) &body body)
  `(destructuring-bind (,name-var &rest ,args-var)
       (vug-function-inputs (vug-variable-value ,ugen-var))
     (declare (ignorable ,args-var))
     (let ((,name-var (unquote-vug-symbol-name ,name-var)))
       ,@body)))

(defun ugen-arg-types-from-var (ugen-var)
  (ugen-arg-types (with-ugen-name-and-args (ugen-var name args) (ugen name))))

(defun get-default-arg-value (type)
  (cond ((foreign-type-p type)
         (cond ((member type '(negative-sample non-positive-sample))
                (sample -1.0d0))
               ((foreign-sample-type-p type) (sample 1.0d0))
               ((foreign-float-type-p type) 1.0)
               ((foreign-double-type-p type) 1.0d0)
               ((or (foreign-int32-type-p type) (foreign-int64-type-p type)) 1)
               ((foreign-pointer-type-p type) (cffi:null-pointer))))
        ((subtypep type 'alexandria:negative-real) (coerce -1 type))
        ((subtypep type 'number) (coerce 1 type))
        ((subtypep type 'function) #'dummy-function)
        ((subtypep type 'array) #())))

(defun init-modulated-ugen (var)
  (blockexpand
    (loop for x in (vug-function-inputs (vug-variable-value var))
          for type in `(nil ,@(ugen-arg-types-from-var var) nil)
          collect (if (performance-time-code-p var x nil)
                      (get-default-arg-value type)
                      x))))

(define-constant +ctrl-foreign-object+ 1)
(define-constant +ctrl-update-function+ 2)

(declaim (inline ctrl-foreign-object-p))
(defun ctrl-foreign-object-p (flag)
  (logtest flag +ctrl-foreign-object+))

(declaim (inline ctrl-update-function-p))
(defun ctrl-update-function-p (flag)
  (logtest flag +ctrl-update-function+))

(defun perf-modulated-ugen (var)
  (with-ugen-name-and-args (var name args)
    (let ((varname (vug-object-name var)))
      `(progn
         ,@(loop for arg in (butlast args)  ; The last arg is (DSP-NODE)
                 for flag in (ugen-control-flags (ugen name))
                 for i from 0 by 2
                 when (performance-time-code-p var arg nil)
                   append (ugen-param-dependence varname arg i flag nil t))
         ,varname))))

(declaim (inline vug-variable-value-to-cache-p))
(defun vug-variable-value-to-cache-p (var)
  (and *common-code-in-local-functions-p*
       (member var (vug-variables-bindings-to-cache *vug-variables*))))

(defmacro with-init-frames (&body body)
  `(let ((current-channel 0)
         (current-frame 0)
         (current-sample 0))
     (declare (type channel-number current-channel)
              (type non-negative-fixnum current-frame current-sample)
              (ignorable current-channel current-frame current-sample))
     ,@body))

;;; (Re)init time: local bindings
(defun %set-let-variables-loop (variables finally-func)
  (declare (type list variables) (type function finally-func))
  (loop for vars on variables by #'cdr
        for var = (car vars)
        until (or (foreign-object-p var)
                  (vug-variable-value-to-cache-p var))
        unless (vug-variable-temporary-p var)
        collect `(,(vug-object-name var)
                  ,(cond ((init-time-p var)
                          (blockexpand (remove-wrapped-parens
                                         (vug-variable-value var))))
                         ((ugen-variable-p var)
                          `(get-ugen-instance ,@(init-modulated-ugen var)))
                         ((integer-has-zero-p (vug-object-type var)) 0)
                         ((vug-type-p var 'positive-fixnum) 1)
                         ((vug-type-p var 'negative-fixnum) -1)))
        finally (funcall finally-func vars)))

;;; (Re)init time: setter forms for the slots of the foreign array
(defun %set-setf-variables-loop (variables finally-func)
  (declare (type list variables) (type function finally-func))
  (loop for vars on variables by #'cdr
        for var = (car vars)
        while (and (foreign-object-p var)
                   (not (vug-variable-value-to-cache-p var)))
        when (and (init-time-p var)
                  (not (vug-variable-value-zero-p var)))
        collect `(setf ,(vug-object-name var)
                       ,(blockexpand (remove-wrapped-parens
                                       (vug-variable-value var))))
        finally (funcall finally-func vars)))

;;; (Re)init time: declarations for the local bindings
(defun %set-local-declarations (variables stop-var)
  (declare (type list variables))
  (loop for var in variables
        for type = (vug-object-type var)
        until (eq var stop-var)
        unless (or (foreign-sample-type-p type) (null type))
        collect `(declare (type ,type ,(vug-object-name var)))))

;;; Bindings during the (re)initialization
(defun %set-variables (variables body)
  (declare (type list variables))
  (let* ((rest nil)
         (finally-func (lambda (x) (setf rest x))))
    (if variables
        (let ((var (car variables)))
          (cond
            ((vug-variable-value-to-cache-p var)
             (let ((setter-name (vug-variable-setter-name var)))
               `((flet ((,setter-name ()
                          ,(if (ugen-variable-p var)
                               `(get-ugen-instance ,@(init-modulated-ugen var))
                               (blockexpand (remove-wrapped-parens
                                              (vug-variable-value var))))))
                   ,@(if (foreign-object-p var)
                         `((setf ,(vug-object-name var) (,setter-name))
                           ,@(%set-variables (cdr variables) body))
                         `((let* ((,(vug-variable-name var) (,setter-name))
                                  ,@(%set-let-variables-loop (cdr variables)
                                                             finally-func))
                             ,@(%set-local-declarations variables (car rest))
                             ,@(%set-variables rest body))))))))
            ((foreign-object-p var)
             `(,@(%set-setf-variables-loop variables finally-func)
               ,@(%set-variables rest body)))
            (t
             `((let* ,(%set-let-variables-loop variables finally-func)
                 ,@(%set-local-declarations variables (car rest))
                 ,@(%set-variables rest body))))))
        body)))

(defun %expand-local-functions (&rest rest)
  (multiple-value-bind (fname local-decl)
      (if *common-code-in-local-functions-p*
          (values 'labels
                  (list
                    (mapcar (lambda (v)
                              `(,(vug-variable-setter-name v) ()
                                 (setf ,(vug-variable-name v)
                                       ,(blockexpand (vug-variable-value v)
                                                     nil t))))
                            (vug-variables-to-expand-multiple-times
                              *vug-variables*))))
          (values 'progn nil))
    `(,fname ,@local-decl ,@rest)))

(defmacro %expand-variables (&body body)
  ``(with-init-frames
      ,@(%set-variables (vug-variables-bindings *vug-variables*)
                        (list (%expand-local-functions ,@body)))))

(defun update-variable-values (variables)
  (dolist (var variables variables)
    (when (reducible-vug-variable-p var)
      (let ((value (let ((res (or (vug-variable-replacement var)
                                  (vug-variable-value var))))
                     (if (vug-variable-p res)
                         (vug-variable-replacement res)
                         res))))
        (when (reducible-vug-function-p value)
          (replace-vug-variable var (reduce-vug-function value))
          (msg-debug-delete-variable var "init-time"))))))

(defun format-vug-code (vug-block)
  (let ((vug-form (cond ((vug-progn-function-p vug-block)
                         (vug-function-inputs vug-block))
                        ((atom vug-block) (list vug-block))
                        (t (remove-wrapped-parens vug-block)))))
    (reorder-parameter-list)
    (find-bindings-to-cache
      (setf #1=(vug-variables-bindings *vug-variables*)
            (delete-if #'vug-variable-deleted-p
                       (update-variable-values (nreverse #1#)))))
    (prog1 (blockexpand vug-form nil t)
      ;; Some variables could be deleted during the generation of the code.
      (setf #1# (delete-if #'vug-variable-deleted-p #1#)))))

(macrolet (;; Add and count the variables with the foreign TYPE
           (define-add-*-variables (type)
             `(defmacro ,(vug-format-symbol "ADD-~A-VARIABLES" type) ()
                (with-gensyms (v counter)
                  `(loop for ,v in (vug-variables-bindings *vug-variables*)
                         with ,counter = 0 do
                           (when (,',(vug-format-symbol "FOREIGN-~A-TYPE-P" type)
                                     (vug-object-type ,v))
                             (push ,v (,',(vug-format-symbol
                                            "VUG-VARIABLES-FOREIGN-~A" type)
                                        *vug-variables*))
                             (incf ,counter))
                         finally (return ,counter))))))
  (define-add-*-variables sample)
  (define-add-*-variables float)
  (define-add-*-variables double)
  (define-add-*-variables int32)
  (define-add-*-variables int64)
  (define-add-*-variables pointer))

(defun rt-free-foreign-array-sample (obj)
  (declare (type foreign-array obj))
  (rt-eval ()
    (incudine.util::foreign-rt-free-sample #1=(foreign-array-data obj))
    (setf #1# nil)
    (tg:cancel-finalization obj)
    (incudine::rt-foreign-array-pool-push obj)
    (values)))

(declaim (inline make-rt-foreign-sample-array))
(defun make-rt-foreign-sample-array (dimension)
  ;; Use a separate memory pool for the SAMPLE type
  (let* ((data (incudine.util::foreign-rt-alloc-sample dimension t))
         (obj (incudine::fill-foreign-array (incudine::rt-foreign-array-pool-pop)
                                            data dimension 'sample
                                            #'rt-free-foreign-array-sample)))
    (tg:finalize obj (lambda ()
                       (rt-eval ()
                         (incudine.util::foreign-rt-free-sample data))))
    obj))

(declaim (inline make-foreign-sample-array))
(defun make-foreign-sample-array (dimension)
  (if (allow-rt-memory-p)
      (make-rt-foreign-sample-array dimension)
      (incudine::make-nrt-foreign-array dimension 'sample t nil nil)))

(defmacro with-foreign-symbols ((variables c-vector type) &body body)
  (let ((count 0))
    `(symbol-macrolet
         ,(mapcar (lambda (var-name)
                    ;; Memo: GET-POINTER depends on the follow line
                    (prog1 `(,var-name (mem-aref ,c-vector ,type ,count))
                      (incf count)))
                  variables)
       ,@body)))

;;; Retrieve the pointer to a slot of a foreign array.
(defmacro get-pointer (foreign-variable &environment env)
  (destructuring-bind (ptr type count)
      ;; FOREIGN-VARIABLE is defined by WITH-FOREIGN-SYMBOLS, so we
      ;; can use the list (mem-aref ptr type count) to get the needed
      ;; informations about the pointer.
      (cdr (macroexpand-1 foreign-variable env))
    `(inc-pointer ,ptr (the non-negative-fixnum
                            (* ,count
                               (the non-negative-fixnum
                                    (cffi:foreign-type-size ,type)))))))

(defmacro %with-sample-variables ((variables &rest unused) &body body)
  (declare (ignore unused))
  `(let ,(mapcar (lambda (var-name) `(,var-name ,+sample-zero+))
                 variables)
     ,@(if variables `((declare (type sample ,@variables))))
     ,@body))

(defmacro with-sample-variables ((variables &rest unused) &body body)
  `(,@(if variables
          `(#.(if *use-foreign-sample-p*
                  'with-foreign-symbols
                  '%with-sample-variables)
            (,variables ,@unused))
          '(progn))
      ,@body))

(defun vug-parameter-fix-dependences (par)
  (dolist (var (vug-parameter-vars-to-update par) par)
    (multiple-value-bind (cached cached-p)
        (vug-variable-replacement var)
      (if cached-p
          (cond ((vug-variable-p cached)
                 (setf (vug-variable-name var) (vug-variable-name cached)
                       (vug-variable-value var) (vug-variable-value cached)))
                (t (undelete-vug-variable var)
                   (pushnew var *variables-to-preserve*)
                   (msg debug "undelete ~A (fix dependences in ~A)" var par)))
          (pushnew var *variables-to-preserve*)))))

(defun reorder-parameter-list ()
  (setf #1=(vug-variables-parameter-list *vug-variables*)
        (let ((acc))
          (dolist (par #1# acc)
            (push (vug-parameter-fix-dependences par) acc)))))

(defun dsp-vug-block (arguments &rest rest)
  (multiple-value-bind (args types) (arg-names-and-types arguments)
    `(reduce-vug-variables
       (with-vug-arguments (,args ,types)
         (vug-block (with-argument-bindings (,args ,types) ,@rest))))))

(defmacro with-foreign-variables (specs &body body)
  (let ((ret body))
    (dolist (i (remove-if #'null specs :key #'car))
      (setf ret `((with-foreign-symbols ,i ,@ret))))
    `(progn ,@ret)))

(defmacro vug-foreign-varnames (type)
  `(mapcar #'vug-object-name
           (,(format-symbol :incudine.vug "VUG-VARIABLES-FOREIGN-~A" type)
             *vug-variables*)))

(defun sample-array-bindings (name wrap-name size)
  (when (reduce-warnings
          (and #.*use-foreign-sample-p* (plusp size)))
    `((,wrap-name (make-foreign-sample-array ,size))
      (,name (foreign-array-data ,wrap-name)))))

(defun foreign-array-bindings (array-bindings)
  (flet ((foreign-array-binding (array-var array-wrap-var type size)
           (when (plusp size)
             `((,array-wrap-var (make-foreign-array ,size ,type :zero-p t))
               (,array-var (foreign-array-data ,array-wrap-var))))))
    (loop for args in array-bindings
          append (apply #'foreign-array-binding args))))

(defun initialization-code ()
  (unless (empty-initialization-code-stack-p)
    (list *initialization-code*)))

(declaim (inline vug-variables-foreign-sample-names))
(defun vug-variables-foreign-sample-names ()
  (mapcar #'vug-object-name
          (vug-variables-foreign-sample *vug-variables*)))

(defmacro with-dsp-preamble ((dsp-var name control-table-var
                              free-hook-var) &body body)
  (with-gensyms (dsp-wrap function-object node)
    `(let* ((,dsp-wrap (dsp-inst-pool-pop))
            (,dsp-var (unwrap-dsp ,dsp-wrap))
            ;; Hash table for the controls of the DSP
            (,control-table-var (dsp-controls ,dsp-var))
            ;; Function related with the DSP
            (,function-object (symbol-function ,name))
            ;; FREE-HOOK for the node
            (,free-hook-var
             (list (lambda (,node)
                     (declare (ignore ,node) #.*reduce-warnings*)
                     (if (eq ,function-object (symbol-function ,name))
                         ;; The instance is reusable the next time
                         (store-dsp-instance ,name ,dsp-wrap)
                         (free-dsp-wrap ,dsp-wrap))))))
       (declare (type cons ,dsp-wrap ,free-hook-var) (type dsp ,dsp-var)
                (type hash-table ,control-table-var))
       ,@body)))

(defmacro with-foreign-arrays ((smp-spec f32-spec f64-spec i32-spec i64-spec
                                ptr-spec) &body body)
  (destructuring-bind (smpvec smpvecw type smpvec-size) smp-spec
    (declare (ignore type))
    `(let* (,@(sample-array-bindings smpvec smpvecw smpvec-size)
            ,@(foreign-array-bindings `(,f32-spec ,f64-spec ,i32-spec
                                        ,i64-spec ,ptr-spec)))
       ,@body)))

(defun debug-foreign-bytes (array-sample-size array-32-size array-64-size
                            array-ptr-size)
  (msg debug "foreign variables in ~D bytes on the C heap"
       (+ (* +foreign-sample-size+ array-sample-size)
          (* 4 array-32-size)
          (* 8 array-64-size)
          (* +pointer-size+ array-ptr-size))))

(defmacro reset-foreign-arrays (&rest rest)
  `(progn
     ,@(loop for (arr dim type-size) on rest by #'cdddr
             when (plusp dim)
             collect `(incudine.external:foreign-set
                        ,arr 0 ,(* dim type-size)))))

(defmacro generate-dsp-code (name arguments arg-names obj)
  (with-gensyms (vug-body smpvec-size f32vec-size f64vec-size i32vec-size
                 i64vec-size ptrvec-size)
    `(let* ((*vug-variables* (make-vug-variables))
            (*variables-to-preserve* nil)
            (*initialization-code* (make-initialization-code-stack))
            (,vug-body (format-vug-code ,(dsp-vug-block arguments obj)))
            (,smpvec-size (add-sample-variables))
            (,f32vec-size (add-float-variables))
            (,f64vec-size (add-double-variables))
            (,i32vec-size (add-int32-variables))
            (,i64vec-size (add-int64-variables))
            (,ptrvec-size (add-pointer-variables)))
       (debug-deleted-variables)
       (debug-foreign-bytes ,smpvec-size (+ ,f32vec-size ,i32vec-size)
                            (+ ,f64vec-size ,i64vec-size) ,ptrvec-size)
       (with-gensyms (dsp control-table free-hook node smpvecw smpvec f32vecw
                      f32vec f64vecw f64vec i32vecw i32vec i64vecw i64vec
                      ptrvecw ptrvec)
         `(lambda (%dsp-node%)
            (declare #.*standard-optimize-settings*
                     (type incudine:node %dsp-node%))
            (with-dsp-preamble (,dsp ,',name ,control-table ,free-hook)
              (with-foreign-arrays ((,smpvec ,smpvecw 'sample ,,smpvec-size)
                                    (,f32vec ,f32vecw :float ,,f32vec-size)
                                    (,f64vec ,f64vecw :double ,,f64vec-size)
                                    (,i32vec ,i32vecw :int32 ,,i32vec-size)
                                    (,i64vec ,i64vecw :int64 ,,i64vec-size)
                                    (,ptrvec ,ptrvecw :pointer ,,ptrvec-size))
                (with-sample-variables (,(vug-variables-foreign-sample-names)
                                        ,smpvec 'sample)
                  (with-foreign-variables
                      ((,(vug-foreign-varnames float) ,f32vec :float)
                       (,(vug-foreign-varnames double) ,f64vec :double)
                       (,(vug-foreign-varnames int32) ,i32vec :int32)
                       (,(vug-foreign-varnames int64) ,i64vec :int64)
                       (,(vug-foreign-varnames pointer) ,ptrvec :pointer))
                    ,(%expand-variables
                       (set-controls-form control-table ',arg-names)
                       (reorder-initialization-code)
                       `(progn
                          (setf (dsp-name ,dsp) ,',name)
                          (setf (node-controls %dsp-node%) ,control-table)
                          (update-free-hook %dsp-node% ,free-hook)
                          ,@(initialization-code)
                          (set-dsp-object ,dsp
                            :init-function
                              (lambda (,node ,@',arg-names)
                                (declare #.*reduce-warnings*)
                                (reset-foreign-arrays
                                  ,smpvec ,,smpvec-size ,+foreign-sample-size+
                                  ,f32vec ,,f32vec-size 4
                                  ,f64vec ,,f64vec-size 8
                                  ,i32vec ,,i32vec-size 4
                                  ,i64vec ,,i64vec-size 8
                                  ,ptrvec ,,ptrvec-size ,+pointer-size+)
                                (setf (node-controls ,node) (dsp-controls ,dsp))
                                (setf %dsp-node% ,node)
                                (with-init-frames
                                  ,(reinit-bindings-form)
                                  (update-free-hook ,node ,free-hook)
                                  ,@(initialization-code))
                                ,node)
                            :free-function
                              ,(to-free-form smpvecw ,smpvec-size
                                             f32vecw ,f32vec-size
                                             f64vecw ,f64vec-size
                                             i32vecw ,i32vec-size
                                             i64vecw ,i64vec-size
                                             ptrvecw ,ptrvec-size)
                            :perf-function
                              (lambda ()
                                (with-init-frames
                                  ,@,vug-body
                                  (values))))
                          (values (dsp-init-function ,dsp)
                                  (dsp-perf-function ,dsp)))))))))))))

(defmacro dsp-node () '%dsp-node%)

(declaim (inline update-free-hook))
(defun update-free-hook (node hook)
  (if #1=(incudine::node-free-hook node)
      (setf (cdr (last #1#)) hook)
      (setf #1# hook)))

(declaim (inline without-follow-vug-parameter-p))
(defun without-follow-vug-parameter-p (parameter vug-function)
  (member parameter (mapcar #'vug-variable-value
                            (car (vug-function-inputs vug-function)))
          :test #'eq))

(declaim (inline skip-update-variable-p))
(defun skip-update-variable-p (parameter variable-value)
  (and (vug-function-p variable-value)
       (vug-name-p variable-value 'without-follow)
       (without-follow-vug-parameter-p parameter variable-value)))

(declaim (inline %reinit-vug-variable))
(defun %reinit-vug-variable (var value param-plist)
  `(,(gethash (vug-object-name value) *objects-to-free*)
      ,(vug-object-name var)
      ,(blockexpand (vug-function-inputs value) param-plist)))

(defun %set-vug-variable (var value param-plist)
  (if (object-to-free-p value)
      (%reinit-vug-variable var value param-plist)
      `(setf ,(vug-object-name var)
             ,(if (vug-variable-value-to-cache-p var)
                  (%update-vug-variable var)
                  (blockexpand value param-plist)))))

(defmacro %with-set-control ((type binding) &body body)
  (if (eq type 'sample)
      `(progn (setf ,@binding) ,@body)
      `(let (,binding) ,@body)))

(defstruct (ugen (:copier nil))
  (name nil :type symbol)
  (callback nil :type (or function null))
  (inline-callback #'dummy-function :type function)
  (return-type nil :type (or symbol list))
  (args nil :type list)
  (arg-types nil :type list)
  (control-flags nil :type list))

(defun find-vug-variable (var obj)
  (labels ((find-var (var obj)
             (cond ((vug-variable-p obj)
                    (or (eq var obj)
                        (eq var (vug-variable-replacement obj))))
                   ((vug-function-p obj)
                    (find-var var (vug-function-inputs obj)))
                   ((consp obj)
                    (or (find-var var (car obj))
                        (find-var var (cdr obj)))))))
    (find-var var obj)))

(defmacro set-ugen-control (ugen-var index value)
  `(setf (smp-ref (svref (ugen-instance-controls ,ugen-var) ,index) 0) ,value))

(defmacro update-ctl-ugen-deps (ugen-var index &rest value)
  `(funcall (the function (svref (ugen-instance-controls ,ugen-var) ,index))
            ,@value))

(defun ugen-param-dependence (var value index flag param-plist
                              &optional vug-body-p)
  (let ((form (blockexpand value param-plist vug-body-p)))
    (cond ((ctrl-foreign-object-p flag)
           `((set-ugen-control ,var ,index ,form)
             ,@(when (ctrl-update-function-p flag)
                 `((update-ctl-ugen-deps ,var ,(1+ index))))))
          ((ctrl-update-function-p flag)
           `((update-ctl-ugen-deps ,var ,(1+ index) ,form))))))

(defun set-ugen-param-deps (ugen-name ugen-var args param param-plist)
  (let ((u (ugen ugen-name)))
    `(progn
       ,@(loop for var in (vug-parameter-vars-to-update param) append
              (loop for arg in args
                    for flag in (ugen-control-flags u)
                    for i from 0 by 2
                    when (and (vug-object-p arg)
                              (not (vug-object-block-p arg))
                              (find-vug-variable var arg))
                      append (ugen-param-dependence ugen-var arg i flag
                                                    param-plist))))))

(declaim (inline get-param-plist))
(defun get-param-plist (param)
  (list (vug-object-name param)
        (vug-object-name (car (vug-parameter-vars-to-update param)))))

;;; VUG-VARIABLEs to update after the change of a control of a DSP
(defun control-dependence (param)
  (let ((param-plist (get-param-plist param)))
    (mapcar
      (lambda (var)
        (let ((value (vug-variable-value var)))
          (unless (skip-update-variable-p param value)
            (cond ((ugen-variable-p var)
                   (with-ugen-name-and-args (var name args)
                     (set-ugen-param-deps name (vug-object-name var) args param
                                          param-plist)))
                  ((vug-variable-temporary-p var)
                   ;; The VUG-VARIABLE is unused (update only the value).
                   (if (object-to-free-p value)
                       (%reinit-vug-variable var value param-plist)
                       (if (vug-variable-value-to-cache-p var)
                           (%update-vug-variable var)
                           (blockexpand value param-plist))))
                  (t (%set-vug-variable var value param-plist))))))
      (cdr (vug-parameter-vars-to-update param)))))

(defun dsp-coercing-argument (arg type)
  (cond ((foreign-float-type-p type) `(coerce ,arg 'single-float))
        ((foreign-double-type-p type) `(coerce ,arg 'double-float))
        ((foreign-non-sample-type-p type) arg)
        ((subtypep type 'sample) `(force-sample-format ,arg))
        ((compound-type-p type) `(the ,type ,arg))
        (t `(coerce ,arg ',type))))

(defun dsp-control-setter-func (param)
  (with-gensyms (value)
    `(lambda (,value)
       (declare #.*reduce-warnings*)
       (setf ,(vug-parameter-aux-varname param)
             ,(dsp-coercing-argument value (vug-object-type param)))
       ,@(control-dependence param)
       (values))))

(defun dsp-control-getter-func (param)
  `(lambda ()
     (declare #.*reduce-warnings*)
     ,(vug-parameter-aux-varname param)))

(defun dsp-control-update-ptr-dep-func (param)
  `(lambda ()
     ,@(when (cdr (vug-parameter-vars-to-update param))
         `((declare #.*reduce-warnings*)
           ,@(control-dependence param)))))

(defun dsp-control-list-func ()
  `(lambda ()
     (declare #.*reduce-warnings*)
     (list ,@(mapcar #'vug-parameter-aux-varname
                     (vug-variables-parameter-list *vug-variables*)))))

(defun dsp-control (obj control-table &optional pointer-p)
  (let ((name (etypecase obj
                (vug-object (vug-object-name-string obj))
                (string obj))))
    `(gethash ,(if pointer-p `(list :pointer ,name) name)
              ,control-table)))

(defun set-dsp-control (obj control-table &key pointer-p arg-names)
  `(setf ,(dsp-control obj control-table pointer-p)
         ,(cond (pointer-p
                 ;; There is consing, for example, if we call a (not inlined)
                 ;; function with a DOUBLE-FLOAT value, therefore we can
                 ;; directly change the value pointed by a C pointer (CAR) and
                 ;; update the other variables by calling a function (CDR)
                 ;; without arguments.
                 `(reduce-warnings
                    (cons (get-pointer ,(vug-parameter-aux-varname obj))
                          ,(dsp-control-update-ptr-dep-func obj))))
                ((vug-parameter-p obj)
                 `(cons ,(dsp-control-setter-func obj)
                        ,(dsp-control-getter-func obj)))
                ((string= obj "%CONTROL-LIST%")
                 `(cons nil ,(dsp-control-list-func)))
                ((string= obj "%CONTROL-NAMES%")
                 `(cons nil (lambda () ',arg-names))))))

(declaim (inline reorder-vug-parameter-vars-to-update))
(defun reorder-vug-parameter-vars-to-update (param)
  (declare (type vug-parameter param))
  (nreversef (vug-parameter-vars-to-update param)))

(declaim (inline update-vug-parameter-aux-varname))
(defun update-vug-parameter-aux-varname (param)
  (declare (type vug-parameter param))
  (unless (vug-parameter-aux-varname param)
    (setf (vug-parameter-aux-varname param)
          (vug-object-name
            (car (reorder-vug-parameter-vars-to-update param))))))

;;; Fill the hash table for the controls of the DSP
(defun set-controls-form (control-table names)
  (let ((param-list (nreversef (vug-variables-to-update *vug-variables*))))
    `(progn
       ;; Controls
       ,@(mapcar (lambda (p)
                   (update-vug-parameter-aux-varname p)
                   (set-dsp-control p control-table))
                 param-list)
       ;; Control pointers
       ,@(loop for p in param-list
               when (foreign-object-p p)
               collect (set-dsp-control p control-table :pointer-p t))
       ;; List of the control values
       ,(set-dsp-control "%CONTROL-LIST%" control-table)
       ;; List of the control names
       ,(set-dsp-control "%CONTROL-NAMES%" control-table :arg-names names))))

(defun coerce-vug-float (obj type)
  (cond ((foreign-float-type-p type) `(coerce ,obj 'single-float))
        ((foreign-double-type-p type) `(coerce ,obj 'double-float))
        ((foreign-non-sample-type-p type) obj)
        ((subtypep type 'float) `(coerce ,obj ',type))
        (t obj)))

(defmacro update-lisp-array (vug-varname args)
  (with-gensyms (dimensions)
    `(let ((,dimensions ,(first args)))
       (when (atom ,dimensions)
         (setf ,dimensions (list ,dimensions)))
       (unless (equal ,dimensions (array-dimensions ,vug-varname))
         (setf ,vug-varname (make-array ,@args))))))

;;; Dummy FREE method for a lisp-array
(defmethod incudine:free ((obj array))
  (declare (ignore obj))
  (values))

(defmacro update-foreign-array (vug-varname args)
  (with-gensyms (size type initial-contents opts i)
    `(let ((,size ,(car args))
           (,type ,(cadr args)))
       (declare (type positive-fixnum ,size))
       (with-slots (incudine::data incudine::size incudine::type) ,vug-varname
         (cond ((and (equal ,type incudine::type) (= ,size incudine::size))
                (do ((,opts ',(cddr args) (cddr ,opts)))
                    ((null ,opts))
                  (case (car ,opts)
                    (:zero-p (incudine.external:foreign-set incudine::data 0
                               (* ,size (foreign-type-size ,type))))
                    (:initial-contents
                     (let ((,initial-contents (cadr ,opts)))
                       (dotimes (,i (length ,initial-contents))
                         (setf (mem-aref incudine::data ,type ,i)
                               (elt ,initial-contents ,i)))))
                    (:initial-element
                     (dotimes (,i ,size)
                       (setf (mem-aref incudine::data ,type ,i)
                             (cadr ,opts)))))))
               (t (setf incudine::data (foreign-rt-realloc incudine::data ,type
                                                           ,@(cddr args)
                                                           :count ,size)
                        incudine::type ,type
                        incudine::size ,size)))
         ,vug-varname))))

(defun reinit-binding-form (var)
  (declare (type vug-variable var))
  (if (vug-variable-value-to-cache-p var)
      `(setf ,(vug-object-name var) ,(%update-vug-variable var))
      (let* ((value (vug-variable-value var))
             (update-fname (when (vug-function-p value)
                             (gethash (vug-object-name value)
                                      *objects-to-free*))))
        (if update-fname
            `(,update-fname ,(vug-object-name var)
                            ,(if (not (init-time-p var))
                                 (init-modulated-ugen var)
                                 (blockexpand (vug-function-inputs value))))
            `(setf ,(vug-object-name var)
                   ,(if (vug-parameter-p value)
                        (coerce-vug-float (vug-object-name value)
                                          (vug-object-type value))
                        (blockexpand value)))))))

(defun reinit-bindings-form ()
  `(progn
     ,@(loop for var in (vug-variables-bindings *vug-variables*)
             when (or (and (init-time-p var)
                           (not (vug-variable-temporary-p var))
                           ;; Unnecessary because each element of the
                           ;; foreign memory is reinitialized to zero.
                           (not (and (foreign-object-p var)
                                     (vug-variable-value-zero-p var))))
                      (ugen-variable-p var))
             collect (reinit-binding-form var))))

;;; ARGS is a list (c-array size c-array size ...)
(defun to-free-form (c-array-sample-wrap sample-size &rest args)
  `(lambda ()
     ;; Free the foreign arrays
     ,@(when (and #.*use-foreign-sample-p* (plusp sample-size))
         `((incudine:free ,c-array-sample-wrap)))
     ,@(loop for (arr size) on args by #'cddr
             when (plusp size)
             collect `(incudine:free ,arr))
     ;; Free all the other objects
     ,@(mapcar (lambda (v) `(incudine:free ,(vug-object-name v)))
               (vug-variables-to-free *vug-variables*))))

(declaim (inline build-control-list))
(defun build-control-list (node &rest options)
  (declare (type incudine:node node))
  (append (incudine:control-list node) options))

(defvar *update-dsp-instances* t)
(declaim (type boolean *update-dsp-instances*))

(declaim (inline %argument-names))
(defun %argument-names (args)
  (mapcar (lambda (x) (if (consp x) (car x) x)) args))

(defmacro get-add-action-and-target (&rest keywords)
  `(cond ,@(mapcar (lambda (x) `(,x (values ,(make-keyword x) ,x)))
                   keywords)
         (t (values :head incudine::*node-root*))))

(declaim (inline compound-type-p))
(defun compound-type-p (type)
  (and (consp type)
       (member (car type) '(or and member eql not satisfies))))

(defun dsp-coercing-arguments (args)
  (mapcar (lambda (x)
            (destructuring-bind (arg type) (if (consp x) x `(,x sample))
              `(,arg ,(dsp-coercing-argument arg type))))
          args))

(defmacro update-dsp-instances (name arg-names)
  (with-gensyms (node)
    `(rt-eval ()
       (incudine:dograph (,node)
         (when (and (eq (incudine::node-name ,node) ',name)
                    (equal (incudine:control-names ,node) ',arg-names))
           (apply #',name (build-control-list ,node :replace ,node)))))))

(defmacro reuse-dsp-instance (dsp node arg-names)
  (with-gensyms (obj)
    `(let ((,obj (car ,dsp)))
       (funcall (dsp-init-function ,obj) ,node ,@arg-names)
       (lambda (,node)
         (declare (ignore ,node))
         (values (dsp-init-function ,obj)
                 (dsp-perf-function ,obj))))))

(declaim (inline set-dsp-arg-names))
(defun set-dsp-arg-names (dsp-name arg-names)
  (setf (dsp-arguments (get-dsp-properties dsp-name)) arg-names))

;;; Returns the function to parse the arguments of a DSP.
(defmacro parse-dsp-args-func (bindings args)
  `(lambda ,args
     (let (,@bindings)
       (list ,@args))))

(defmacro dsp-init-args (bindings arg-names)
  `(list (parse-dsp-args-func ,bindings ,arg-names) ,@arg-names))

(defmacro with-add-action ((add-action target head tail before after replace)
                           &body body)
  `(multiple-value-bind (,add-action ,target)
       (get-add-action-and-target ,head ,tail ,before ,after ,replace)
     (let ((,target (if (numberp ,target)
                        (incudine:node ,target)
                        ,target)))
       ,@body)))

(defmacro enqueue-dsp-node (name node-id arg-names arg-bindings get-dsp-func
                            head tail before after replace stop-hook free-hook
                            action fade-time fade-curve)
  (with-gensyms (node dsp add-action target)
    `(with-add-action (,add-action ,target ,head ,tail ,before ,after ,replace)
       (rt-eval ()
         (let* (,@arg-bindings
                (,node-id (get-node-id ,node-id ,add-action))
                (,node (incudine:node ,node-id)))
           (declare (type non-negative-fixnum ,node-id)
                    (type incudine:node ,node))
           (when (incudine::null-node-p ,node)
             (let ((,dsp (get-next-dsp-instance ',name)))
               (declare (type list ,dsp))
               (incudine::enqueue-node-function
                 (update-node-hooks ,node ,stop-hook ,free-hook)
                 (if ,dsp
                     (reuse-dsp-instance ,dsp ,node ,arg-names)
                     (,get-dsp-func ,@arg-names))
                 (dsp-init-args ,arg-bindings ,arg-names)
                 ,node-id ',name ,add-action ,target ,action ,fade-time
                 ,fade-curve))
             (nrt-msg debug "node ~D ~{~A ~}" ,node-id
                      (list ,@(loop for i in arg-names append `(',i ,i))))))))))

(defmacro maybe-update-dsp-instances (dsp-name arg-names)
  `(when *update-dsp-instances*
     (update-dsp-instances ,dsp-name ,arg-names)))

;;; An argument is a symbol or a pair (NAME TYPE), where TYPE is the specifier
;;; of NAME. When the argument is a symbol, the default type is SAMPLE.
(defmacro dsp! (name args &body body)
  (with-gensyms (get-function)
    (let* ((doc (when (stringp (car body)) (car body)))
           (body (if doc (cdr body) body))
           (arg-names (%argument-names args))
           (dsp-arg-bindings (dsp-coercing-arguments args)))
      `(macrolet ((,get-function ,arg-names
                    `(prog1
                       ,(generate-dsp-code ',name ,args ,arg-names
                                           (progn ,@body))
                       (nrt-msg info "new alloc for DSP ~A" ',',name))))
         (cond ((vug ',name)
                (msg error "~A was defined to be a VUG" ',name))
               ((ugen ',name)
                (msg error "~A was defined to be an UGEN" ',name))
               (t
                ;; If there is a DSP called NAME, remove the cached instances.
                (free-dsp-instances ',name)
                (set-dsp-arg-names ',name ',arg-names)
                (defun ,name (,@arg-names &key id head tail before after replace
                              action stop-hook free-hook fade-time fade-curve)
                  (declare (type (or fixnum null) id)
                           (type (or incudine:node fixnum null) head tail before
                                 after replace)
                           (type (or function null) action)
                           (type list stop-hook free-hook))
                  ,doc
                  (enqueue-dsp-node ,name id ,arg-names ,dsp-arg-bindings
                                    ,get-function head tail before after replace
                                    stop-hook free-hook action fade-time
                                    fade-curve)
                  (values))
                (maybe-update-dsp-instances ,name ,arg-names)
                #',name))))))

(declaim (inline get-node-id))
(defun get-node-id (id add-action)
  (cond (id id)
        ((eq add-action :replace) (incudine::next-large-node-id))
        (t (incudine:next-node-id))))

(declaim (inline update-node-hooks))
(defun update-node-hooks (node stop-hook free-hook)
  (if stop-hook (setf (incudine::node-stop-hook node) stop-hook))
  (if free-hook (setf (incudine::node-free-hook node) free-hook))
  node)

(defmacro %codegen-debug (name args arg-names codegen-fname rest &body body)
  (let ((doc (if (stringp (car body)) (car body))))
    `(lambda ,arg-names
       (let ,(dsp-coercing-arguments args)
         (,codegen-fname ',name ,args ,arg-names ,@rest
                         (progn ,@(if doc (cdr body) body)))))))

(defmacro %%codegen-debug (name args codegen-fname rest &body body)
  (with-gensyms (fn stream)
    (let ((lambda-list (%argument-names args)))
      `(let ((,fn (%codegen-debug ,name ,args ,lambda-list ,codegen-fname ,rest
                    ,@body)))
         (lambda (,@lambda-list &optional ,stream)
           (flet ((codegen () (funcall ,fn ,@lambda-list)))
             (if ,stream
                 (let ((*print-gensym* nil))
                   (pprint (codegen) ,stream))
                 (codegen))))))))

;;; Return a function to show the code generated by DSP!.
;;; The arguments of the function are the arguments of the dsp
;;; plus one optional STREAM.
(defmacro dsp-debug (name args &body body)
  `(%%codegen-debug ,name ,args generate-dsp-code nil ,@body))
