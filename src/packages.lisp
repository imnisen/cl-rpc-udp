(in-package :cl-user)

(defpackage cl-rpc-udp
  (:use :cl)
  (:nicknames #:rpcudp)
  (:export #:rpc-node
           #:expose
           #:start
           #:stop
           #:call
           #:*remote-host*
           #:*remote-port*))
