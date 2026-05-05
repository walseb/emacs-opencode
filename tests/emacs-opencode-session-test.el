;;; emacs-opencode-session-test.el --- Tests for session data model  -*- lexical-binding: t; -*-

(require 'ert)
(require 'emacs-opencode-session)

;;; session struct

(ert-deftest test-opencode-session/create ()
  "Create a session struct and access fields."
  (let ((session (opencode-session-create
                  :id "s1"
                  :slug "my-session"
                  :version 1
                  :project-id "p1"
                  :directory "/tmp"
                  :title "Test"
                  :status "idle")))
    (should (opencode-session-p session))
    (should (equal (opencode-session-id session) "s1"))
    (should (equal (opencode-session-slug session) "my-session"))
    (should (= (opencode-session-version session) 1))
    (should (equal (opencode-session-title session) "Test"))
    (should (equal (opencode-session-status session) "idle"))))

(ert-deftest test-opencode-session/nil-fields ()
  "Unset fields default to nil."
  (let ((session (opencode-session-create :id "s1")))
    (should (null (opencode-session-title session)))
    (should (null (opencode-session-status session)))
    (should (null (opencode-session-summary session)))))

(ert-deftest test-opencode-session/mutate-fields ()
  "Mutate session fields via setf."
  (let ((session (opencode-session-create :id "s1")))
    (setf (opencode-session-title session) "New Title")
    (should (equal (opencode-session-title session) "New Title"))
    (setf (opencode-session-status session) "running")
    (should (equal (opencode-session-status session) "running"))))

;;; opencode-status struct

(ert-deftest test-opencode-status/create-defaults ()
  "Status struct defaults to nil fields."
  (let ((status (opencode-status-create :type "idle")))
    (should (opencode-status-p status))
    (should (equal (opencode-status-type status) "idle"))
    (should (null (opencode-status-attempt status)))
    (should (null (opencode-status-message status)))
    (should (null (opencode-status-next status)))))

(ert-deftest test-opencode-status/create-retry ()
  "Status struct preserves retry fields."
  (let ((status (opencode-status-create
                 :type "retry"
                 :attempt 3
                 :message "Rate Limited"
                 :next 1234567890)))
    (should (equal (opencode-status-type status) "retry"))
    (should (= (opencode-status-attempt status) 3))
    (should (equal (opencode-status-message status) "Rate Limited"))
    (should (= (opencode-status-next status) 1234567890))))

(ert-deftest test-opencode-status/busy-p-struct-idle ()
  "Idle struct is not busy."
  (should (null (opencode-status-busy-p
                 (opencode-status-create :type "idle")))))

(ert-deftest test-opencode-status/busy-p-struct-retry ()
  "Retry struct is busy."
  (should (opencode-status-busy-p
           (opencode-status-create :type "retry"))))

(ert-deftest test-opencode-status/busy-p-struct-busy ()
  "Busy struct is busy."
  (should (opencode-status-busy-p
           (opencode-status-create :type "busy"))))

(ert-deftest test-opencode-status/busy-p-string-idle ()
  "String \"idle\" is not busy (legacy compat)."
  (should (null (opencode-status-busy-p "idle"))))

(ert-deftest test-opencode-status/busy-p-string-running ()
  "Arbitrary string status is busy (legacy compat)."
  (should (opencode-status-busy-p "running")))

(ert-deftest test-opencode-status/busy-p-nil ()
  "Nil status is not busy."
  (should (null (opencode-status-busy-p nil))))

(provide 'emacs-opencode-session-test)

;;; emacs-opencode-session-test.el ends here
