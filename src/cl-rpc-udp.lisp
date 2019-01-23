(defpackage cl-rpc-udp
  (:use :cl)
  (:export #:make-server
           #:expose
           #:start
           #:stop

           #:make-client
           #:connect
           #:call
           #:disconnect

           #:*remote-host*
           #:*remote-port*))
(in-package :cl-rpc-udp)

;;; Utils

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


;;; Server

(defclass transport-udp-server ()
  ((socket :initform nil
           :accessor server-socket
           :documentation "The socket listening for incoming
connections.")
   (shutdown-p-lock :accessor server-shutdownp-lock
                    :initform (bt:make-lock "transport-udp-server shutdown-p-lock"))
   (shutdown-p :accessor server-shutdown-p
               :initform nil)
   (backgroud-thread :accessor server-background-thread
                     :initform nil)
   (router :accessor server-router
           :initform (make-hash-table :test 'equal))))


(defgeneric expose (server rpc-name lambda-function)
  (:documentation ""))

(defgeneric start (server &key host port)
  (:documentation ""))

(defgeneric stop (server &optional soft)
  (:documentation ""))

(defun make-server ()
  (make-instance 'transport-udp-server))

(defmethod expose ((server transport-udp-server) rpc-name lambda-function)
  (setf (gethash rpc-name (server-router server)) lambda-function))


(defmethod start ((server transport-udp-server) &key host port)
  (log:info "Server starting listen on address ~a ~a" host port)

  (let ((socket (usocket:socket-connect nil nil
                                        :protocol :datagram
                                        :local-host host
                                        :local-port port)))
    (setf (server-socket server) socket
          (server-background-thread server)
          (bt:make-thread (lambda () (start-background-worker server))
                          :name "server background worker"))))

(defmethod stop ((server transport-udp-server) &optional soft)
  (declare (ignore soft))
  (with-lock-held ((server-shutdownp-lock server))
    (setf (server-shutdown-p server) t))
  (wake-background-woker-for-shutdown server)
  ;; (when soft todo)
  (log:info "server starting join thread")
  (bt:join-thread (server-background-thread server))
  (usocket:socket-close (server-socket server))
  (setf (server-socket server) nil)
  (log:info "server stop")
  )

(defun start-background-worker (server)
  (log:info "Server starting background worker")
  (let ((socket (server-socket server)))
    (unwind-protect
         (loop :for (id rpc-name args remote-host remote-port)
               := (wait-for-client-data socket)
               :do (progn
                     (with-lock-held ((server-shutdownp-lock server))
                       (when (server-shutdown-p server)
                         (log:info "server leaving the background thread")
                         (return)))
                     (generate-response server socket
                                        id rpc-name args
                                        remote-host remote-port)))
      (log:info "Server trying close socket")
      (usocket:socket-close socket)
      (log:info "Server stopped"))))


(defun wake-background-woker-for-shutdown (server)
  "Creates a dummy connection to the acceptor, waking background worker while it is waiting.
This is supposed to force a check of ACCEPTOR-SHUTDOWN-P."
  (handler-case
      (multiple-value-bind (address port) (usocket:get-local-name (server-socket server))
        (log:info "dummy call host: ~a, port:~a" address port)
        (let ((conn (usocket:socket-connect address port :protocol :datagram))
              (buffer (encode-msg "1"))) ;; send somthing dummy

          (handler-case
              (usocket:socket-send conn  buffer (length buffer))
            (error (e)
              (log:info "server wake-background-woker-for-shutdown dummy send error" e)))

          (log:info "dummy call start to close")
          (usocket:socket-close conn)
          (log:info "dummy call have closed")))
    (error (e)
      (log:error :error "server wake-for-shutdown connect failed: ~A" e))))



;; listen helper function
;; client send msg format {"rpc-name":"", "args":#(), "id":""}
(defvar data-max-length 65507)
(defun vector-to-list (v) (coerce v 'list))
(defun wait-for-client-data (socket)
  (multiple-value-bind (return-buffer return-length remote-host remote-port)
      (usocket:socket-receive socket nil data-max-length)
    (log:info "server have received client data")
    (handler-case
        (let* ((msg (decode-msg (subseq return-buffer 0 return-length)))
               (id (gethash "id" msg))
               (rpc-name (gethash "rpc-name" msg))
               (args (gethash "args" msg)))
          (log:info "server receive id:~a, rpc-name: ~a, args: ~a from host: ~a, port: ~a"
                    id rpc-name args remote-host remote-port)
          (list id rpc-name (vector-to-list args) remote-host remote-port))
      (error (e)
        (log:info "server decode msg error" e)
        (list nil nil nil remote-host remote-port)))))

;; generate-response helper function
;; response msg format {"id":"", "result": ""}
(defvar *remote-host*)
(defvar *remote-port*)

(defun generate-response (server socket id rpc-name args remote-host remote-port)
  (let ((result nil)
        (msg (make-hash-table :test 'equal))
        (buffer nil))

    (handler-case
        (setf result (let ((*remote-host* remote-host)
                           (*remote-port* remote-port))
                       (apply (gethash rpc-name (server-router server))
                              args)))
      (error (e)
        (log:info "server method process error:e , return nil" e)))

    (setf (gethash "id" msg) id
          (gethash "result" msg) result)
    (setf buffer (encode-msg msg))
    (usocket:socket-send socket buffer (length buffer)
                         :host remote-host
                         :port remote-port)))


;;; Client

(defclass transport-udp-client ()
  ((host :accessor client-host
         :initarg :host
         :initform nil)
   (port :accessor client-port
         :initarg :port
         :initform nil)

   (outstanding :accessor client-outstanding
                :initform (make-hash-table :test 'equal))
   (outstanding-lock :accessor client-outstanding-lock
                     :initform (bt:make-lock "outstanding-lock"))

   (socket :accessor client-socket
           :initform nil)

   (shutdown-p-lock :accessor client-shutdownp-lock
                    :initform (bt:make-lock "transport-udp-client shutdown-p-lock"))
   (shutdown-p :accessor client-shutdown-p
               :initform nil)
   (backgroud-thread :accessor client-background-thread
                     :initform nil)))


(defgeneric connect (client &key host port)
  (:documentation ""))

(defgeneric call (client rpc-name args &key timeout)
  (:documentation ""))

(defgeneric disconnect (client)
  (:documentation ""))


(defun make-client ()
  (make-instance 'transport-udp-client))


(defmethod connect ((client transport-udp-client) &key host port)
  (log:info "client connecting to host:~a  port: ~a" host port)

  (let ((socket (usocket:socket-connect host port
                                        :protocol :datagram)))
    (setf (client-socket client) socket
          (client-host client) host
          (client-port client) port
          (client-background-thread client) (bt:make-thread (lambda () (client-work-background client))
                                                            :name "Background client"))
    ))


(defmethod call ((client transport-udp-client) rpc-name args &key (timeout 5))

  (let* ((msg (construct-request-msg rpc-name args))
         (buffer (encode-msg msg)))

    (log:info "client call server host:~a port:~a with msg:~a" (client-host client) (client-port client) msg)
    (set-needed-field client (gethash "id" msg))
    (request-server client buffer)
    (wait-fetching-result client (gethash "id" msg) timeout))
  )


(defmethod disconnect ((client transport-udp-client))

  (with-lock-held ((client-shutdownp-lock client))
    (setf (client-shutdown-p client) t))

  ;; (wake-client-background-woker-for-shutdown client)

  (log:info "client starting close socket")
  ;; very rude here, try to figure a method to stop it softly
  ;; here can't be same like server's stop, because I can't send a dummy request to client with the socket(?)
  (usocket:socket-close (client-socket client))

  (log:info "client starting join thread")

  (bt:join-thread (client-background-thread client))

  (setf (client-socket client) nil)
  (log:info "client stop"))


;; call helper methods
(defun construct-request-msg (rpc-name args)
  (let ((msg (make-hash-table :test 'equal)))
    (setf (gethash "rpc-name" msg) rpc-name
          (gethash "id" msg) (generate-msg-id)
          (gethash "args" msg) args)
    msg))

(defun set-needed-field (client id)
  (with-lock-held ((client-outstanding-lock client))
    (setf (gethash id (client-outstanding client)) nil)))

(defun request-server (client buffer)
  (handler-case
      (usocket:socket-send (client-socket client) buffer (length buffer))
    (error (c)
      (log:info "Notice: connecting error" c " to"
                (client-host client)
                (client-port client)))))

(defvar check-time-interval 0.2)
(defun wait-fetching-result (client id timeout)

  (loop :with end-time := (and timeout (+ (get-internal-real-time)
                                          (* internal-time-units-per-second timeout)))
        :and result := nil
        :while (or (null end-time)
                   (< (get-internal-real-time) end-time))
        :do (progn
              (with-lock-held ((client-outstanding-lock client))
                (when (gethash id (client-outstanding client)) ;; the result can't be nil?
                  (setf result (gethash id (client-outstanding client)))
                  (log:info "result is" result)
                  (return result)))
              (sleep check-time-interval)
              (log:info "once")))
  )
;; connect helper methods
;; Backgroud thread, receive result
(defun client-work-background (client)
  (loop :for (id result) := (wait-for-server-data (client-socket client))
        :do (progn
              (with-lock-held ((client-shutdownp-lock client))
                (when (client-shutdown-p client)
                  (log:info "client leaving the background thread")
                  (return)))
              (with-lock-held ((client-outstanding-lock client))
                (if (nth-value 1 (gethash id (client-outstanding client)))
                    (setf (gethash id (client-outstanding client)) result)
                    (log:info "Unknown msg id:~a" id))))))

;; client-work-background helper function
;; server send msg format {"id":"", "result":""}
(defun wait-for-server-data (socket)
  (handler-case
      (multiple-value-bind (return-buffer return-length)
          (usocket:socket-receive socket nil data-max-length)
        (log:info "client have received server data")
        (handler-case
            (let* ((msg (decode-msg (subseq return-buffer 0 return-length)))
                   (id (gethash "id" msg))
                   (result (gethash "result" msg)))
              (log:info "client receive id:~a, result: ~a from server"
                        id result)
              (list id result))
          (error (e)
            (log:info "client decode msg error" e)
            (list nil nil))))
    (error (e)
      (log:info "client wait-for-server-data error" e)
      (list nil nil))))



(defun wake-client-background-woker-for-shutdown (client)
  "Creates a dummy connection to the acceptor, waking background worker while it is waiting.
This is supposed to force a check of ACCEPTOR-SHUTDOWN-P."
  (handler-case
      (multiple-value-bind (address port) (usocket:get-local-name (client-socket client))
        (log:info "client dummy call host: ~a, port:~a" address port)
        (let ((socket (usocket:socket-connect address port :protocol :datagram))
              (buffer (encode-msg "1"))) ;; send somthing dummy

          (handler-case
              (usocket:socket-send socket buffer (length buffer))
            (error (e)
              (log:info "client wake-background-woker-for-shutdown dummy send error" e)))

          (log:info "client dummy call start to close")
          (usocket:socket-close socket)
          (log:info "client dummy call have closed")))
    (error (e)
      (log:error :error "client wake-for-shutdown connect failed: ~A" e))))
