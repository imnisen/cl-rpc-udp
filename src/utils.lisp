(in-package :cl-rpc-udp)


(defmacro with-lock-held ((lock) &body body)
  "Simple wrapper to allow LispWorks and Bordeaux Threads to coexist."
  `(bt:with-lock-held (,lock) ,@body))

(defun ip-vector-to-string (array)
  (format nil "~{~a~^.~}" (coerce array 'list)))
