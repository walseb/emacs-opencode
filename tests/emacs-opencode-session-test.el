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

(provide 'emacs-opencode-session-test)

;;; emacs-opencode-session-test.el ends here
