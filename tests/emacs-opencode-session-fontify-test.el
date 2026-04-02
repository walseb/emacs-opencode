;;; emacs-opencode-session-fontify-test.el --- Tests for font-lock  -*- lexical-binding: t; -*-

(require 'ert)
(require 'emacs-opencode-session-fontify)

;;; regex constants

(ert-deftest test-opencode-fontify/regex-code-matches-backticks ()
  "Inline code regex matches backtick-delimited code."
  (with-temp-buffer
    (insert "hello `code` world")
    (goto-char (point-min))
    (should (re-search-forward opencode-session--regex-code nil t))
    (should (equal (match-string 3) "code"))))

(ert-deftest test-opencode-fontify/regex-bold-matches-asterisks ()
  "Bold regex matches **bold** text."
  (with-temp-buffer
    (insert "hello **bold** world")
    (goto-char (point-min))
    (should (re-search-forward opencode-session--regex-bold nil t))
    (should (equal (match-string 4) "bold"))))

(ert-deftest test-opencode-fontify/regex-italic-matches-single-asterisk ()
  "Italic regex matches *italic* text."
  (with-temp-buffer
    (insert "hello *italic* world")
    (goto-char (point-min))
    (should (re-search-forward opencode-session--regex-italic nil t))
    (should (equal (match-string 3) "italic"))))

;;; in-part-p

(ert-deftest test-opencode-fontify/in-part-p ()
  "Check text property for part type."
  (with-temp-buffer
    (insert (propertize "hello" 'opencode-part-type "user-text"))
    (should (opencode-session--in-part-p 1 "user-text"))
    (should-not (opencode-session--in-part-p 1 "tool"))))

(ert-deftest test-opencode-fontify/in-text-part-p ()
  "Check text property for user-text or assistant-text."
  (with-temp-buffer
    (insert (propertize "hello" 'opencode-part-type "assistant-text"))
    (should (opencode-session--in-text-part-p 1))
    (insert (propertize "tool" 'opencode-part-type "tool"))
    (should-not (opencode-session--in-text-part-p (+ 1 5)))))

;;; face-p

(ert-deftest test-opencode-fontify/face-p-single ()
  "Detect a single face."
  (with-temp-buffer
    (insert (propertize "hello" 'face 'bold))
    (should (opencode-session--face-p 1 '(bold)))))

(ert-deftest test-opencode-fontify/face-p-list ()
  "Detect a face in a list of faces."
  (with-temp-buffer
    (insert (propertize "hello" 'face '(bold italic)))
    (should (opencode-session--face-p 1 '(italic)))))

(ert-deftest test-opencode-fontify/face-p-no-match ()
  "Return nil when face doesn't match."
  (with-temp-buffer
    (insert (propertize "hello" 'face 'bold))
    (should-not (opencode-session--face-p 1 '(italic)))))

;;; collapse-symbol (tested in render tests but also used in fontify)

(ert-deftest test-opencode-fontify/block-separator-regex ()
  "Block separator matches blank lines."
  (with-temp-buffer
    (insert "line1\n\nline2")
    (goto-char (point-min))
    (should (re-search-forward opencode-session--regex-block-separator nil t))))

;;; table fontification

(ert-deftest test-opencode-fontify/table-separator-line-p ()
  "Detect table separator lines."
  (should (opencode-session--table-separator-line-p "|---|---|"))
  (should (opencode-session--table-separator-line-p "| --- | --- |"))
  (should (opencode-session--table-separator-line-p "|:---|---:|"))
  (should-not (opencode-session--table-separator-line-p "| a | b |"))
  (should-not (opencode-session--table-separator-line-p "not a table")))

(ert-deftest test-opencode-fontify/table-faces-exist ()
  "Table faces are defined."
  (should (facep 'opencode-markdown-table-delimiter-face))
  (should (facep 'opencode-markdown-table-separator-face))
  (should (facep 'opencode-markdown-table-header-face)))

(provide 'emacs-opencode-session-fontify-test)

;;; emacs-opencode-session-fontify-test.el ends here
