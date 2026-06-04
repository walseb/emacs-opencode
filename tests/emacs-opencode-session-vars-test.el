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

;;; any-live-session-buffer

(ert-deftest test-opencode-session-vars/any-live-buffer-no-connection ()
  "With no connection filter, return any live registered buffer."
  (let ((opencode-session--buffers (make-hash-table :test 'equal))
        (buf (generate-new-buffer " *oc-test-any*")))
    (unwind-protect
        (progn
          (puthash "s1" buf opencode-session--buffers)
          (should (eq (opencode-session--any-live-session-buffer) buf)))
      (kill-buffer buf))))

(ert-deftest test-opencode-session-vars/any-live-buffer-skips-dead ()
  "Dead buffers are skipped."
  (let ((opencode-session--buffers (make-hash-table :test 'equal))
        (dead (generate-new-buffer " *oc-test-dead*"))
        (live (generate-new-buffer " *oc-test-live*")))
    (unwind-protect
        (progn
          (puthash "dead" dead opencode-session--buffers)
          (puthash "live" live opencode-session--buffers)
          (kill-buffer dead)
          (should (eq (opencode-session--any-live-session-buffer) live)))
      (when (buffer-live-p live) (kill-buffer live)))))

(ert-deftest test-opencode-session-vars/any-live-buffer-matches-connection ()
  "With a connection filter, only return a buffer on that connection."
  (let ((opencode-session--buffers (make-hash-table :test 'equal))
        (conn-a 'conn-a)
        (conn-b 'conn-b)
        (buf-a (generate-new-buffer " *oc-test-a*"))
        (buf-b (generate-new-buffer " *oc-test-b*")))
    (unwind-protect
        (progn
          (with-current-buffer buf-a
            (setq-local opencode-session--connection conn-a))
          (with-current-buffer buf-b
            (setq-local opencode-session--connection conn-b))
          (puthash "a" buf-a opencode-session--buffers)
          (puthash "b" buf-b opencode-session--buffers)
          (should (eq (opencode-session--any-live-session-buffer conn-a) buf-a))
          (should (eq (opencode-session--any-live-session-buffer conn-b) buf-b)))
      (kill-buffer buf-a)
      (kill-buffer buf-b))))

(ert-deftest test-opencode-session-vars/any-live-buffer-no-connection-match ()
  "Return nil when no buffer matches the requested connection."
  (let ((opencode-session--buffers (make-hash-table :test 'equal))
        (buf (generate-new-buffer " *oc-test-nomatch*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (setq-local opencode-session--connection 'conn-a))
          (puthash "a" buf opencode-session--buffers)
          (should (null (opencode-session--any-live-session-buffer 'conn-other))))
      (kill-buffer buf))))

(provide 'emacs-opencode-session-vars-test)

;;; emacs-opencode-session-vars-test.el ends here
