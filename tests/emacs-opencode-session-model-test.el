;;; emacs-opencode-session-model-test.el --- Tests for model selection  -*- lexical-binding: t; -*-

(require 'ert)
(require 'emacs-opencode-session-model)

;;; normalize-agents

(ert-deftest test-opencode-model/normalize-agents-strings ()
  "Normalize a list of string agents."
  (should (equal (opencode-session--normalize-agents '("plan" "code"))
                 '("plan" "code"))))

(ert-deftest test-opencode-model/normalize-agents-vector ()
  "Normalize a vector of agents."
  (should (equal (opencode-session--normalize-agents ["plan" "code"])
                 '("plan" "code"))))

(ert-deftest test-opencode-model/normalize-agents-alists ()
  "Normalize alist agents with mode and hidden."
  (let ((data '(((id . "plan") (mode . "primary") (hidden . nil))
                ((id . "code") (mode . "primary") (hidden . nil))
                ((id . "hidden") (mode . "primary") (hidden . t))
                ((id . "secondary") (mode . "secondary") (hidden . nil)))))
    (let ((result (opencode-session--normalize-agents data)))
      (should (member "plan" result))
      (should (member "code" result))
      (should-not (member "hidden" result))
      (should-not (member "secondary" result)))))

(ert-deftest test-opencode-model/normalize-agents-nil ()
  "Return nil for nil."
  (should (null (opencode-session--normalize-agents nil))))

(ert-deftest test-opencode-model/normalize-agents-uses-name-fallback ()
  "Fall back to name when id is absent."
  (let ((data '(((name . "plan") (mode . "primary")))))
    (should (equal (opencode-session--normalize-agents data) '("plan")))))

;;; variant-keys

(ert-deftest test-opencode-model/variant-keys-alist ()
  "Extract variant names from alist."
  (let ((result (opencode-session--variant-keys
                 '((fast . nil)
                   (slow . nil)
                   (disabled . ((disabled . t)))))))
    (should (member "fast" result))
    (should (member "slow" result))
    (should-not (member "disabled" result))))

(ert-deftest test-opencode-model/variant-keys-hash-table ()
  "Extract variant names from hash table."
  (let ((ht (make-hash-table :test 'equal)))
    (puthash "fast" nil ht)
    (puthash "slow" nil ht)
    (puthash "off" '((disabled . t)) ht)
    (let ((result (opencode-session--variant-keys ht)))
      (should (member "fast" result))
      (should (member "slow" result))
      (should-not (member "off" result)))))

(ert-deftest test-opencode-model/variant-keys-sorted ()
  "Variant keys are sorted alphabetically."
  (let ((result (opencode-session--variant-keys
                 '((zebra . nil) (alpha . nil) (middle . nil)))))
    (should (equal result '("alpha" "middle" "zebra")))))

(ert-deftest test-opencode-model/variant-keys-nil ()
  "Return nil for nil."
  (should (null (opencode-session--variant-keys nil))))

(ert-deftest test-opencode-model/variant-keys-symbol-keys ()
  "Handle symbol keys in alist."
  (let ((result (opencode-session--variant-keys
                 '((fast . nil) (slow . nil)))))
    (should (member "fast" result))
    (should (member "slow" result))))

;;; model-candidate-tier

(ert-deftest test-opencode-model/candidate-tier-recent ()
  "Recently selected models are tier 0."
  (let ((candidate (list :provider-id "anthropic" :model-id "claude-3" :connected-p nil)))
    (should (= (opencode-session--model-candidate-tier
                candidate
                '(("anthropic" . "claude-3"))
                nil)
               0))))

(ert-deftest test-opencode-model/candidate-tier-session ()
  "Session-used models are tier 1."
  (let ((candidate (list :provider-id "openai" :model-id "gpt-4" :connected-p nil)))
    (should (= (opencode-session--model-candidate-tier
                candidate
                nil
                '(("openai" . "gpt-4")))
               1))))

(ert-deftest test-opencode-model/candidate-tier-connected ()
  "Connected models are tier 2."
  (let ((candidate (list :provider-id "openai" :model-id "gpt-4" :connected-p t)))
    (should (= (opencode-session--model-candidate-tier candidate nil nil)
               2))))

(ert-deftest test-opencode-model/candidate-tier-other ()
  "Other models are tier 3."
  (let ((candidate (list :provider-id "openai" :model-id "gpt-4" :connected-p nil)))
    (should (= (opencode-session--model-candidate-tier candidate nil nil)
               3))))

;;; model-candidate-rank

(ert-deftest test-opencode-model/candidate-rank-in-list ()
  "Rank from position in ordered list."
  (let ((candidate (list :provider-id "b" :model-id "2"))
        (ranked '(("a" . "1") ("b" . "2") ("c" . "3"))))
    (should (= (opencode-session--model-candidate-rank candidate 0 ranked) 1))))

(ert-deftest test-opencode-model/candidate-rank-not-in-list ()
  "Default rank 0 when not in list."
  (let ((candidate (list :provider-id "x" :model-id "y")))
    (should (= (opencode-session--model-candidate-rank candidate 0 nil) 0))))

(ert-deftest test-opencode-model/candidate-rank-high-tier ()
  "Tier > 1 always returns rank 0."
  (let ((candidate (list :provider-id "x" :model-id "y")))
    (should (= (opencode-session--model-candidate-rank candidate 2 nil) 0))))

;;; provider-model-items

(ert-deftest test-opencode-model/provider-model-items-list ()
  "Extract model items from a list."
  (let ((provider '((id . "anthropic")
                    (models . (("claude-3" . ((name . "Claude 3")))
                               ("claude-2" . ((name . "Claude 2"))))))))
    (let ((items (opencode-session--provider-model-items provider)))
      (should (= (length items) 2))
      (should (equal (caar items) "claude-3")))))

(ert-deftest test-opencode-model/provider-model-items-hash-table ()
  "Extract model items from a hash table."
  (let ((ht (make-hash-table :test 'equal)))
    (puthash "claude-3" '((name . "Claude 3")) ht)
    (let ((provider `((id . "anthropic") (models . ,ht))))
      (let ((items (opencode-session--provider-model-items provider)))
        (should (= (length items) 1))
        (should (equal (caar items) "claude-3"))))))

(ert-deftest test-opencode-model/provider-model-items-nil ()
  "Return nil for nil models."
  (should (null (opencode-session--provider-model-items '((id . "x"))))))

;;; provider-model-candidate-display

(ert-deftest test-opencode-model/candidate-display-connected ()
  "Display connected indicator."
  (should (equal (opencode-session--provider-model-candidate-display
                  "anthropic" "claude-3" t)
                 "anthropic/claude-3 (connected)")))

(ert-deftest test-opencode-model/candidate-display-not-connected ()
  "Display without connected indicator."
  (should (equal (opencode-session--provider-model-candidate-display
                  "anthropic" "claude-3" nil)
                 "anthropic/claude-3")))

;;; provider-auth-methods

(ert-deftest test-opencode-model/provider-auth-methods ()
  "Extract auth methods for a provider."
  (let ((data `((anthropic . [((type . "api") (label . "API key"))]))))
    (let ((result (opencode-session--provider-auth-methods "anthropic" data)))
      (should (= (length result) 1))
      (should (equal (alist-get 'type (car result)) "api")))))

(ert-deftest test-opencode-model/provider-auth-methods-fallback ()
  "Fall back to API key when provider not found."
  (let ((result (opencode-session--provider-auth-methods "unknown" nil)))
    (should (= (length result) 1))
    (should (equal (alist-get 'type (car result)) "api"))))

(provide 'emacs-opencode-session-model-test)

;;; emacs-opencode-session-model-test.el ends here
