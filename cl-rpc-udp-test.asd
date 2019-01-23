#|
  This file is a part of cl-rpc-udp project.
  Copyright (c) 2019 Nisen (imnisen@gmail.com)
|#

(defsystem "cl-rpc-udp-test"
  :defsystem-depends-on ("prove-asdf")
  :author "Nisen"
  :license "MIT"
  :depends-on ("cl-rpc-udp"
               "prove")
  :components ((:module "tests"
                :components
                ((:test-file "cl-rpc-udp"))))
  :description "Test system for cl-rpc-udp"

  :perform (test-op (op c) (symbol-call :prove-asdf :run-test-system c)))
