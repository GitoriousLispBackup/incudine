;;; Copyright (c) 2013 Tito Latini
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

(defvar *initialization-code* nil)
(declaim (type list *initialization-code*))

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
                                                       :value nil :type 'boolean)))
             (setf (vug-variable-conditional-expansion value) var-name)
             (push cond-expand-var (vug-variables-bindings *vug-variables*)))))
        ((vug-function-p value)
         (mapc #'resolve-conditional-expansion (vug-function-inputs value)))))

(defun expand-setter-form (obj init-time-p)
  (do ((l (vug-function-inputs obj) (cddr l)))
      ((null l))
    (declare (type list l))
    (let ((input (car l)))
      (when (vug-variable-p input)
        (if init-time-p
            (resolve-conditional-expansion input))
        (cond ((performance-time-p input)
               (setf (vug-variable-to-set-p input) nil))
              (t (if init-time-p
                     (setf (vug-variable-skip-init-set-p input) t)
                     (setf (vug-variable-to-set-p input) nil))
                 (setf (vug-variable-performance-time-p input) t)))))))

;;; Transform a VUG block in lisp code
(defun blockexpand (obj &optional param-plist vug-body-p init-time-p
                    (conditional-expansion-p t))
  (declare (type list param-plist) (type boolean vug-body-p))
  (cond ((consp obj)
         (cons (blockexpand (car obj) param-plist vug-body-p init-time-p
                            conditional-expansion-p)
               (blockexpand (cdr obj) param-plist vug-body-p init-time-p
                            conditional-expansion-p)))
        ((vug-function-p obj)
         (when (and vug-body-p (setter-form-p (vug-object-name obj)))
           (expand-setter-form obj init-time-p))
         (cond ((consp (vug-object-name obj)) (vug-object-name obj))
               ((vug-name-p obj 'initialize)
                (if (null *initialization-code*)
                    ;; Inside a definition of a VUG
                    (blockexpand (vug-function-inputs obj) param-plist vug-body-p
                                 init-time-p conditional-expansion-p)
                    ;; Inside a definition of a SYNTH
                    (push `(progn ,@(blockexpand (vug-function-inputs obj)
                                                 param-plist vug-body-p t nil))
                          *initialization-code*))
                (values))
               ((vug-name-p obj 'progn)
                (if (cdr (vug-function-inputs obj))
                    `(progn ,@(blockexpand (vug-function-inputs obj)
                                           param-plist vug-body-p
                                           init-time-p conditional-expansion-p))
                    (blockexpand (car (vug-function-inputs obj))
                                 param-plist vug-body-p
                                 init-time-p conditional-expansion-p)))
               ((vug-name-p obj 'without-follow)
                `(progn ,@(blockexpand (cdr (vug-function-inputs obj))
                                       param-plist vug-body-p
                                       init-time-p conditional-expansion-p)))
               ((null (vug-function-inputs obj))
                (list (vug-object-name obj)))
               ((vug-name-p obj 'lambda)
                (let ((inputs (vug-function-inputs obj)))
                  `(lambda ,(car inputs) ,@(blockexpand (cadr inputs)))))
               ((vug-name-p obj 'init-only)
                `(progn ,@(blockexpand (vug-function-inputs obj)
                                       param-plist vug-body-p
                                       init-time-p conditional-expansion-p)))
               ((vug-name-p obj 'update)
                (let ((var (car (vug-function-inputs obj))))
                  (if init-time-p
                      (setf (vug-variable-skip-init-set-p var) t)
                      (setf (vug-variable-to-set-p var) nil))
                  `(setf ,(vug-object-name var)
                         ,(blockexpand (vug-variable-value var) nil t
                                       init-time-p conditional-expansion-p))))
               (t (cons (vug-object-name obj)
                        (blockexpand (vug-function-inputs obj)
                                     param-plist vug-body-p
                                     init-time-p conditional-expansion-p)))))
        ((vug-parameter-p obj)
         (cond (vug-body-p
                (unless (vug-parameter-varname obj)
                  (setf (vug-parameter-varname obj)
                        (or (vug-parameter-aux-varname obj)
                            (gensym (string (vug-object-name obj)))))
                  (push obj (vug-variables-from-parameters *vug-variables*))
                  (variable-to-update
                   (%make-vug-variable :name (vug-parameter-varname obj)
                                       :value obj
                                       :type (vug-object-type obj))
                   obj))
                (vug-parameter-varname obj))
               (t (let ((value (getf param-plist (vug-object-name obj))))
                    (or value (vug-parameter-value obj))))))
        ((and (vug-variable-p obj) vug-body-p (vug-variable-to-set-p obj)
              (not (and init-time-p (vug-variable-skip-init-set-p obj)))
              (or (not (init-time-p obj))
                  (and (not (vug-variable-performance-time-p obj))
                       (some #'performance-time-p
                             (vug-variable-variables-to-recheck obj)))))
         (if init-time-p
             (setf (vug-variable-skip-init-set-p obj) t)
             (setf (vug-variable-to-set-p obj) nil))
         (let* ((cond-expand-var (and conditional-expansion-p
                                      (not init-time-p)
                                      (vug-variable-conditional-expansion obj)))
                (set-form `(setf ,(vug-object-name obj)
                                 ,(blockexpand (vug-variable-value obj) nil t
                                               init-time-p
                                               (and conditional-expansion-p
                                                    (null cond-expand-var))))))
           (if cond-expand-var
               ;; COND-EXPAND-VAR is NIL during the process of the first sample
               ;; because the expansion of the code is in the INITIALIZE block
               `(if ,cond-expand-var
                    ,set-form
                    (progn (setq ,cond-expand-var t)
                           ,(vug-object-name obj)))
               set-form)))
        ((or (vug-symbol-p obj) (vug-variable-p obj))
         (vug-object-name obj))
        (t obj)))

(defmacro with-vug-arguments (args types &body body)
  `(let ,(mapcar (lambda (name type)
                   `(,name (make-vug-parameter ',name ,name ',type)))
                 args types)
     ,@body))

(declaim (inline vug-progn-function-p))
(defun vug-progn-function-p (obj)
  (and (vug-object-p obj) (vug-name-p obj 'progn)))

(declaim (inline foreign-sample-p))
(defun foreign-sample-p (type)
  (member type '(sample positive-sample negative-sample
                 non-negative-sample non-positive-sample)))

(declaim (inline foreign-int32-p))
(defun foreign-int32-p (type)
  (declare (ignorable type))
  ;; Useless on 64-bits systems
  #+x86-64 nil
  #-x86-64 (if (consp type)
               (and (member (car type) '(signed-byte unsigned-byte))
                    (= (cadr type) 32))
               (member type '(unsigned-byte signed-byte))))

(declaim (inline foreign-int64-p))
(defun foreign-int64-p (type)
  (if (consp type)
      (and (member (car type) '(signed-byte unsigned-byte))
           (= (cadr type) 64))
      #+x86-64 (member type '(unsigned-byte signed-byte))
      #-x86-64 nil))

(declaim (inline foreign-type-p))
(defun foreign-type-p (type)
  (or (foreign-sample-p type)
      (foreign-int32-p type)
      (foreign-int64-p type)))

(declaim (inline foreign-object-p))
(defun foreign-object-p (var)
  (foreign-type-p (vug-object-type var)))

;;; (Re)init time: local bindings
(defun %set-let-variables-loop (variables finally-func)
  (declare (type list variables) (type function finally-func))
  (loop for vars on variables by #'cdr
        for var = (car vars)
        until (foreign-object-p var)
        if (vug-parameter-p var)
          collect `(,(vug-parameter-varname var) ,(vug-parameter-value var))
        else
          collect `(,(vug-object-name var)
                    ,(if (init-time-p var)
                         (blockexpand (remove-wrapped-parens
                                       (vug-variable-value var)))
                         (cond ((or (member (vug-object-type var)
                                            '(fixnum non-negative-fixnum
                                              non-positive-fixnum signed-byte
                                              unsigned-byte bit))
                                    (and (consp (vug-object-type var))
                                         (member (car (vug-object-type var))
                                                 '(integer unsigned-byte signed-byte))))
                                0)
                               ((vug-type-p var 'positive-fixnum) 1)
                               ((vug-type-p var 'negative-fixnum) -1))))
        finally (funcall finally-func vars)))

;;; (Re)init time: setter forms for the slots of the foreign array
(defun %set-setf-variables-loop (variables finally-func)
  (declare (type list variables) (type function finally-func))
  (loop for vars on variables by #'cdr
        for var = (car vars)
        while (foreign-object-p var)
        when (init-time-p var)
        if (vug-parameter-p var)
          collect `(setf ,(vug-parameter-aux-varname var)
                         ,(vug-parameter-value var))
        else
          collect `(setf ,(vug-object-name var)
                         ,(blockexpand (remove-wrapped-parens (vug-variable-value var))))
        finally (funcall finally-func vars)))

;;; (Re)init time: declarations for the local bindings
(defun %set-local-declarations (variables stop-var control-names-p)
  (declare (type list variables) (type boolean control-names-p))
  (let ((get-varname (if control-names-p
                         #'vug-parameter-varname
                         #'vug-object-name)))
    (loop for var in variables
          for type = (vug-object-type var)
          until (eq var stop-var)
          unless (or (foreign-sample-p type) (null type))
          collect `(declare (type ,type ,(funcall get-varname var))))))

;;; Bindings during the (re)initialization
(defun %set-variables (variables control-names-p body)
  (declare (type list variables) (type boolean control-names-p))
  (let* ((rest nil)
         (finally-func (lambda (x) (setf rest x))))
    (if variables
        (if (foreign-object-p (car variables))
            `(,@(%set-setf-variables-loop variables finally-func)
              ,@(%set-variables rest control-names-p body))
            `((let* ,(%set-let-variables-loop variables finally-func)
                ,@(%set-local-declarations variables (car rest) control-names-p)
                ,@(%set-variables rest control-names-p body))))
        body)))

(defmacro %expand-variables (&body body)
  `(%set-variables (vug-variables-from-parameters *vug-variables*) t
     (%set-variables 
       (setf #1=(vug-variables-bindings *vug-variables*) (nreverse #1#))
       nil (list ,@body))))

(declaim (inline format-vug-code))
(defun format-vug-code (vug-block)
  (blockexpand
   (cond ((vug-progn-function-p vug-block)
          (vug-function-inputs vug-block))
         ((atom vug-block) (list vug-block))
         (t (remove-wrapped-parens vug-block)))
   nil t))

(macrolet (;; Add and count the variables with the foreign TYPE
           (define-add-*-variables (type)
             `(defmacro ,(format-symbol :incudine.vug "ADD-~A-VARIABLES" type) (counter)
                (with-gensyms (v)
                  `(dolist (,v (vug-variables-bindings *vug-variables*))
                     (when (,',(format-symbol :incudine.vug "FOREIGN-~A-P" type)
                               (vug-object-type ,v))
                       (push ,v (,',(format-symbol :incudine.vug
                                                   "VUG-VARIABLES-FOREIGN-~A" type)
                                    *vug-variables*))
                       (incf ,counter))))))
           ;;; Add and count the parameters with the foreign TYPE
           (define-add-*-parameters (type)
             `(defmacro ,(format-symbol :incudine.vug "ADD-~A-PARAMETERS" type) (counter)
                (with-gensyms (p)
                  `(dolist (,p (vug-variables-to-update *vug-variables*))
                     (when (and (vug-parameter-p ,p)
                                (,',(format-symbol :incudine.vug "FOREIGN-~A-P" type)
                                    (vug-object-type ,p)))
                       (push (%make-vug-variable :name (vug-parameter-aux-varname ,p)
                                                 :type (vug-object-type ,p))
                             (,',(format-symbol :incudine.vug
                                                "VUG-VARIABLES-FOREIGN-~A" type)
                                 *vug-variables*))
                       (incf ,counter)))))))
  (define-add-*-variables sample)
  (define-add-*-variables int32)
  (define-add-*-variables int64)
  (define-add-*-parameters sample)
  (define-add-*-parameters int32)
  (define-add-*-parameters int64))

(defmacro add-foreign-vars-and-params (number-of-sample number-of-int32
                                       number-of-int64)
  (declare (ignorable number-of-int32))
  `(progn
     (add-sample-variables  ,number-of-sample)
     #-x86-64
     (add-int32-variables ,number-of-int32)
     (add-int64-variables ,number-of-int64)
     (add-sample-parameters ,number-of-sample)
     #-x86-64
     (add-int32-parameters ,number-of-int32)
     (add-int64-parameters ,number-of-int64)))

;;; Wrapper for a foreign array with type SAMPLE.
;;; It uses a separate pool to alloc/free the memory in realtime
(defstruct (foreign-sample-array (:constructor %make-foreign-sample-array)
                                 (:copier nil))
  (data (error "missing data for the foreign array")
        :type (or foreign-pointer null))
  (size 1 :type positive-fixnum))

(declaim (inline make-foreign-sample-array))
(defun make-foreign-sample-array (dimension)
  (let* ((data (incudine.util::foreign-rt-alloc-sample dimension))
         (obj (%make-foreign-sample-array :data data :size dimension)))
    (tg:finalize obj (lambda ()
                       (rt-eval ()
                         (incudine.util::foreign-rt-free-sample data))))
    obj))

(declaim (inline free-foreign-sample-array))
(defun free-foreign-sample-array (obj)
  (declare (type foreign-sample-array obj))
  (when #1=(foreign-sample-array-data obj)
     (incudine.util::foreign-rt-free-sample #1#)
     (tg:cancel-finalization obj)
     (setf #1# nil)))

(defmacro with-foreign-symbols (variables c-vector type &body body)
  (let ((count 0))
    `(symbol-macrolet
         ,(mapcar (lambda (var-name)
                    (prog1 `(,var-name (mem-aref ,c-vector ,type ,count))
                      (incf count)))
                  variables)
       ,@body)))

(defmacro with-sample-variables (variables unused &body body)
  (declare (ignore unused))
  `(let ,(mapcar (lambda (var-name)
                   `(,var-name ,+sample-zero+))
                 variables)
     ,@(when variables
         `((declare (type sample ,@variables))))
     ,@body))

(declaim (inline reorder-parameter-list))
(defun reorder-parameter-list ()
  (setf #1=(vug-variables-parameter-list *vug-variables*) (nreverse #1#)))

(declaim (inline reorder-initialization-code))
(defun reorder-initialization-code ()
  (setf *initialization-code* (nreverse *initialization-code*)))

(defun synth-vug-block (arguments &rest rest)
  (multiple-value-bind (args types)
      (arg-names-and-types arguments)
    `(with-vug-arguments ,args ,types
       (vug-block
         (with-argument-bindings ,args ,types ,@rest)))))

(defmacro performance-loop (&body body)
  (with-gensyms (i)
    `(foreach-channel (,i *number-of-output-bus-channels*)
       (let ((current-channel ,i))
         (declare (type channel-number current-channel))
         ,@body))))

(defmacro generate-code (name arguments arg-names obj)
  (with-gensyms (result vug-body control-table c-array-sample-wrap
                 c-array-int32-wrap c-array-int64-wrap c-array-sample
                 c-array-int32 c-array-int64 number-of-sample
                 number-of-int32 number-of-int64 synth-cons synth node
                 free-hook function-object)
    `(let* ((*vug-variables* (make-vug-variables))
            (*initialization-code* (list '(values)))
            (,number-of-sample 0)
            (,number-of-int32 0)
            (,number-of-int64 0)
            (,result ,(synth-vug-block arguments obj))
            (,vug-body (format-vug-code ,result)))
       (reorder-parameter-list)
       (add-foreign-vars-and-params ,number-of-sample ,number-of-int32 ,number-of-int64)
       `(lambda (%synth-node%)
          (declare #.*standard-optimize-settings*
                   (type incudine:node %synth-node%))
          (let* ((,',synth-cons (synth-inst-pool-pop-cons))
                 (,',synth (car ,',synth-cons))
                 ;; Hash table for the controls of the synth
                 (,',control-table (synth-controls ,',synth))
                 ;; Function related with the synth
                 (,',function-object (symbol-function ,',name))
                 ;; FREE-HOOK for the node
                 (,',free-hook
                  (list (lambda (,',node)
                          (declare (ignore ,',node)
                                   #.*reduce-warnings*)
                          (if (eq ,',function-object (symbol-function ,',name))
                              ;; The instance is reusable the next time
                              (store-synth-instance ,',name ,',synth-cons)
                              (free-synth-cons ,',synth-cons)))))
                 ;; Foreign array with type SAMPLE
                 ,@(when (locally (declare #.*reduce-warnings*)
                             (and #.*use-foreign-sample-p*
                                  (plusp ,number-of-sample)))
                     `((,',c-array-sample-wrap (make-foreign-sample-array ,,number-of-sample))
                       (,',c-array-sample (foreign-sample-array-data ,',c-array-sample-wrap))))
                 ;; Foreign array with type INT32
                 ,@(when (plusp ,number-of-int32)
                     `((,',c-array-int32-wrap (make-foreign-array ,,number-of-int32 :int32))
                       (,',c-array-int32 (foreign-array-data ,',c-array-int32-wrap))))
                 ;; Foreign array with type INT64
                 ,@(when (plusp ,number-of-int64)
                     `((,',c-array-int64-wrap (make-foreign-array ,,number-of-int64 :int64))
                       (,',c-array-int64 (foreign-array-data ,',c-array-int64-wrap)))))
            (declare (type cons ,',synth-cons ,',free-hook) (type synth ,',synth)
                     (type hash-table ,',control-table))
            (#.(if *use-foreign-sample-p* 'with-foreign-symbols 'with-sample-variables)
               ,(mapcar #'vug-object-name (vug-variables-foreign-sample *vug-variables*))
               ,',c-array-sample 'sample
               (with-foreign-symbols ,(mapcar #'vug-object-name
                                              (vug-variables-foreign-int32 *vug-variables*))
                   ,',c-array-int32 :int32
                 (with-foreign-symbols ,(mapcar #'vug-object-name
                                                (vug-variables-foreign-int64 *vug-variables*))
                     ,',c-array-int64 :int64
                   ,@(%expand-variables
                      (set-controls-form ',control-table ',arg-names)
                      `(progn
                         (setf (synth-name ,',synth) ,',name)
                         (setf (incudine::node-controls %synth-node%) ,',control-table)
                         (update-free-hook %synth-node% ,',free-hook)
                         (reorder-initialization-code)
                         (let ((current-channel 0))
                           (declare (type channel-number current-channel)
                                    (ignorable current-channel))
                           ,@*initialization-code*)
                         (set-synth-object ,',synth
                           :init-function
                           (lambda (,',node ,@',arg-names)
                             (declare #.*reduce-warnings*)
                             (setf (incudine::node-controls ,',node) (synth-controls ,',synth))
                             (setf %synth-node% ,',node)
                             ,(reinit-bindings-form)
                             (update-free-hook ,',node ,',free-hook)
                             (let ((current-channel 0))
                               (declare (type channel-number current-channel)
                                        (ignorable current-channel))
                               ,@*initialization-code*)
                             ,',node)
                           :free-function ,(to-free-form ',c-array-sample-wrap ,number-of-sample
                                                         ',c-array-int32-wrap ,number-of-int32
                                                         ',c-array-int64-wrap ,number-of-int64)
                           :perf-function (lambda ()
                                            (performance-loop ,@,vug-body)))))))))))))

(declaim (inline update-free-hook))
(defun update-free-hook (node hook)
  (if #1=(incudine::node-free-hook node)
      (setf (cdr (last #1#)) hook)
      (setf #1# hook)))

(defmacro %with-set-control ((varname aux-varname varvalue type) &body body)
  (if (or (eq type 'sample)
          (eq varname aux-varname))
      `(progn (setf ,aux-varname (coerce ,varvalue ',type))
              ,@body)
      `(let ((,aux-varname (coerce ,varvalue ',type)))
         ,@body)))

(declaim (inline skip-update-variable-p))
(defun skip-update-variable-p (parameter variable-value)
  (and (vug-function-p variable-value)
       (vug-name-p variable-value 'without-follow)
       (member parameter (mapcar #'vug-variable-value
                                 (car (vug-function-inputs variable-value)))
               :test #'eq)))

;;; Fill the hash table for the controls of the synth
(defun set-controls-form (control-table arg-names)
  (declare (type symbol control-table))
  (with-gensyms (value)
    (let ((param-list (setf #1=(vug-variables-to-update *vug-variables*)
                            (nreverse #1#))))
      (declare (type list param-list))
      `(progn
         ,@(mapcar
            (lambda (p)
              `(setf (gethash ,(symbol-name (vug-object-name p)) ,control-table)
                     (cons
                      ;; The CAR is the function to set the value of a control
                      (lambda (,value)
                        (declare #.*reduce-warnings*)
                        (%with-set-control (,(vug-parameter-varname p)
                                            ,(vug-parameter-aux-varname p)
                                            ,value ,(vug-object-type p))
                            ,(if (and (null (cdr #2=(vug-parameter-vars-to-update p)))
                                      (vug-name-p (car #2#) (vug-parameter-aux-varname p)))
                                 `(values)
                                 `(progn
                                    ,@(mapcar
                                       (lambda (var)
                                         (let ((value (vug-variable-value var)))
                                           (unless (skip-update-variable-p p value)
                                             (if (object-to-free-p value)
                                                 `(,(gethash (vug-object-name value)
                                                             *object-to-free-hash*)
                                                    ,(vug-object-name var)
                                                    ,(blockexpand (vug-function-inputs value)
                                                       (list (vug-object-name p)
                                                             (vug-parameter-aux-varname p))))
                                                 `(setf ,(vug-object-name var)
                                                        ,(blockexpand value
                                                           (list (vug-object-name p)
                                                                 (vug-parameter-aux-varname p))))))))
                                       (setf #2# (nreverse #2#)))
                                    (values)))))
                      ;; The CDR is the function to get the value of a control
                      (lambda ()
                        (declare #.*reduce-warnings*)
                        ,(vug-object-name (car #2#))))))
            param-list)
         ;; List of the control values
         (setf (gethash "%CONTROL-LIST%" ,control-table)
               (cons nil ; no setter
                     (lambda ()
                       (declare #.*reduce-warnings*)
                       (list ,@(mapcar (lambda (p)
                                         (vug-object-name
                                          (car (vug-parameter-vars-to-update p))))
                                       (vug-variables-parameter-list *vug-variables*))))))
         ;; List of the control names
         (setf (gethash "%CONTROL-NAMES%" ,control-table)
               (cons nil (lambda () ',arg-names)))))))

(declaim (inline coerce-vug-float))
(defun coerce-vug-float (obj type)
  (flet ((vug-float-p (x)
           (member x '(double-float float))))
    (if (or (vug-float-p type)
            (and (consp type)
                 (vug-float-p (car type))))
        `(coerce ,obj ',type)
        obj)))

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
  (with-gensyms (size type initial-contents pair i)
    `(let ((,size ,(car args))
           (,type ,(cadr args)))
       (declare (type positive-fixnum ,size))
       (with-slots (incudine::data incudine::size incudine::type) ,vug-varname
         (cond ((and (equal ,type incudine::type)
                     (= ,size incudine::size))
                (do ((,pair ',(cddr args) (cddr ,pair)))
                    ((null ,pair))
                  (case (car ,pair)
                    (:zero-p (incudine.external:foreign-set incudine::data 0
                               (* ,size (foreign-type-size ,type))))
                    (:initial-contents
                     (let ((,initial-contents (cadr ,pair)))
                       (dotimes (,i (length ,initial-contents))
                         (setf (mem-aref incudine::data ,type ,i)
                               (elt ,initial-contents ,i)))))
                    (:initial-element
                     (dotimes (,i ,size)
                       (setf (mem-aref incudine::data ,type ,i) (cadr ,pair)))))))
               (t (setf incudine::data (foreign-rt-realloc incudine::data ,type ,@(cddr args))
                        incudine::type ,type
                        incudine::size ,size)))
         ,vug-varname))))

(defun reinit-bindings-form ()
  `(progn
     ,@(mapcar (lambda (par)
                 `(setf ,(vug-parameter-varname par)
                        ,(coerce-vug-float (vug-object-name par)
                                           (vug-object-type par))))
               (vug-variables-from-parameters *vug-variables*))
     ,@(loop for var in (vug-variables-bindings *vug-variables*)
             when (init-time-p var)
             collect (let* ((value (vug-variable-value var))
                            (update-symbol (when (vug-function-p value)
                                             (gethash (vug-object-name value)
                                                      *object-to-free-hash*))))
                       (if update-symbol
                           `(,update-symbol ,(vug-object-name var)
                                            ,(blockexpand (vug-function-inputs value)))
                           `(setf ,(vug-object-name var)
                                  ,(if (vug-parameter-p value)
                                       (coerce-vug-float (vug-object-name value)
                                                         (vug-object-type value))
                                       (blockexpand value))))))))

(defun to-free-form (c-array-sample-wrap sample-size
                     c-array-int32-wrap int32-size
                     c-array-int64-wrap int64-size)
  (declare (type symbol c-array-sample-wrap c-array-int32-wrap c-array-int64-wrap)
           (type non-negative-fixnum sample-size int32-size int64-size))
  `(lambda ()
     ;; Free the foreign arrays
     ,@(locally (declare #.*reduce-warnings*)
           (when (and #.*use-foreign-sample-p* (plusp sample-size))
             `((free-foreign-sample-array ,c-array-sample-wrap))))
     ,@(when (plusp int32-size)
         `((incudine:free ,c-array-int32-wrap)))
     ,@(when (plusp int64-size)
         `((incudine:free ,c-array-int64-wrap)))
     ;; Free all the other objects
     ,@(mapcar (lambda (v)
                 `(incudine:free ,(vug-object-name v)))
               (vug-variables-to-free *vug-variables*))))

(defmacro synth-node () '%synth-node%)

(defmacro done-action (action)
  `(funcall ,action (synth-node)))

(defmacro done-self ()
  `(incudine::node-done-p (synth-node)))

(defmacro free-self ()
  `(incudine:free (synth-node)))

(defmacro free-self-when-done ()
  `(when (done-self) (free-self)))

(declaim (inline build-control-list))
(defun build-control-list (node &rest options)
  (declare (type incudine:node node))
  (if options
      (let ((args (nreverse (incudine:control-list node))))
        (dolist (i options (nreverse args))
          (push i args)))
      (incudine:control-list node)))

(defvar *update-synth-instances* t)
(declaim (type boolean *update-synth-instances*))

(declaim (inline %argument-names))
(defun %argument-names (args)
  (mapcar (lambda (x) (if (consp x) (car x) x)) args))

(defmacro get-add-action-and-target (&rest keywords)
  `(cond ,@(mapcar (lambda (x)
                     `(,x (values ,(make-keyword x) ,x)))
                   keywords)
         (t (values :head incudine::*node-root*))))

;;; An argument is a symbol or a pair (NAME TYPE), where TYPE is the specifier
;;; of NAME. When the argument is a symbol, the default type is SAMPLE.
(defmacro defsynth (name args &body body)
  (with-gensyms (get-function node synth-cons synth-prop)
    (let ((doc (when (stringp (car body))
                 (car body)))
          (arg-names (%argument-names args)))
      `(macrolet ((,get-function ,arg-names
                    (generate-code ',name ,args ,arg-names
                                   (progn ,@(if doc (cdr body) body)))))
         (cond ((vug ',name)
                (msg error "~A was defined to be a VUG" ',name))
               (t
                (free-synth-instances ',name)
                (let ((,synth-prop (get-synth-properties ',name)))
                  (setf (synth-arguments ,synth-prop) ',arg-names)
                  (defun ,name (,@arg-names &key id head tail before after replace
                                action stop-hook free-hook fade-time fade-curve)
                    (declare (type (or fixnum null) id)
                             (type (or incudine:node fixnum null)
                                   head tail before after replace)
                             (type (or function null) action)
                             (type list stop-hook free-hook))
                    ,doc
                    (multiple-value-bind (add-action target)
                        (get-add-action-and-target head tail before after replace)
                      (let ((target (if (numberp target) (incudine:node target) target)))
                        (rt-eval ()
                          (let (,@(mapcar (lambda (x)
                                            (destructuring-bind (arg type)
                                                (if (consp x) x `(,x sample))
                                              (if (and (consp type)
                                                       (eq (car type) 'or))
                                                  arg `(,arg (coerce ,arg ',type)))))
                                          args)
                                (id (cond (id id)
                                          ((eq add-action :replace)
                                           (incudine::next-large-node-id))
                                          (t (incudine:next-node-id)))))
                            (declare (type non-negative-fixnum id))
                            (let ((,node (incudine:node id)))
                              (declare (type incudine:node ,node))
                              (when (incudine::null-item-p ,node)
                                (let ((,synth-cons (get-next-synth-instance ',name)))
                                  (declare (type list ,synth-cons))
                                  (when stop-hook
                                    (setf (incudine::node-stop-hook ,node) stop-hook))
                                  (when free-hook
                                    (setf (incudine::node-free-hook ,node) free-hook))
                                  (incudine::enqueue-node-function
                                   (if ,synth-cons
                                       (let ((s (car ,synth-cons)))
                                         (funcall (synth-init-function s) ,node ,@arg-names)
                                         (lambda (,node)
                                           (declare (ignore ,node))
                                           (synth-perf-function s)))
                                       (prog1 (,get-function ,@arg-names)
                                         (nrt-msg info "new alloc for synth ~A"
                                                  ',name)))
                                   ,node id ',name add-action target action
                                   fade-time fade-curve))))))))
                    (values))
                  (when *update-synth-instances*
                    (rt-eval ()
                      (incudine:dograph (,node)
                        (when (and (eq (incudine::node-name ,node) ',name)
                                   (equal (incudine:control-names ,node)
                                          ',arg-names))
                          (apply #',name
                                 (build-control-list ,node :replace ,node))))))
                  #',name)))))))

(defmacro defsynth-debug (name args &body body)
  (let ((doc (when (stringp (car body))
               (car body)))
        (arg-names (%argument-names args)))
    `(lambda ,arg-names
       (let ,(mapcar (lambda (x)
                       (destructuring-bind (arg type)
                           (if (consp x) x `(,x sample))
                         `(,arg (coerce ,arg ',type))))
                     args)
         (generate-code ',name ,args ,arg-names
                        (progn ,@(if doc (cdr body) body)))))))
