(defpackage cl-rpc-udp-test
  (:use :cl
        :cl-rpc-udp
        :prove))
(in-package :cl-rpc-udp-test)

;; NOTE: To run this test file, execute `(asdf:test-system :cl-rpc-udp)' in your Lisp.

(plan nil)




(defparameter *server* (make-server))

;; expose first, then start server
(expose *server* "sum" (lambda (a b) (apply #'+ (list a b))))
(expose *server* "mul" (lambda (args) (reduce #'* args)))
(expose *server* "sub" (lambda (&rest args) (reduce #'- args)))
(expose *server* "test-func" (lambda (&rest args)
                               (reduce #'- args)))
(expose *server* "get-address" (lambda (&rest args)
                                 (format nil "~a:~a" *remote-host* *remote-port*)))

(start *server* :host "127.0.0.1" :port 30979)


(defparameter *client* (make-client))

(connect *client* :host "127.0.0.1" :port 30979
                  :local-host "127.0.0.1" :local-port 40979)

(unwind-protect
     (progn
       (is (call *client* "sum" '(10 20)) 30)
       (is (call *client* "mul" '((10 20 30))) 6000)
       (is (call *client* "sub" '(10 20 30) :timeout 10) -40)
       (ok (typep (call *client* "get-address" '()) 'string)))
  (disconnect *client*)
  (stop *server*))

(finalize)
