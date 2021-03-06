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

(define-constant +rt-foreign-array-pool-size+ 500)

(define-constant +rt-foreign-array-pool-grow+ 10)

(define-constant +nrt-foreign-array-pool-size+ 500)

(define-constant +nrt-foreign-array-pool-grow+
    (floor (* +nrt-foreign-array-pool-size+ 0.1)))

(defstruct (foreign-array (:constructor %make-foreign-array)
                          (:copier nil))
  (data nil :type (or foreign-pointer null))
  (type 'sample)
  (size 1 :type positive-fixnum)
  (free-func #'foreign-free :type function))

(declaim (inline expand-foreign-array-pool))
(defun expand-foreign-array-pool (pool &optional (delta 1))
  (expand-cons-pool pool delta (%make-foreign-array)))

(defvar *rt-foreign-array-pool*
  (make-cons-pool :data (loop repeat +rt-foreign-array-pool-size+
                              collect (%make-foreign-array))
                  :size +rt-foreign-array-pool-size+
                  :expand-func #'expand-foreign-array-pool
                  :grow +rt-foreign-array-pool-grow+))
(declaim (type cons-pool *rt-foreign-array-pool*))

(defvar *nrt-foreign-array-pool*
  (make-cons-pool :data (loop repeat +nrt-foreign-array-pool-size+
                              collect (%make-foreign-array))
                  :size +nrt-foreign-array-pool-size+
                  :expand-func #'expand-foreign-array-pool
                  :grow +nrt-foreign-array-pool-grow+))
(declaim (type cons-pool *nrt-foreign-array-pool*))

(defvar *nrt-foreign-array-pool-spinlock* (make-spinlock "NRT-FOREIGN-ARRAY"))
(declaim (type spinlock *nrt-foreign-array-pool-spinlock*))

(declaim (inline rt-foreign-array-pool-pop))
(defun rt-foreign-array-pool-pop ()
  (let* ((cons (cons-pool-pop-cons *rt-foreign-array-pool*))
         (value (car cons)))
    (rt-global-pool-push-cons cons)
    value))

(declaim (inline rt-foreign-array-pool-push))
(defun rt-foreign-array-pool-push (obj)
  (declare (type foreign-array obj))
  (let ((cons (rt-global-pool-pop-cons)))
    (setf (car cons) obj)
    (cons-pool-push-cons *rt-foreign-array-pool* cons)))

(defun nrt-foreign-array-pool-pop ()
  (let* ((cons (with-spinlock-held (*nrt-foreign-array-pool-spinlock*)
                 (cons-pool-pop-cons *nrt-foreign-array-pool*)))
         (value (car cons)))
    (nrt-global-pool-push-cons cons)
    value))

(defun nrt-foreign-array-pool-push (obj)
  (declare (type foreign-array obj))
  (let ((cons (nrt-global-pool-pop-cons)))
    (setf (car cons) obj)
    (with-spinlock-held (*nrt-foreign-array-pool-spinlock*)
      (cons-pool-push-cons *nrt-foreign-array-pool* cons))))

(declaim (inline foreign-array-pool-pop))
(defun foreign-array-pool-pop ()
  (if (allow-rt-memory-p)
      (rt-foreign-array-pool-pop)
      (nrt-foreign-array-pool-pop)))

(declaim (inline foreign-array-pool-push))
(defun foreign-array-pool-push (obj)
   (if (allow-rt-memory-p)
       (rt-foreign-array-pool-push obj)
       (nrt-foreign-array-pool-push obj)))

(declaim (inline fill-foreign-array))
(defun fill-foreign-array (obj data size type free-func)
  (setf (foreign-array-data obj) data
        (foreign-array-size obj) size
        (foreign-array-type obj) type
        (foreign-array-free-func obj) free-func)
  obj)

(defun rt-free-foreign-array (obj)
  (declare (type foreign-array obj))
  (rt-eval () 
    (foreign-rt-free #1=(foreign-array-data obj))
    (setf #1# nil)
    (tg:cancel-finalization obj)
    (rt-foreign-array-pool-push obj)
    (values)))

(declaim (inline nrt-free-foreign-array))
(defun nrt-free-foreign-array (obj)
  (declare (type foreign-array obj))
  (foreign-free #1=(foreign-array-data obj))
  (setf #1# nil)
  (tg:cancel-finalization obj)
  (nrt-foreign-array-pool-push obj)
  (values))

(declaim (inline make-rt-foreign-array))
(defun make-rt-foreign-array (dimension element-type zero-p
                              initial-element initial-contents)
  (let* ((data (foreign-rt-alloc element-type :count dimension
                                 :zero-p zero-p
                                 :initial-element initial-element
                                 :initial-contents initial-contents))
         (obj (fill-foreign-array (rt-foreign-array-pool-pop)
                                  data dimension element-type
                                  #'rt-free-foreign-array)))
    (tg:finalize obj (lambda () (rt-eval () (foreign-rt-free data))))
    obj))

(defun make-nrt-foreign-array-data (dimension element-type zero-p
                                    initial-element initial-contents)
  (cond (zero-p
         (incudine.external:foreign-set
          (foreign-alloc element-type :count dimension)
          0 (* (foreign-type-size element-type) dimension)))
        (initial-element
         (foreign-alloc element-type :count dimension
                        :initial-element initial-element))
        (initial-contents
         (foreign-alloc element-type :count dimension
                        :initial-contents initial-contents))
        (t (foreign-alloc element-type :count dimension))))

(defun make-nrt-foreign-array (dimension element-type zero-p
                               initial-element initial-contents)
  (let* ((data (make-nrt-foreign-array-data dimension element-type zero-p
                                            initial-element
                                            initial-contents))
         (obj (fill-foreign-array (nrt-foreign-array-pool-pop)
                                  data dimension element-type
                                  #'nrt-free-foreign-array)))
    (tg:finalize obj (lambda () (foreign-free data)))
    obj))

(declaim (inline make-foreign-array))
(defun make-foreign-array (dimension element-type &key zero-p
                           initial-element initial-contents)
  (if (allow-rt-memory-p)
      (make-rt-foreign-array dimension element-type zero-p
                             initial-element initial-contents)
      (make-nrt-foreign-array dimension element-type zero-p
                              initial-element initial-contents)))

(declaim (inline free-foreign-array))
(defun free-foreign-array (obj)
  (declare (type foreign-array obj))
  (when (foreign-array-data obj)
    (funcall (foreign-array-free-func obj) obj)
    (values)))

(defmethod free ((obj foreign-array))
  (free-foreign-array obj))

(in-package :incudine.util)

(define-constant +fast-nrt-foreign-array-max-size+ 64)

(defmacro with-foreign-array ((var type &optional (count 1)) &body body)
  (with-gensyms (array-wrap array-wrap-p)
    `(let* ((,array-wrap-p (or (rt-thread-p)
                               (> ,count +fast-nrt-foreign-array-max-size+)))
            (,array-wrap (if ,array-wrap-p
                             (incudine:make-foreign-array ,count ,type)))
            (,var (if ,array-wrap-p
                      (incudine:foreign-array-data ,array-wrap)
                      (incudine.util::foreign-nrt-alloc ,type :count ,count))))
       (declare (ignorable ,array-wrap))
       (unwind-protect (progn ,@body)
         (reduce-warnings
           (if ,array-wrap-p
               (incudine::free-foreign-array ,array-wrap)
               (incudine.util::foreign-nrt-free ,var)))))))

;;; The expansion inside a definition of a VUG is different
;;; (see %WITH-SAMPLES in `vug/vug.lisp')
(defmacro with-samples (bindings &body body)
  (with-gensyms (c-array)
    (let ((size (length bindings))
          (count 0))
      (if *use-foreign-sample-p*
          `(with-foreign-array (,c-array 'sample ,size)
             (symbol-macrolet
                 ,(mapcar (lambda (x)
                            (prog1 `(,(if (consp x) (car x) x)
                                     (smp-ref ,c-array ,count))
                              (incf count)))
                          bindings)
               (psetf ,@(loop for i in bindings
                              when (consp i)
                              append `(,(car i) (sample ,(cadr i)))))
               ,@body))
          `(let (,@(mapcar (lambda (x)
                             (if (consp x)
                                 `(,(car x) (sample ,(cadr x)))
                                 `(,x ,+sample-zero+)))
                           bindings))
             (declare (type sample ,@(mapcar (lambda (x)
                                               (if (consp x) (car x) x))
                                             bindings)))
             ,@body)))))

(defmacro with-samples* (bindings &body body)
  (with-gensyms (c-array)
    (let ((size (length bindings))
          (count 0))
      (if *use-foreign-sample-p*
          `(with-foreign-array (,c-array 'sample ,size)
             (symbol-macrolet
                 ,(mapcar (lambda (x)
                            (prog1 `(,(if (consp x) (car x) x)
                                     (smp-ref ,c-array ,count))
                              (incf count)))
                          bindings)
               (setf ,@(loop for i in bindings
                             when (consp i)
                             append `(,(car i) (sample ,(cadr i)))))
               ,@body))
          `(let* (,@(mapcar (lambda (x)
                              (if (consp x)
                                  `(,(car x) (sample ,(cadr x)))
                                  `(,x ,+sample-zero+)))
                            bindings))
             (declare (type sample ,@(mapcar (lambda (x)
                                               (if (consp x) (car x) x))
                                             bindings)))
             ,@body)))))
