;;; emacs-opencode-run-test.el --- Tests for opencode run wrapper  -*- lexical-binding: t; -*-

(require 'ert)
(require 'emacs-opencode-run)

;;; build-args

(ert-deftest test-opencode-run/build-args-bare ()
  "A bare prompt produces just the run subcommand and prompt."
  (should (equal (opencode-run--build-args "the prompt")
                 '("run" "the prompt"))))

(ert-deftest test-opencode-run/build-args-model ()
  "The :model keyword adds a --model flag."
  (should (equal (opencode-run--build-args "the prompt" :model "anthropic/foo")
                 '("run" "--model" "anthropic/foo" "the prompt"))))

(ert-deftest test-opencode-run/build-args-agent ()
  "The :agent keyword adds an --agent flag."
  (should (equal (opencode-run--build-args "the prompt" :agent "build")
                 '("run" "--agent" "build" "the prompt"))))

(ert-deftest test-opencode-run/build-args-command ()
  "The :command keyword adds a --command flag."
  (should (equal (opencode-run--build-args "the prompt" :command "review")
                 '("run" "--command" "review" "the prompt"))))

(ert-deftest test-opencode-run/build-args-skip-permissions ()
  "The :dangerously-skip-permissions keyword adds a valueless flag."
  (should (equal (opencode-run--build-args
                  "the prompt" :dangerously-skip-permissions t)
                 '("run" "--dangerously-skip-permissions" "the prompt"))))

(ert-deftest test-opencode-run/build-args-skip-permissions-nil ()
  "A nil :dangerously-skip-permissions omits the flag."
  (should (equal (opencode-run--build-args
                  "the prompt" :dangerously-skip-permissions nil)
                 '("run" "the prompt"))))

(ert-deftest test-opencode-run/build-args-nil-flags-omitted ()
  "Keyword flags with nil values are omitted."
  (should (equal (opencode-run--build-args "the prompt" :model nil :agent nil)
                 '("run" "the prompt"))))

(ert-deftest test-opencode-run/build-args-all-flags ()
  "All flags combine in a stable order before the prompt."
  (should (equal (opencode-run--build-args
                  "the prompt"
                  :model "anthropic/foo"
                  :agent "build"
                  :command "review"
                  :dangerously-skip-permissions t)
                 '("run"
                   "--model" "anthropic/foo"
                   "--agent" "build"
                   "--command" "review"
                   "--dangerously-skip-permissions"
                   "the prompt"))))

;;; invoke-callback

(ert-deftest test-opencode-run/invoke-callback-one-arg ()
  "A single-argument callback receives only the output."
  (let ((received :none))
    (opencode-run--invoke-callback
     (lambda (output) (setq received output))
     "the output" t)
    (should (equal received "the output"))))

(ert-deftest test-opencode-run/invoke-callback-two-args ()
  "A two-argument callback receives output and success-p."
  (let ((received :none))
    (opencode-run--invoke-callback
     (lambda (output success-p) (setq received (list output success-p)))
     "the output" t)
    (should (equal received '("the output" t)))))

(ert-deftest test-opencode-run/invoke-callback-rest-args ()
  "A &rest callback receives output and success-p."
  (let ((received :none))
    (opencode-run--invoke-callback
     (lambda (&rest args) (setq received args))
     "the output" nil)
    (should (equal received '("the output" nil)))))

(ert-deftest test-opencode-run/invoke-callback-optional-second ()
  "A callback with an optional second arg receives both values."
  (let ((received :none))
    (opencode-run--invoke-callback
     (lambda (output &optional success-p) (setq received (list output success-p)))
     "the output" t)
    (should (equal received '("the output" t)))))

(ert-deftest test-opencode-run/invoke-callback-nil ()
  "A nil callback is a no-op."
  (should-not (opencode-run--invoke-callback nil "the output" t)))

(ert-deftest test-opencode-run/invoke-callback-trims-trailing ()
  "Trailing whitespace and newlines are stripped from the output."
  (let ((received :none))
    (opencode-run--invoke-callback
     (lambda (output) (setq received output))
     "the output\n\n  " t)
    (should (equal received "the output"))))

(ert-deftest test-opencode-run/invoke-callback-trims-nil-output ()
  "A nil output is passed through without error."
  (let ((received :none))
    (opencode-run--invoke-callback
     (lambda (output) (setq received output))
     nil t)
    (should (null received))))

(provide 'emacs-opencode-run-test)

;;; emacs-opencode-run-test.el ends here
