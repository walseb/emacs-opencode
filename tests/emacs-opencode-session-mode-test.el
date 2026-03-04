;;; emacs-opencode-session-mode-test.el --- Tests for session mode  -*- lexical-binding: t; -*-

(require 'ert)
(require 'emacs-opencode-session-mode)

;;; parse-command-input

(ert-deftest test-opencode-session-mode/parse-command-basic ()
  "Parse a basic slash command."
  (let ((result (opencode-session--parse-command-input "/help")))
    (should (equal (car result) "help"))
    (should (equal (cadr result) ""))))

(ert-deftest test-opencode-session-mode/parse-command-with-args ()
  "Parse a slash command with arguments."
  (let ((result (opencode-session--parse-command-input "/search hello world")))
    (should (equal (car result) "search"))
    (should (equal (cadr result) "hello world"))))

(ert-deftest test-opencode-session-mode/parse-command-not-a-command ()
  "Return nil command for non-slash input."
  (let ((result (opencode-session--parse-command-input "regular text")))
    (should (null (car result)))
    (should (equal (cadr result) ""))))

(ert-deftest test-opencode-session-mode/parse-command-empty ()
  "Handle empty input."
  (let ((result (opencode-session--parse-command-input "")))
    (should (null (car result)))))

(ert-deftest test-opencode-session-mode/parse-command-slash-only ()
  "A bare slash is not a valid command."
  (let ((result (opencode-session--parse-command-input "/")))
    (should (null (car result)))))

;;; buffer-name

(ert-deftest test-opencode-session-mode/buffer-name-with-title ()
  "Buffer name includes session title."
  (let ((session (opencode-session-create :title "My Session")))
    (should (equal (opencode-session--buffer-name session)
                   "*OpenCode: My Session*"))))

(ert-deftest test-opencode-session-mode/buffer-name-fallback-slug ()
  "Fall back to slug when title is empty."
  (let ((session (opencode-session-create :slug "my-slug")))
    (should (equal (opencode-session--buffer-name session)
                   "*OpenCode: my-slug*"))))

(ert-deftest test-opencode-session-mode/buffer-name-fallback-id ()
  "Fall back to ID when title and slug are empty."
  (let ((session (opencode-session-create :id "abc123")))
    (should (equal (opencode-session--buffer-name session)
                   "*OpenCode: abc123*"))))

(ert-deftest test-opencode-session-mode/buffer-name-fallback-default ()
  "Fall back to 'session' when everything is nil."
  (let ((session (opencode-session-create)))
    (should (equal (opencode-session--buffer-name session)
                   "*OpenCode: session*"))))

(ert-deftest test-opencode-session-mode/buffer-name-trims-whitespace ()
  "Trim whitespace from title."
  (let ((session (opencode-session-create :title "  ")))
    ;; Empty after trim, should fall back
    (should (equal (opencode-session--buffer-name session)
                   "*OpenCode: session*"))))

;;; message-from-info

(ert-deftest test-opencode-session-mode/message-from-info ()
  "Create a message from an info alist."
  (let ((msg (opencode-session--message-from-info
              '((id . "m1")
                (sessionID . "s1")
                (role . "assistant")
                (providerID . "anthropic")
                (modelID . "claude-3")
                (time . ((created . "2024-01-01")))))))
    (should (opencode-message-p msg))
    (should (equal (opencode-message-id msg) "m1"))
    (should (equal (opencode-message-role msg) "assistant"))
    (should (equal (opencode-message-provider-id msg) "anthropic"))
    (should (equal (opencode-message-model-id msg) "claude-3"))))

(ert-deftest test-opencode-session-mode/message-from-info-nil ()
  "Return nil for nil info."
  (should (null (opencode-session--message-from-info nil))))

;;; message-part-from-info

(ert-deftest test-opencode-session-mode/message-part-from-info ()
  "Create a message part from an info alist."
  (let ((part (opencode-session--message-part-from-info
               '((id . "p1")
                 (sessionID . "s1")
                 (messageID . "m1")
                 (type . "text")
                 (text . "hello")
                 (tool . "bash")
                 (time . ((start . "2024-01-01") (end . "2024-01-02")))))))
    (should (opencode-message-part-p part))
    (should (equal (opencode-message-part-id part) "p1"))
    (should (equal (opencode-message-part-type part) "text"))
    (should (equal (opencode-message-part-text part) "hello"))
    (should (equal (opencode-message-part-tool part) "bash"))
    (should (equal (opencode-message-part-time-start part) "2024-01-01"))))

;;; command-items

(ert-deftest test-opencode-session-mode/command-items-vector ()
  "Normalize command vector to list."
  (should (equal (opencode-session--command-items [1 2]) '(1 2))))

(ert-deftest test-opencode-session-mode/command-items-list ()
  "Pass list through."
  (should (equal (opencode-session--command-items '(1 2)) '(1 2))))

(ert-deftest test-opencode-session-mode/command-items-nil ()
  "Return nil for nil."
  (should (null (opencode-session--command-items nil))))

;;; command-names

(ert-deftest test-opencode-session-mode/command-names ()
  "Extract command names from items."
  (should (equal (opencode-session--command-names
                  '(((name . "help") (description . "Show help"))
                    ((name . "clear") (description . "Clear"))))
                 '("help" "clear"))))

(ert-deftest test-opencode-session-mode/command-names-filters-non-lists ()
  "Filter out non-list items (delq removes nils)."
  (should (equal (opencode-session--command-names '("not-an-alist" ((name . "ok"))))
                 '("ok"))))

;;; hydrate-parts

(ert-deftest test-opencode-session-mode/hydrate-parts ()
  "Hydrate raw parts into an alist of part structs."
  (let ((result (opencode-session--hydrate-parts
                 '(((id . "p1") (type . "text") (text . "hello"))
                   ((id . "p2") (type . "tool") (tool . "bash"))))))
    (should (= (length result) 2))
    (should (equal (car (car result)) "p1"))
    (should (opencode-message-part-p (cdr (car result))))
    (should (equal (opencode-message-part-type (cdr (car result))) "text"))))

;;; classify-input

(ert-deftest test-opencode-session-mode/classify-input-message ()
  "Regular text is classified as a message."
  (let ((result (opencode-session--classify-input "hello world")))
    (should (eq (car result) 'message))
    (should (equal (cdr result) "hello world"))))

(ert-deftest test-opencode-session-mode/classify-input-command ()
  "Slash-prefixed text is classified as a command."
  (let ((result (opencode-session--classify-input "/help")))
    (should (eq (car result) 'command))
    (should (equal (cdr result) "/help"))))

(ert-deftest test-opencode-session-mode/classify-input-shell ()
  "Bang-prefixed text is classified as shell with prefix stripped."
  (let ((result (opencode-session--classify-input "!ls -la")))
    (should (eq (car result) 'shell))
    (should (equal (cdr result) "ls -la"))))

(ert-deftest test-opencode-session-mode/classify-input-shell-strips-only-bang ()
  "Only the leading ! is stripped from shell input."
  (let ((result (opencode-session--classify-input "!echo '!hello'")))
    (should (eq (car result) 'shell))
    (should (equal (cdr result) "echo '!hello'"))))

(ert-deftest test-opencode-session-mode/classify-input-shell-bare-bang ()
  "A bare ! is classified as shell with empty payload."
  (let ((result (opencode-session--classify-input "!")))
    (should (eq (car result) 'shell))
    (should (equal (cdr result) ""))))

(ert-deftest test-opencode-session-mode/classify-input-slash-priority ()
  "Slash takes priority when input starts with /."
  (let ((result (opencode-session--classify-input "/!mixed")))
    (should (eq (car result) 'command))))

(ert-deftest test-opencode-session-mode/classify-input-bang-not-at-start ()
  "A ! not at the start is treated as a regular message."
  (let ((result (opencode-session--classify-input "hello !world")))
    (should (eq (car result) 'message))
    (should (equal (cdr result) "hello !world"))))

;;; extract-agent-mentions

(ert-deftest test-opencode-session-mode/extract-mentions-single ()
  "Extract a single @-mention."
  (let ((opencode-session--connection
         (opencode-connection-create :agents-raw
          '(((id . "explore") (mode . "subagent") (hidden . nil))
            ((id . "general") (mode . "subagent") (hidden . nil))))))
    (should (equal (opencode-session--extract-agent-mentions "hello @explore")
                   '("explore")))))

(ert-deftest test-opencode-session-mode/extract-mentions-multiple ()
  "Extract multiple @-mentions."
  (let ((opencode-session--connection
         (opencode-connection-create :agents-raw
          '(((id . "explore") (mode . "subagent") (hidden . nil))
            ((id . "general") (mode . "subagent") (hidden . nil))))))
    (should (equal (opencode-session--extract-agent-mentions
                    "@explore do this @general do that")
                   '("explore" "general")))))

(ert-deftest test-opencode-session-mode/extract-mentions-dedup ()
  "Duplicate mentions are deduplicated."
  (let ((opencode-session--connection
         (opencode-connection-create :agents-raw
          '(((id . "explore") (mode . "subagent") (hidden . nil))))))
    (should (equal (opencode-session--extract-agent-mentions
                    "@explore and @explore again")
                   '("explore")))))

(ert-deftest test-opencode-session-mode/extract-mentions-unknown-agent ()
  "Unknown agent names are not extracted."
  (let ((opencode-session--connection
         (opencode-connection-create :agents-raw
          '(((id . "explore") (mode . "subagent") (hidden . nil))))))
    (should (null (opencode-session--extract-agent-mentions "hello @unknown")))))

(ert-deftest test-opencode-session-mode/extract-mentions-no-at ()
  "Input without @ returns empty list."
  (let ((opencode-session--connection
         (opencode-connection-create :agents-raw
          '(((id . "explore") (mode . "subagent") (hidden . nil))))))
    (should (null (opencode-session--extract-agent-mentions "hello world")))))

(ert-deftest test-opencode-session-mode/extract-mentions-at-start ()
  "Mention at the start of input is extracted."
  (let ((opencode-session--connection
         (opencode-connection-create :agents-raw
          '(((id . "explore") (mode . "subagent") (hidden . nil))))))
    (should (equal (opencode-session--extract-agent-mentions "@explore find files")
                   '("explore")))))

(ert-deftest test-opencode-session-mode/extract-mentions-mid-word ()
  "@ embedded in a word (no preceding whitespace) is not extracted."
  (let ((opencode-session--connection
         (opencode-connection-create :agents-raw
          '(((id . "explore") (mode . "subagent") (hidden . nil))))))
    (should (null (opencode-session--extract-agent-mentions "email@explore")))))

;;; build-message-parts

(ert-deftest test-opencode-session-mode/build-parts-text-only ()
  "Build parts with no mentions."
  (let ((opencode-session--connection
         (opencode-connection-create :agents-raw
          '(((id . "explore") (mode . "subagent") (hidden . nil))))))
    (let ((parts (opencode-session--build-message-parts "hello world")))
      (should (= (length parts) 1))
      (should (equal (cdr (assoc "type" (car parts))) "text"))
      (should (equal (cdr (assoc "text" (car parts))) "hello world")))))

(ert-deftest test-opencode-session-mode/build-parts-with-mention ()
  "Build parts with an @-mention."
  (let ((opencode-session--connection
         (opencode-connection-create :agents-raw
          '(((id . "explore") (mode . "subagent") (hidden . nil))))))
    (let ((parts (opencode-session--build-message-parts "hello @explore")))
      (should (= (length parts) 2))
      (should (equal (cdr (assoc "type" (car parts))) "text"))
      (should (equal (cdr (assoc "type" (cadr parts))) "agent"))
      (should (equal (cdr (assoc "name" (cadr parts))) "explore")))))

;;; agent-completion-bounds

(ert-deftest test-opencode-session-mode/agent-bounds-at-trigger ()
  "Detect @ at the start of input."
  (with-temp-buffer
    (opencode-session-mode)
    (opencode-session--ensure-markers)
    (opencode-session--ensure-input-region)
    (goto-char (marker-position opencode-session--input-marker))
    (insert "@expl")
    (let ((bounds (opencode-session--agent-completion-bounds)))
      (should bounds)
      (should (= (car bounds)
                 (1+ (marker-position opencode-session--input-start-marker))))
      (should (= (cdr bounds) (point))))))

(ert-deftest test-opencode-session-mode/agent-bounds-after-space ()
  "Detect @ after a space in input."
  (with-temp-buffer
    (opencode-session-mode)
    (opencode-session--ensure-markers)
    (opencode-session--ensure-input-region)
    (goto-char (marker-position opencode-session--input-marker))
    (insert "hello @expl")
    (let ((bounds (opencode-session--agent-completion-bounds)))
      (should bounds))))

(ert-deftest test-opencode-session-mode/agent-bounds-no-trigger ()
  "Return nil when no @ is present."
  (with-temp-buffer
    (opencode-session-mode)
    (opencode-session--ensure-markers)
    (opencode-session--ensure-input-region)
    (goto-char (marker-position opencode-session--input-marker))
    (insert "hello world")
    (should (null (opencode-session--agent-completion-bounds)))))

(ert-deftest test-opencode-session-mode/agent-bounds-mid-word ()
  "Return nil when @ is not preceded by whitespace."
  (with-temp-buffer
    (opencode-session-mode)
    (opencode-session--ensure-markers)
    (opencode-session--ensure-input-region)
    (goto-char (marker-position opencode-session--input-marker))
    (insert "email@expl")
    (should (null (opencode-session--agent-completion-bounds)))))

(provide 'emacs-opencode-session-mode-test)

;;; emacs-opencode-session-mode-test.el ends here
