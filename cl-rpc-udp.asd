#|
  This file is a part of cl-rpc-udp project.
  Copyright (c) 2019 Nisen (imnisen@gmail.com)
|#

#|
  Author: Nisen (imnisen@gmail.com)
|#

(defsystem "cl-rpc-udp"
  :version "0.1.0"
  :author "Nisen"
  :license "MIT"
  :depends-on (:log4cl
               :ironclad
               :usocket
               :yason
               :flexi-streams)
  :components ((:module "src"
                :components
                ((:file "cl-rpc-udp"))))
  :description ""
  :long-description
  #.(read-file-string
     (subpathname *load-pathname* "README.md"))
  :in-order-to ((test-op (test-op "cl-rpc-udp-test"))))
