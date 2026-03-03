;;; emacs-opencode-session-header-test.el --- Tests for session header  -*- lexical-binding: t; -*-

(require 'ert)
(require 'emacs-opencode-session-header)

;;; format-number

(ert-deftest test-opencode-header/format-number-small ()
  "Small numbers have no separator."
  (should (equal (opencode-session--format-number 42) "42")))

(ert-deftest test-opencode-header/format-number-zero ()
  "Zero formats correctly."
  (should (equal (opencode-session--format-number 0) "0")))

(ert-deftest test-opencode-header/format-number-thousands ()
  "Thousands get a comma."
  (should (equal (opencode-session--format-number 1234) "1,234")))

(ert-deftest test-opencode-header/format-number-millions ()
  "Millions get two commas."
  (should (equal (opencode-session--format-number 1234567) "1,234,567")))

(ert-deftest test-opencode-header/format-number-exact-thousand ()
  "Exact thousand."
  (should (equal (opencode-session--format-number 1000) "1,000")))

(ert-deftest test-opencode-header/format-number-negative ()
  "Negative numbers are clamped to zero."
  (should (equal (opencode-session--format-number -5) "0")))

(ert-deftest test-opencode-header/format-number-float ()
  "Floats are truncated."
  (should (equal (opencode-session--format-number 1234.56) "1,234")))

;;; safe-number

(ert-deftest test-opencode-header/safe-number-value ()
  "Return the number when it is a number."
  (should (= (opencode-session--safe-number 42) 42)))

(ert-deftest test-opencode-header/safe-number-nil ()
  "Return 0 for nil."
  (should (= (opencode-session--safe-number nil) 0)))

(ert-deftest test-opencode-header/safe-number-string ()
  "Return 0 for non-number."
  (should (= (opencode-session--safe-number "hello") 0)))

;;; tokens-total

(ert-deftest test-opencode-header/tokens-total ()
  "Sum all token counts."
  (let ((tokens '((input . 100) (output . 200) (reasoning . 50)
                  (cache . ((read . 30) (write . 20))))))
    (should (= (opencode-session--tokens-total tokens) 400))))

(ert-deftest test-opencode-header/tokens-total-partial ()
  "Handle missing token fields."
  (let ((tokens '((input . 100) (output . 200))))
    (should (= (opencode-session--tokens-total tokens) 300))))

(ert-deftest test-opencode-header/tokens-total-nil ()
  "Return 0 for nil tokens (nil is a list in Elisp)."
  (should (= (opencode-session--tokens-total nil) 0)))

;;; status-busy-p

(ert-deftest test-opencode-header/status-busy-p-idle ()
  "Idle is not busy."
  (should (null (opencode-session--status-busy-p "idle"))))

(ert-deftest test-opencode-header/status-busy-p-running ()
  "Running is busy."
  (should (opencode-session--status-busy-p "running")))

(ert-deftest test-opencode-header/status-busy-p-waiting ()
  "Waiting is busy."
  (should (opencode-session--status-busy-p "waiting")))

(provide 'emacs-opencode-session-header-test)

;;; emacs-opencode-session-header-test.el ends here
