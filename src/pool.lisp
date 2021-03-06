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

(in-package :incudine.util)

;;; CONS-POOL

(defstruct (cons-pool (:copier nil))
  (data nil :type list)
  (size 0 :type non-negative-fixnum)
  (expand-func #'identity :type function)
  (grow 128 :type non-negative-fixnum))

(defmethod print-object ((obj cons-pool) stream)
  (format stream "#<CONS-POOL ~D>" (cons-pool-size obj)))

(defmacro expand-cons-pool (pool delta new)
  (with-gensyms (lst p d value i exp-size)
    `(let ((,p ,pool)
           (,d ,delta)
           (,value ,new))
       (declare (type cons-pool ,p) (type positive-fixnum ,d))
       (labels ((expand (,lst ,i)
                  (declare (type non-negative-fixnum ,i)
                           (type list ,lst))
                  (if (zerop ,i)
                      ,lst
                      (expand (cons ,value ,lst) (1- ,i)))))
         (with-slots (data size grow) ,p
           (let ((,exp-size (max ,d grow)))
             (incf size ,exp-size)
             (setf data (expand data ,exp-size))))))))

(defmacro cons-pool-push-cons (pool cons)
  (with-gensyms (p x)
    `(let ((,p ,pool)
           (,x ,cons))
       (declare (type cons ,x) (type cons-pool ,p))
       (with-slots (data size) ,p
         (incf size)
         (setf (cdr ,x) data data ,x)))))

(defmacro cons-pool-pop-cons (pool)
  (with-gensyms (p result)
    `(let ((,p ,pool))
       (declare (type cons-pool ,p))
       (with-slots (data size expand-func) ,p
         (when (zerop size)
           (funcall expand-func ,p))
         (let ((,result data))
           (decf size)
           (setf data (cdr data)
                 (cdr ,result) nil)
           ,result)))))

(defmacro cons-pool-push-list (pool list)
  (with-gensyms (lst p i l)
    `(let ((,p ,pool)
           (,lst ,list))
       (declare (type list ,lst) (type cons-pool ,p))
       (do ((,i 1 (1+ ,i))
            (,l ,lst (cdr ,l)))
           ((null (cdr ,l))
            (with-slots (data size) ,p
              (incf size ,i)
              (setf (cdr ,l) data data ,lst)))
         (declare (type positive-fixnum ,i) (type list ,l))))))

(defmacro cons-pool-pop-list (pool list-size)
  (with-gensyms (lsize p i lst)
    `(let ((,lsize ,list-size)
           (,p ,pool))
       (declare (type positive-fixnum ,lsize)
                (type cons-pool ,p))
       (with-slots (data size) ,p
         (when (< size ,lsize)
           (expand-global-pool ,p ,lsize))
         (do ((,i 1 (1+ ,i))
              (,lst data (cdr ,lst)))
             ((= ,i ,lsize)
              (prog1 data
                (decf size ,lsize)
                (setf data (cdr ,lst))
                (setf (cdr ,lst) nil)))
           (declare (type positive-fixnum ,i) (type list ,lst)))))))

;;; NRT GLOBAL CONS-POOL (used in nrt-thread)

(declaim (inline expand-global-pool))
(defun expand-global-pool (pool &optional (delta 1))
  (expand-cons-pool pool delta nil))

(defvar *nrt-global-pool* (make-cons-pool :data (make-list 2048)
                                          :size 2048
                                          :expand-func #'expand-global-pool
                                          :grow 2048))
(declaim (type cons-pool *nrt-global-pool*))

(defvar *nrt-global-pool-spinlock* (make-spinlock "NRT-GLOBAL-POOL"))
(declaim (type spinlock *nrt-global-pool-spinlock*))

(defun nrt-global-pool-push-cons (cons)
  (with-spinlock-held (*nrt-global-pool-spinlock*)
    (cons-pool-push-cons *nrt-global-pool* cons)))

(defun nrt-global-pool-pop-cons ()
  (with-spinlock-held (*nrt-global-pool-spinlock*)
    (cons-pool-pop-cons *nrt-global-pool*)))

(defun nrt-global-pool-push-list (lst)
  (with-spinlock-held (*nrt-global-pool-spinlock*)
    (cons-pool-push-list *nrt-global-pool* lst)))

(defun nrt-global-pool-pop-list (list-size)
  (with-spinlock-held (*nrt-global-pool-spinlock*)
    (cons-pool-pop-list *nrt-global-pool* list-size)))

;;; RT GLOBAL CONS-POOL (used in rt-thread)

(defvar *rt-global-pool* (make-cons-pool :data (make-list 2048)
                                         :size 2048
                                         :expand-func #'expand-global-pool
                                         :grow 2048))
(declaim (type cons-pool *rt-global-pool*))

(declaim (inline rt-global-pool-push-cons))
(defun rt-global-pool-push-cons (cons)
  (cons-pool-push-cons *rt-global-pool* cons))

(declaim (inline rt-global-pool-pop-cons))
(defun rt-global-pool-pop-cons ()
  (cons-pool-pop-cons *rt-global-pool*))

(declaim (inline rt-global-pool-push-list))
(defun rt-global-pool-push-list (lst)
  (cons-pool-push-list *rt-global-pool* lst))

(declaim (inline rt-global-pool-pop-list))
(defun rt-global-pool-pop-list (list-size)
  (cons-pool-pop-list *rt-global-pool* list-size))

;;; TLIST

(declaim (inline set-cons))
(defun set-cons (cons new-car new-cdr)
  (declare (type cons cons))
  (setf (car cons) new-car
        (cdr cons) new-cdr))

(declaim (inline make-tlist))
(defun make-tlist (pool)
  (declare (type cons-pool pool))
  (let ((entry (cons-pool-pop-cons pool)))
    (set-cons entry nil nil)
    entry))

(declaim (inline tlist-left))
(defun tlist-left (tl) (caar tl))

(declaim (inline tlist-right))
(defun tlist-right (tl) (cadr tl))

(declaim (inline tlist-empty-p))
(defun tlist-empty-p (tl) (null (car tl)))

(declaim (inline tlist-add-left))
(defun tlist-add-left (tl obj pool)
  (declare (type cons tl) (type cons-pool pool))
  (let ((entry (cons-pool-pop-cons pool)))
    (set-cons entry obj (car tl))
    (if (tlist-empty-p tl)
        (setf (cdr tl) entry))
    (setf (car tl) entry)))

(declaim (inline tlist-add-right))
(defun tlist-add-right (tl obj pool)
  (declare (type cons tl) (type cons-pool pool))
  (let ((entry (cons-pool-pop-cons pool)))
    (set-cons entry obj nil)
    (if (tlist-empty-p tl)
        (setf (car tl) entry)
        (setf (cddr tl) entry))
    (setf (cdr tl) entry)))

(declaim (inline tlist-remove-left))
(defun tlist-remove-left (tl pool)
  (declare (type cons tl) (type cons-pool pool))
  (unless (tlist-empty-p tl)
    (let ((entry (car tl)))
      (setf (car tl) (cdar tl))
      (cons-pool-push-cons pool entry)
      (if (tlist-empty-p tl)
          (setf (cdr tl) nil))
      (car entry))))

;;; FOREIGN MEMORY POOL

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defvar *foreign-sample-pool-size* (* 64 1024 1024))

  (defvar *foreign-rt-memory-pool-size* (* 64 1024 1024))

  (defvar *foreign-nrt-memory-pool-size* (* 64 1024 1024))

  (defvar *foreign-sample-pool*
    (foreign-alloc :char :count *foreign-sample-pool-size*))

  (defvar *foreign-rt-memory-pool*
    (foreign-alloc :char :count *foreign-rt-memory-pool-size*))

  ;;; This pool is used in non-realtime for short temporary arrays.
  (defvar *foreign-nrt-memory-pool*
    (foreign-alloc :char :count *foreign-nrt-memory-pool-size*))

  (defvar *initialized-foreign-memory-pools* nil)

  ;;; Lock used only to free the memory if the rt-thread is absent
  ;;; (memory allocated in realtime but the rt-thread has been terminated)
  (defvar *rt-memory-lock* (bt:make-lock "RT-MEMORY"))
  (defvar *rt-memory-sample-lock* (bt:make-lock "RT-MEMORY-SAMPLE"))

  ;;; Lock to alloc/free the memory in non-realtime.
  (defvar *nrt-memory-lock* (make-spinlock "NRT-MEMORY"))

  (defun init-foreign-memory-pools ()
    (unless *initialized-foreign-memory-pools*
      (incudine.external:init-foreign-memory-pool
       *foreign-sample-pool-size* *foreign-sample-pool*)
      (incudine.external:init-foreign-memory-pool
       *foreign-rt-memory-pool-size* *foreign-rt-memory-pool*)
      (incudine.external:init-foreign-memory-pool
       *foreign-nrt-memory-pool-size* *foreign-nrt-memory-pool*)
      (setf *initialized-foreign-memory-pools* t)))

  (defvar *add-init-foreign-memory-pools-p* t)
  (when *add-init-foreign-memory-pools-p*
    (setf *add-init-foreign-memory-pools-p* nil)
    (init-foreign-memory-pools)
    (push (lambda () (init-foreign-memory-pools))
          incudine::*initialize-hook*)))

;;; Realtime version of CFFI:FOREIGN-ALLOC.
;;; The NULL-TERMINATED-P keyword is removed.
(defun foreign-rt-alloc (type &key zero-p initial-element initial-contents
                         (count 1 count-p))
  "Allocate enough memory to hold COUNT objects of type TYPE. If
ZEROP is T, the memory is initialized with zeros. If INITIAL-ELEMENT
is supplied, each element of the newly allocated memory is initialized
with its value. If INITIAL-CONTENTS is supplied, each of its elements
will be used to initialize the contents of the newly allocated memory."
  (let (contents-length)
    (when initial-contents
      (setq contents-length (length initial-contents))
      (if count-p
          (assert (>= count contents-length))
          (setq count contents-length)))
    (let* ((size (* (foreign-type-size type) count))
           (ptr (incudine.external:foreign-rt-alloc-ex
                   size *foreign-rt-memory-pool*)))
      (cond (zero-p (incudine.external:foreign-set ptr 0 size))
            (initial-contents
             (dotimes (i contents-length)
               (setf (mem-aref ptr type i) (elt initial-contents i))))
            (initial-element
             (dotimes (i count)
               (setf (mem-aref ptr type i) initial-element))))
      ptr)))

(declaim (inline %foreign-rt-free))
(defun %foreign-rt-free (ptr)
  (incudine.external:foreign-rt-free-ex ptr *foreign-rt-memory-pool*))

(declaim (inline foreign-rt-free))
(defun foreign-rt-free (ptr)
  (if *rt-thread*
      (%foreign-rt-free ptr)
      (bt:with-lock-held (*rt-memory-lock*)
        (%foreign-rt-free ptr))))

(defun foreign-rt-realloc (ptr type &key zero-p initial-element initial-contents
                           (count 1 count-p))
  "Changes the size of the memory block pointed to by ptr to hold COUNT
objects of type TYPE. If ZEROP is T, the memory is initialized with zeros.
If INITIAL-ELEMENT is supplied, each element of the newly reallocated
memory is initialized with its value. If INITIAL-CONTENTS is supplied,
each of its elements will be used to initialize the contents of the newly
reallocated memory."
  (let (contents-length)
    (when initial-contents
      (setq contents-length (length initial-contents))
      (if count-p
          (assert (>= count contents-length))
          (setq count contents-length)))
    (let* ((size (* (foreign-type-size type) count))
           (ptr (incudine.external:foreign-rt-realloc-ex
                   ptr size *foreign-rt-memory-pool*)))
      (cond (zero-p (incudine.external:foreign-set ptr 0 size))
            (initial-contents
             (dotimes (i contents-length)
               (setf (mem-aref ptr type i) (elt initial-contents i))))
            (initial-element
             (dotimes (i count)
               (setf (mem-aref ptr type i) initial-element))))
      ptr)))

(declaim (inline foreign-rt-alloc-sample))
(defun foreign-rt-alloc-sample (size &optional zerop)
  (let* ((dsize (* size +foreign-sample-size+))
         (ptr (incudine.external:foreign-rt-alloc-ex
                 dsize *foreign-sample-pool*)))
    (when zerop (incudine.external:foreign-set ptr 0 dsize))
    ptr))

(declaim (inline %foreign-rt-free-sample))
(defun %foreign-rt-free-sample (ptr)
  (incudine.external:foreign-rt-free-ex ptr *foreign-sample-pool*))

(declaim (inline foreign-rt-free-sample))
(defun foreign-rt-free-sample (ptr)
  (if *rt-thread*
      (%foreign-rt-free-sample ptr)
      (bt:with-lock-held (*rt-memory-sample-lock*)
        (%foreign-rt-free-sample ptr))))

(declaim (inline foreign-rt-realloc-sample))
(defun foreign-rt-realloc-sample (ptr size &optional zerop)
  (let* ((dsize (* size +foreign-sample-size+))
         (ptr (incudine.external:foreign-rt-realloc-ex
                 ptr dsize *foreign-sample-pool*)))
    (when zerop (incudine.external:foreign-set ptr 0 dsize))
    ptr))

;;; Based on CFFI:FOREIGN-ALLOC to use TLSF Memory Storage allocator.
;;; The NULL-TERMINATED-P keyword is removed.
(defun foreign-nrt-alloc (type &key zero-p initial-element initial-contents
                          (count 1 count-p))
  "Allocate enough memory to hold COUNT objects of type TYPE. If
ZEROP is T, the memory is initialized with zeros. If INITIAL-ELEMENT
is supplied, each element of the newly allocated memory is initialized
with its value. If INITIAL-CONTENTS is supplied, each of its elements
will be used to initialize the contents of the newly allocated memory."
  (let (contents-length)
    (when initial-contents
      (setq contents-length (length initial-contents))
      (if count-p
          (assert (>= count contents-length))
          (setq count contents-length)))
    (let* ((size (* (foreign-type-size type) count))
           (ptr (with-spinlock-held (*nrt-memory-lock*)
                  (incudine.external:foreign-rt-alloc-ex
                   size *foreign-nrt-memory-pool*))))
      (cond (zero-p (incudine.external:foreign-set ptr 0 size))
            (initial-contents
             (dotimes (i contents-length)
               (setf (mem-aref ptr type i) (elt initial-contents i))))
            (initial-element
             (dotimes (i count)
               (setf (mem-aref ptr type i) initial-element))))
      ptr)))

(defun foreign-nrt-free (ptr)
  (with-spinlock-held (*nrt-memory-lock*)
    (incudine.external:foreign-rt-free-ex ptr *foreign-nrt-memory-pool*)))

(declaim (inline get-foreign-sample-used-size))
(defun get-foreign-sample-used-size ()
  (incudine.external:get-foreign-used-size *foreign-sample-pool*))

(declaim (inline get-foreign-sample-free-size))
(defun get-foreign-sample-free-size ()
  (- *foreign-sample-pool-size* (get-foreign-sample-used-size)))

(declaim (inline get-foreign-sample-max-size))
(defun get-foreign-sample-max-size ()
  (incudine.external:get-foreign-max-size *foreign-sample-pool*))

(declaim (inline get-rt-memory-used-size))
(defun get-rt-memory-used-size ()
  (incudine.external:get-foreign-used-size *foreign-rt-memory-pool*))

(declaim (inline get-rt-memory-free-size))
(defun get-rt-memory-free-size ()
  (- *foreign-rt-memory-pool-size* (get-rt-memory-used-size)))

(declaim (inline get-rt-memory-max-size))
(defun get-rt-memory-max-size ()
  (incudine.external:get-foreign-max-size *foreign-rt-memory-pool*))

(declaim (inline get-nrt-memory-used-size))
(defun get-nrt-memory-used-size ()
  (incudine.external:get-foreign-used-size *foreign-nrt-memory-pool*))

(declaim (inline get-nrt-memory-free-size))
(defun get-nrt-memory-free-size ()
  (- *foreign-nrt-memory-pool-size* (get-nrt-memory-used-size)))

(declaim (inline get-nrt-memory-max-size))
(defun get-nrt-memory-max-size ()
  (incudine.external:get-foreign-max-size *foreign-nrt-memory-pool*))
