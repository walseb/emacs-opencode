;;; emacs-opencode-message-test.el --- Tests for message data model  -*- lexical-binding: t; -*-

(require 'ert)
(require 'emacs-opencode-message)

;;; message-part struct

(ert-deftest test-opencode-message/part-create ()
  "Create a message part and access fields."
  (let ((part (opencode-message-part-create
               :id "p1"
               :session-id "s1"
               :message-id "m1"
               :type "text"
               :text "hello"
               :tool "bash")))
    (should (opencode-message-part-p part))
    (should (equal (opencode-message-part-id part) "p1"))
    (should (equal (opencode-message-part-type part) "text"))
    (should (equal (opencode-message-part-text part) "hello"))
    (should (equal (opencode-message-part-tool part) "bash"))))

(ert-deftest test-opencode-message/part-nil-fields ()
  "Unset fields default to nil."
  (let ((part (opencode-message-part-create :id "p1")))
    (should (null (opencode-message-part-text part)))
    (should (null (opencode-message-part-tool part)))
    (should (null (opencode-message-part-metadata part)))))

;;; message struct

(ert-deftest test-opencode-message/create ()
  "Create a message and access fields."
  (let ((msg (opencode-message-create
              :id "m1"
              :session-id "s1"
              :role "assistant"
              :model-id "claude-3"
              :provider-id "anthropic")))
    (should (opencode-message-p msg))
    (should (equal (opencode-message-id msg) "m1"))
    (should (equal (opencode-message-role msg) "assistant"))
    (should (equal (opencode-message-model-id msg) "claude-3"))
    (should (equal (opencode-message-provider-id msg) "anthropic"))))

(ert-deftest test-opencode-message/mutate-fields ()
  "Mutate message fields via setf."
  (let ((msg (opencode-message-create :id "m1" :role "user")))
    (setf (opencode-message-role msg) "assistant")
    (should (equal (opencode-message-role msg) "assistant"))
    (setf (opencode-message-text msg) "hello world")
    (should (equal (opencode-message-text msg) "hello world"))))

(provide 'emacs-opencode-message-test)

;;; emacs-opencode-message-test.el ends here
