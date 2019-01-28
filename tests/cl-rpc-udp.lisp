(defpackage cl-rpc-udp-test
  (:use :cl
        :cl-rpc-udp
        :prove))
(in-package :cl-rpc-udp-test)

;; NOTE: To run this test file, execute `(asdf:test-system :cl-rpc-udp)' in your Lisp.

(plan nil)

;; server
(defparameter *server* (make-instance 'rpc-node))

;; expose first, then start server
(expose *server* "sum" (lambda (a b) (apply #'+ (list a b))))
(expose *server* "mul" (lambda (args) (reduce #'* args)))
(expose *server* "sub" (lambda (&rest args) (reduce #'- args)))
(expose *server* "test-func" (lambda (&rest args)
                               (reduce #'- args)))
(expose *server* "get-address" (lambda (&rest args)
                                 (declare (ignore args))
                                 (format nil "~a:~a" *remote-host* *remote-port*)))

(start *server* "127.0.0.1" 8000)


;; client
(defparameter *client* (make-instance 'rpc-node))

(start *client* "127.0.0.1"  9000)


(unwind-protect
     (progn
       (is (call *client* "sum" '(10 20) "127.0.0.1" 8000) 30 )
       (is (call *client* "mul" '((10 20 30)) "127.0.0.1" 8000) 6000)
       (is (call *client* "sub" '(10 20 30) "127.0.0.1" 8000 :timeout 10) -40)
       (ok (typep (call *client* "get-address" '() "127.0.0.1" 8000) 'string)))
  (stop *client*)
  (stop *server*))

(finalize)
