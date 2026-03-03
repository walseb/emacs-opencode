;;; emacs-opencode-session-handlers-test.el --- Tests for SSE event handlers  -*- lexical-binding: t; -*-

(require 'ert)
(require 'emacs-opencode-session-handlers)

;;; session-error-text

(ert-deftest test-opencode-handlers/error-text-detail-message ()
  "Extract detail message from nested alist."
  (should (equal (opencode-session--session-error-text
                  '((name . "SomeError")
                    (data . ((message . "something went wrong")))))
                 "something went wrong")))

(ert-deftest test-opencode-handlers/error-text-name-only ()
  "Fall back to error name when no detail message."
  (should (equal (opencode-session--session-error-text
                  '((name . "ConnectionError")
                    (data . ((message . "")))))
                 "ConnectionError")))

(ert-deftest test-opencode-handlers/error-text-string ()
  "Handle string error info."
  (should (equal (opencode-session--session-error-text "plain error")
                 "plain error")))

(ert-deftest test-opencode-handlers/error-text-nil ()
  "Fall back to default for nil."
  (should (equal (opencode-session--session-error-text nil)
                 "An error occurred")))

(ert-deftest test-opencode-handlers/error-text-empty-name ()
  "Fall back to default when name is empty."
  (should (equal (opencode-session--session-error-text
                  '((name . "") (data . nil)))
                 "An error occurred")))

;;; permission helpers

(ert-deftest test-opencode-handlers/permission-patterns-vector ()
  "Extract patterns from vector."
  (should (equal (opencode-session--permission-patterns
                  '((patterns . ["*.el" "*.org"])))
                 '("*.el" "*.org"))))

(ert-deftest test-opencode-handlers/permission-patterns-list ()
  "Extract patterns from list."
  (should (equal (opencode-session--permission-patterns
                  '((patterns . ("*.el"))))
                 '("*.el"))))

(ert-deftest test-opencode-handlers/permission-patterns-nil ()
  "Return nil when no patterns."
  (should (null (opencode-session--permission-patterns '((other . "x"))))))

(ert-deftest test-opencode-handlers/permission-detail-read ()
  "Detail for read permission."
  (should (equal (opencode-session--permission-detail
                  '((permission . "read")
                    (metadata . ((filePath . "foo.el")))))
                 "read foo.el")))

(ert-deftest test-opencode-handlers/permission-detail-edit ()
  "Detail for edit permission."
  (should (equal (opencode-session--permission-detail
                  '((permission . "edit")
                    (metadata . ((filepath . "bar.el")))))
                 "edit bar.el")))

(ert-deftest test-opencode-handlers/permission-detail-bash ()
  "Detail for bash permission."
  (should (equal (opencode-session--permission-detail
                  '((permission . "bash")
                    (metadata . ((command . "ls -la")))))
                 "ls -la")))

(ert-deftest test-opencode-handlers/permission-detail-bash-with-description ()
  "Detail for bash permission with description."
  (should (equal (opencode-session--permission-detail
                  '((permission . "bash")
                    (metadata . ((description . "list files")
                                 (command . "ls -la")))))
                 "list files (ls -la)")))

(ert-deftest test-opencode-handlers/permission-detail-glob ()
  "Detail for glob permission."
  (should (equal (opencode-session--permission-detail
                  '((permission . "glob")
                    (metadata . ((pattern . "*.el")))))
                 "glob *.el")))

(ert-deftest test-opencode-handlers/permission-detail-external-directory ()
  "Detail for external directory with pattern."
  (should (equal (opencode-session--permission-detail
                  '((permission . "external_directory")
                    (patterns . ["/tmp/other"])))
                 "access external directory /tmp/other")))

(ert-deftest test-opencode-handlers/permission-detail-nil ()
  "Return nil when no metadata matches."
  (should (null (opencode-session--permission-detail
                 '((permission . "unknown")
                   (metadata . nil))))))

(ert-deftest test-opencode-handlers/permission-prompt-label ()
  "Build a prompt label."
  (let ((result (opencode-session--permission-prompt-label
                 '((permission . "read")
                   (metadata . ((filePath . "foo.el")))))))
    (should (string-match-p "read foo\\.el" result))
    (should (string-suffix-p ": " result))))

(ert-deftest test-opencode-handlers/permission-prompt-label-fallback ()
  "Prompt label falls back to kind."
  (let ((result (opencode-session--permission-prompt-label
                 '((permission . "custom")))))
    (should (string-match-p "use custom" result))))

;;; question helpers

(ert-deftest test-opencode-handlers/question-list-vector ()
  "Normalize question vector."
  (should (equal (opencode-session--question-list [1 2]) '(1 2))))

(ert-deftest test-opencode-handlers/question-list-nil ()
  "Return nil for nil."
  (should (null (opencode-session--question-list nil))))

(ert-deftest test-opencode-handlers/question-options ()
  "Extract option labels."
  (should (equal (opencode-session--question-options
                  '((options . [((label . "Yes")) ((label . "No"))])))
                 '("Yes" "No"))))

(ert-deftest test-opencode-handlers/question-multiple-p-true ()
  "Detect multiple-answer questions."
  (should (opencode-session--question-multiple-p '((multiple . t)))))

(ert-deftest test-opencode-handlers/question-multiple-p-false ()
  "Non-multiple returns nil."
  (should (null (opencode-session--question-multiple-p '((multiple . nil))))))

(ert-deftest test-opencode-handlers/question-custom-p-true ()
  "Detect custom-answer questions."
  (should (opencode-session--question-custom-p '((custom . t)))))

(ert-deftest test-opencode-handlers/question-custom-p-false ()
  "Non-custom returns nil."
  (should (null (opencode-session--question-custom-p '((custom . :json-false))))))

(ert-deftest test-opencode-handlers/question-custom-p-nil ()
  "Nil custom returns nil."
  (should (null (opencode-session--question-custom-p '((custom . nil))))))

(ert-deftest test-opencode-handlers/question-prompt-label ()
  "Build question prompt."
  (should (equal (opencode-session--question-prompt-label
                  '((header . "Auth") (question . "Enter key")))
                 "OpenCode Auth: Enter key ")))

(ert-deftest test-opencode-handlers/question-prompt-label-no-header ()
  "Build question prompt without header."
  (should (equal (opencode-session--question-prompt-label
                  '((question . "Choose one")))
                 "OpenCode: Choose one ")))

;;; event-file-paths

(ert-deftest test-opencode-handlers/event-file-paths-vector ()
  "Extract paths from vector."
  (should (equal (opencode-session--event-file-paths
                  '((properties . ((paths . ["a.el" "b.el"])))))
                 '("a.el" "b.el"))))

(ert-deftest test-opencode-handlers/event-file-paths-list ()
  "Extract paths from list."
  (should (equal (opencode-session--event-file-paths
                  '((properties . ((paths . ("a.el" "b.el"))))))
                 '("a.el" "b.el"))))

(ert-deftest test-opencode-handlers/event-file-paths-nil ()
  "Return nil when no paths found."
  ;; Note: (listp nil) is t in Elisp, so when paths/files are absent
  ;; the function returns nil via the (listp paths) branch.
  (should (null (opencode-session--event-file-paths
                 '((properties . ((other . "x"))))))))

(provide 'emacs-opencode-session-handlers-test)

;;; emacs-opencode-session-handlers-test.el ends here
