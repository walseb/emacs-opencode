;;; emacs-opencode-session-vars-test.el --- Tests for shared session state  -*- lexical-binding: t; -*-

(require 'ert)
(require 'emacs-opencode-session-vars)

;;; normalize-items

(ert-deftest test-opencode-session-vars/normalize-items-vector ()
  "Convert vector to list."
  (should (equal (opencode-session--normalize-items [1 2 3]) '(1 2 3))))

(ert-deftest test-opencode-session-vars/normalize-items-list ()
  "Pass list through."
  (should (equal (opencode-session--normalize-items '(1 2)) '(1 2))))

(ert-deftest test-opencode-session-vars/normalize-items-nil ()
  "Return nil for nil."
  (should (null (opencode-session--normalize-items nil))))

(ert-deftest test-opencode-session-vars/normalize-items-other ()
  "Return nil for non-collection input."
  (should (null (opencode-session--normalize-items "string"))))

;;; subagent tracking

(ert-deftest test-opencode-session-vars/subagent-register-lookup ()
  "Register and look up a subagent."
  (let ((opencode-session--subagent-parents (make-hash-table :test 'equal))
        (opencode-session--subagent-tools (make-hash-table :test 'equal)))
    (opencode-session--register-subagent "sub1" "parent1" "part1")
    (let ((parent-info (opencode-session--subagent-parent "sub1")))
      (should (equal (car parent-info) "parent1"))
      (should (equal (cdr parent-info) "part1")))))

(ert-deftest test-opencode-session-vars/subagent-parent-nil ()
  "Return nil for unregistered subagent."
  (let ((opencode-session--subagent-parents (make-hash-table :test 'equal)))
    (should (null (opencode-session--subagent-parent "unknown")))))

(ert-deftest test-opencode-session-vars/subagent-tools-update ()
  "Update and retrieve subagent tool tracking data."
  (let ((opencode-session--subagent-parents (make-hash-table :test 'equal))
        (opencode-session--subagent-tools (make-hash-table :test 'equal)))
    (opencode-session--register-subagent "sub1" "parent1" "part1")
    ;; Add first tool
    (opencode-session--update-subagent-tool
     "sub1" "tool-part-1" "read" '((status . "completed")))
    (let ((tools (opencode-session--subagent-tools-for "sub1")))
      (should (= (length tools) 1))
      (should (equal (alist-get 'tool (car tools)) "read")))
    ;; Add second tool
    (opencode-session--update-subagent-tool
     "sub1" "tool-part-2" "edit" '((status . "running")))
    (should (= (length (opencode-session--subagent-tools-for "sub1")) 2))
    ;; Update first tool
    (opencode-session--update-subagent-tool
     "sub1" "tool-part-1" "read" '((status . "error")))
    (let ((tools (opencode-session--subagent-tools-for "sub1")))
      (should (= (length tools) 2))
      ;; First tool should be updated
      (let ((first (cl-find "tool-part-1" tools
                            :key (lambda (item) (alist-get 'part-id item))
                            :test #'equal)))
        (should (equal (alist-get 'status (alist-get 'state first)) "error"))))))

(ert-deftest test-opencode-session-vars/subagent-cleanup ()
  "Clean up subagent data for a parent session."
  (let ((opencode-session--subagent-parents (make-hash-table :test 'equal))
        (opencode-session--subagent-tools (make-hash-table :test 'equal)))
    (opencode-session--register-subagent "sub1" "parent1" "part1")
    (opencode-session--register-subagent "sub2" "parent1" "part2")
    (opencode-session--register-subagent "sub3" "parent2" "part3")
    (opencode-session--update-subagent-tool "sub1" "t1" "read" '((status . "ok")))
    (opencode-session--update-subagent-tool "sub2" "t2" "edit" '((status . "ok")))
    ;; Clean up parent1's subagents
    (opencode-session--cleanup-subagent "parent1")
    (should (null (opencode-session--subagent-parent "sub1")))
    (should (null (opencode-session--subagent-parent "sub2")))
    (should (null (opencode-session--subagent-tools-for "sub1")))
    ;; parent2's subagent should be untouched
    (should (opencode-session--subagent-parent "sub3"))))

;;; buffer-for-session

(ert-deftest test-opencode-session-vars/buffer-for-session ()
  "Look up a buffer by session ID."
  (let ((opencode-session--buffers (make-hash-table :test 'equal)))
    (should (null (opencode-session--buffer-for-session "s1")))
    (puthash "s1" (current-buffer) opencode-session--buffers)
    (should (eq (opencode-session--buffer-for-session "s1") (current-buffer)))))

(provide 'emacs-opencode-session-vars-test)

;;; emacs-opencode-session-vars-test.el ends here
