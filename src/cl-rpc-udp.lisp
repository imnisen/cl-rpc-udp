(defpackage cl-rpc-udp
  (:use :cl)
  (:nicknames #:rpcudp)
  (:export #:rpc-node
           #:expose
           #:start
           #:stop
           #:call
           #:*remote-host*
           #:*remote-port*
           ))


(defvar *data-max-length* 65507)
(defvar *remote-host*)
(defvar *remote-port*)
(defvar *check-time-interval* 0.2)



;; request format : {"type": "request", "id": "", "rpc-name": "", "args": (1 2)}
;; response format : {"type": "response", "id": "", "result": ""}

;; TODO 将序列化部分抽取出来，并采用messagepack, 并且固定好能传参的格式


;; utils

(defun decode-msg (bytes)
  (yason:parse (flex:octets-to-string bytes)))

(defun encode-msg (msg)
  (flex:string-to-octets (with-output-to-string (stream)
                           (yason:encode msg stream))))

(defmacro with-lock-held ((lock) &body body)
  "Simple wrapper to allow LispWorks and Bordeaux Threads to coexist."
  `(bt:with-lock-held (,lock) ,@body))

(defun generate-msg-id ()
  (ironclad:byte-array-to-hex-string (ironclad:digest-sequence
                                      :Sha1
                                      (crypto:random-data 32 (crypto:make-prng :fortuna)))))



(defclass rpc-node ()
  ((socket :accessor node-socket
           :initform nil)
   (shutdown-lock :accessor node-shutdown-lock
                  :initform (bt:make-lock "node-shutdown-lock"))
   (shutdown-p :accessor node-shutdown-p
               :initform nil)

   (worker :accessor node-worker
           :initform nil)

   ;; methods no lock here because methods are intend to expose before node started.
   (methods :accessor node-methods
            :initform (make-hash-table :test 'equal))

   (results-lock :accessor node-results-lock
                 :initform (bt:make-lock "node-results-lock"))
   (results :accessor node-results
            :initform (make-hash-table :test 'equal))))


(defgeneric start (node host port)
  (:method ((node rpc-node) host port)
    (setf (node-socket node) (usocket:socket-connect nil nil
                                                     :protocol :datagram
                                                     :local-host host
                                                     :local-port port)
          (node-worker node) (bt:make-thread (lambda () (start-worker node))
                                             :name "node-worker-thread")))
  (:documentation "start as a rpc over udp node"))

(defgeneric stop (node)
  (:method ((node rpc-node))
    (labels ((wake-worker-for-shutdown (node)
               (handler-case
                   (multiple-value-bind (host port) (usocket:get-local-name (node-socket node))
                     (log:info "node dummy call host: ~a, port:~a" host port)

                     (let ((s (usocket:socket-connect host port :protocol :datagram))
                           (buffer (encode-msg "1"))) ;; send something dummy

                       (usocket:socket-send s  buffer (length buffer))
                       (usocket:socket-close s)
                       (log:info "node dummy call closed")))
                 (error (e)
                   (log:error :error "node stop dummy request connect failed: ~A" e)))))

      (with-lock-held ((node-shutdown-lock node))
        (setf (node-shutdown-p node) t))

      (wake-worker-for-shutdown node)

      (log:info "node waiting worker stop")
      (bt:join-thread (node-worker node)) ;; todo incase error, force kill it

      (usocket:socket-close (node-socket node)) ;; make sure socket is closed

      (setf (node-socket node) nil
            (node-worker node) nil)
      (log:info "node stop")
      t))
  (:documentation "stop node"))

(defgeneric call (node rpc-name args dest-host dest-port &key timeout)
  (:method ((node rpc-node) rpc-name args dest-host dest-port &key (timeout 5))
    ;; TODO do some check if the node started or stopped

    (let ((msg (make-hash-table :test 'equal))
          (id (generate-msg-id))
          (buffer nil))

      (setf (gethash "type" msg) "request"
            (gethash "rpc-name" msg) rpc-name
            (gethash "id" msg) id
            (gethash "args" msg) args)

      (setf buffer (encode-msg msg))

      ;; request dest address
      (handler-case
          (usocket:socket-send (nod-socket node) buffer (length buffer) :host dest-host :port dest-port)
        (error (e)
          (log:info "node call to dest(~a:~a) error: ~a" desc-host dest-port e)))


      ;; fetch result
      (loop :with end-time := (and timeout (+ (get-internal-real-time)
                                              (* internal-time-units-per-second timeout)))
            :and result := nil
            :while (or (null end-time)
                       (< (get-internal-real-time) end-time))
            :do (progn
                  (with-lock-held ((node-results-lock node))
                    (when (nth-value 1 (gethash id (node-results node)))
                      (setf result (gethash id (client-outstanding client)))
                      (log:info "node call ~a result is ~a" rpc-name result)
                      (return result)))
                  (sleep *check-time-interval*)
                  (log:info "node wait for result of msg-id: ~a" id))
            :finally (progn
                       (log:info "node call ~a can't fetch result")
                       (return nil)))))
  (:documentation "as a client call remote rpc server"))


(defgeneric expose (node rpc-name function)
  (:method ((node rpc-node) rpc-name function)
    (setf (gethash rpc-name (node-methods node)) function))
  (:documentation "node expose fuction as service"))

(defun start-worker (node)
  (log:info "node worker starting")
  (labels (;; function to get and extract data, return (success is-request id  remote-host remote-port data) format, data is a list
           (receive-data (socket)
             (multiple-value-bind (return-buffer return-length remote-host remote-port)
                 (usocket:socket-receive socket nil *data-max-length*)
               (log:info "node worker get data from host: ~a, port: ~a" remote-host remote-port)
               (handler-case
                   (let* ((msg (decode-msg (subseq return-buffer 0 return-length)))
                          (msg-type (gethash "type" msg)))

                     (cond ((string-equal "request" msg-type)
                            (log:info "node worker get data decode:"
                                      "request" (gethash "id" msg) remote-host remote-port (list (gethash "rpc-name" msg) (gethash "args" msg)))
                            (list t t (gethash "id" msg) remote-host remote-port (list (gethash "rpc-name" msg) (gethash "args" msg))))

                           ((string-equal "response" msg-type)
                            (log:info "node worker get data decode:"
                                      "response" (gethash "id" msg) remote-host remote-port (list (gethash "rpc-name" msg) (gethash "args" msg)))
                            (list t nil (gethash "id" msg) remote-host remote-port (list (gethash "result" msg))))
                           (t (error "error msg type"))))
                 (error (e)
                   (log:info "node worker receive data error:" e)
                   (list nil nil nil  remote-host remote-port ())))) )
           ;; function handle rpc methods call to generate data response
           (apply-function (rpc-name args methods remote-host remote-port)
             (handler-case
                 (let ((*remote-host* remote-host)
                       (*remote-port* remote-port)
                       (result nil))
                   (if (nth-value 1 (gethash rpc-name methods))
                       (progn
                         (setf result (apply (gethash rpc-name methods) args))
                         (log:info "node worker handle rpc method success, result is" result))
                       (log:info "node worker handle rpc method fail, no such method: ~a, result nil" rpc-name))
                   result)
               (error (e)
                 (log:info "node worker handle rpc method error: ~a, return nil" e))))
           ;; function handle send data to remote
           (send-response (socket remote-host remote-port id result)
             (let ((msg (make-hash-table :test 'equal))
                   (buffer nil))
               (setf (gethash "type" msg) "response"
                     (gethash "id" msg) id
                     (gethash "result" msg) result)
               (setf buffer (encode-msg msg))
               (log:info "node worker send msg id:~a result:~a  to remote host: ~a port: ~a" id result remote-host remote-port)
               (usocket:socket-send socket buffer (length buffer)
                                    :host remote-host
                                    :port remote-port)))
           (save-response (id result results-lock results)
             (log:info "node saving msg-id: ~a , result: ~a" id result)
             (with-lock-held (results-lock)
               (setf (gethash id results) result))))

    (with-accessors ((socket node-socket)
                     (shutdown-lock node-shutdown-lock)
                     (shutdown-p node-shutdown-p)
                     (methods node-methods)
                     (results-lock node-results-lock)
                     (results node-results))
        node
      (unwind-protect
           (loop :for (success is-request id remote-host remote-port data)
                 := (receive-data socket)
                 :do (when success
                       (with-lock-held (shutdown-lock)
                         (when shutdown-p (log:info "node worker shutting down") (return)))

                       (if is-request
                           (send-response socket remote-host remote-port id
                                          (apply-function (first data) (second data) methods remote-host remote-port))
                           (save-response id (car data) results-lock results))))
        (log:info "node worker closing socket")
        (usocket:socket-close socket)
        (log:info "node worker socket closed")))))

;;;
;;; Example
;;;

;; ;; server
;; (defparameter *server* (make-instance 'rpc-node))

;; ;; expose first, then start server
;; (expose *server* "sum" (lambda (a b) (apply #'+ (list a b))))
;; (expose *server* "mul" (lambda (args) (reduce #'* args)))
;; (expose *server* "sub" (lambda (&rest args) (reduce #'- args)))
;; (expose *server* "test-func" (lambda (&rest args)
;;                                (reduce #'- args)))
;; (expose *server* "get-address" (lambda (&rest args)
;;                                  (format nil "~a:~a" *remote-host* *remote-port*)))

;; (start *server* :host "127.0.0.1" :port 8000)


;; ;; client
;; (defparameter *client* (make-instance 'rpc-node))

;; (start *client* :host "127.0.0.1" :port 9000)

;; (call *client* "sum" '(10 20) "127.0.0.1" 8000)

;; ;; stop
;; (stop *server*)
;; (stop *client*)
