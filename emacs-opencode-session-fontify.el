;;; emacs-opencode-session-fontify.el --- Font-lock for session buffers  -*- lexical-binding: t; -*-

;;; Commentary:

;; Font-lock keywords and faces for OpenCode session buffers.
;; Provides markdown fontification for human/AI text parts and diff
;; fontification for edit/patch tool output.  Face definitions are
;; modeled after `markdown-mode' for visual consistency.

;;; Code:

(require 'cl-lib)
(require 'diff-mode)

;;; Markdown faces
;;
;; When `markdown-mode' is loaded, faces inherit from the corresponding
;; markdown-mode face so that theme customizations carry over.  Otherwise
;; the fallback matches markdown-mode's own defaults.

(defface opencode-markdown-markup-face
  `((t :inherit ,(if (facep 'markdown-markup-face)
                     'markdown-markup-face
                   '(shadow :slant normal :weight normal))))
  "Face for markdown markup elements such as delimiters."
  :group 'emacs-opencode)

(defface opencode-markdown-header-face
  `((t :inherit ,(if (facep 'markdown-header-face)
                     'markdown-header-face
                   '(font-lock-function-name-face bold))))
  "Base face for markdown headings."
  :group 'emacs-opencode)

(defface opencode-markdown-header-1-face
  `((t :inherit ,(if (facep 'markdown-header-face-1)
                     'markdown-header-face-1
                   'opencode-markdown-header-face)))
  "Face for markdown level-1 headings."
  :group 'emacs-opencode)

(defface opencode-markdown-header-2-face
  `((t :inherit ,(if (facep 'markdown-header-face-2)
                     'markdown-header-face-2
                   'opencode-markdown-header-face)))
  "Face for markdown level-2 headings."
  :group 'emacs-opencode)

(defface opencode-markdown-header-3-face
  `((t :inherit ,(if (facep 'markdown-header-face-3)
                     'markdown-header-face-3
                   'opencode-markdown-header-face)))
  "Face for markdown level-3 headings."
  :group 'emacs-opencode)

(defface opencode-markdown-header-4-face
  `((t :inherit ,(if (facep 'markdown-header-face-4)
                     'markdown-header-face-4
                   'opencode-markdown-header-face)))
  "Face for markdown level-4+ headings."
  :group 'emacs-opencode)

(defface opencode-markdown-header-delimiter-face
  `((t :inherit ,(if (facep 'markdown-header-delimiter-face)
                     'markdown-header-delimiter-face
                   'opencode-markdown-markup-face)))
  "Face for markdown header delimiters."
  :group 'emacs-opencode)

(defface opencode-markdown-bold-face
  `((t :inherit ,(if (facep 'markdown-bold-face)
                     'markdown-bold-face
                   'bold)))
  "Face for markdown bold text."
  :group 'emacs-opencode)

(defface opencode-markdown-italic-face
  `((t :inherit ,(if (facep 'markdown-italic-face)
                     'markdown-italic-face
                   'italic)))
  "Face for markdown italic text."
  :group 'emacs-opencode)

(defface opencode-markdown-code-face
  `((t :inherit ,(if (facep 'markdown-inline-code-face)
                     'markdown-inline-code-face
                   '(fixed-pitch font-lock-constant-face))))
  "Face for markdown inline code."
  :group 'emacs-opencode)

(defface opencode-markdown-code-block-face
  `((t :inherit ,(if (facep 'markdown-code-face)
                     'markdown-code-face
                   '(fixed-pitch font-lock-constant-face))
       :extend t))
  "Face for markdown fenced code block content."
  :group 'emacs-opencode)

(defface opencode-markdown-code-block-delimiter-face
  `((t :inherit ,(if (facep 'markdown-markup-face)
                     'markdown-markup-face
                   '(shadow :slant normal :weight normal))
       :extend t))
  "Face for markdown fenced code block delimiters."
  :group 'emacs-opencode)

(defface opencode-markdown-language-face
  `((t :inherit ,(if (facep 'markdown-language-keyword-face)
                     'markdown-language-keyword-face
                   'font-lock-type-face)))
  "Face for language identifiers on fenced code block delimiters."
  :group 'emacs-opencode)

(defface opencode-markdown-blockquote-face
  `((t :inherit ,(if (facep 'markdown-blockquote-face)
                     'markdown-blockquote-face
                   'font-lock-doc-face)))
  "Face for markdown blockquotes."
  :group 'emacs-opencode)

(defface opencode-markdown-link-face
  `((t :inherit ,(if (facep 'markdown-link-face)
                     'markdown-link-face
                   'link)))
  "Face for markdown link text."
  :group 'emacs-opencode)

(defface opencode-markdown-link-url-face
  `((t :inherit ,(if (facep 'markdown-url-face)
                     'markdown-url-face
                   'font-lock-string-face)))
  "Face for markdown link URLs."
  :group 'emacs-opencode)

(defface opencode-markdown-list-bullet-face
  `((t :inherit ,(if (facep 'markdown-list-face)
                     'markdown-list-face
                   'opencode-markdown-markup-face)))
  "Face for markdown list bullets and ordered markers."
  :group 'emacs-opencode)

(defface opencode-markdown-hr-face
  `((t :inherit ,(if (facep 'markdown-hr-face)
                     'markdown-hr-face
                   'opencode-markdown-markup-face)))
  "Face for markdown horizontal rules."
  :group 'emacs-opencode)

;;; Font-lock matcher helpers

(defun opencode-session--in-part-p (pos &rest types)
  "Return non-nil when POS has an `opencode-part-type' matching one of TYPES."
  (member (get-text-property pos 'opencode-part-type) types))

(defun opencode-session--make-text-matcher (regexp)
  "Return a font-lock matcher for REGEXP in text part regions.
The matcher searches forward for REGEXP but only succeeds when the
match lies inside a region with `opencode-part-type' of
\"user-text\" or \"assistant-text\"."
  (lambda (limit)
    (let (found)
      (while (and (not found) (re-search-forward regexp limit t))
        (when (opencode-session--in-part-p (match-beginning 0)
                                           "user-text" "assistant-text")
          (setq found t)))
      found)))

(defun opencode-session--make-diff-matcher (regexp)
  "Return a font-lock matcher for REGEXP in diff part regions.
The matcher searches forward for REGEXP but only succeeds when the
match lies inside a region with `opencode-part-type' of \"diff\"."
  (lambda (limit)
    (let (found)
      (while (and (not found) (re-search-forward regexp limit t))
        (when (opencode-session--in-part-p (match-beginning 0) "diff")
          (setq found t)))
      found)))

;;; Base face matchers

(defun opencode-session--match-part-type (type limit)
  "Match the next contiguous run of `opencode-part-type' TYPE before LIMIT.
Sets `match-data' group 0 to the matched region."
  (let (found start end)
    (while (and (not found) (< (point) limit))
      (let ((ptype (get-text-property (point) 'opencode-part-type)))
        (if (equal ptype type)
            (progn
              (setq start (point))
              (setq end (or (next-single-property-change (point) 'opencode-part-type nil limit)
                            limit))
              (set-match-data (list start end))
              (goto-char end)
              (setq found t))
          (goto-char (or (next-single-property-change (point) 'opencode-part-type nil limit)
                         limit)))))
    found))

(defun opencode-session--match-user-text (limit)
  "Font-lock matcher for user text regions up to LIMIT."
  (opencode-session--match-part-type "user-text" limit))

(defun opencode-session--match-assistant-text (limit)
  "Font-lock matcher for assistant text regions up to LIMIT."
  (opencode-session--match-part-type "assistant-text" limit))

(defun opencode-session--match-tool-text (limit)
  "Font-lock matcher for tool output regions up to LIMIT."
  (opencode-session--match-part-type "tool" limit))

(defun opencode-session--match-reasoning-text (limit)
  "Font-lock matcher for reasoning/thinking regions up to LIMIT."
  (opencode-session--match-part-type "reasoning" limit))

(defvar opencode-session--base-font-lock-keywords
  `((opencode-session--match-user-text
     (0 'opencode-session-user-face))
    (opencode-session--match-assistant-text
     (0 'opencode-session-assistant-face))
    (opencode-session--match-tool-text
     (0 'opencode-session-tool-face))
    (opencode-session--match-reasoning-text
     (0 'opencode-session-reasoning-face)))
  "Font-lock keywords that set the base face for tagged regions.")

;;; Markdown font-lock keywords

(defvar opencode-session--markdown-font-lock-keywords
  `(;; Horizontal rules: ---, ***, ___ (3+ chars, alone on a line)
    (,(opencode-session--make-text-matcher
       "^[[:blank:]]*\\([-*_]\\{3,\\}\\)[[:blank:]]*$")
     (1 'opencode-markdown-hr-face t))

    ;; ATX headers: # through ######
    ;; Delimiter (#) gets markup face, text gets header face
    (,(opencode-session--make-text-matcher "^\\(#\\) \\(.+\\)$")
     (1 'opencode-markdown-header-delimiter-face t)
     (2 'opencode-markdown-header-1-face t))
    (,(opencode-session--make-text-matcher "^\\(##\\) \\(.+\\)$")
     (1 'opencode-markdown-header-delimiter-face t)
     (2 'opencode-markdown-header-2-face t))
    (,(opencode-session--make-text-matcher "^\\(###\\) \\(.+\\)$")
     (1 'opencode-markdown-header-delimiter-face t)
     (2 'opencode-markdown-header-3-face t))
    (,(opencode-session--make-text-matcher "^\\(####+ \\)\\(.+\\)$")
     (1 'opencode-markdown-header-delimiter-face t)
     (2 'opencode-markdown-header-4-face t))

    ;; Fenced code blocks: ```...``` (multi-line via function matcher)
    (opencode-session--fontify-code-blocks)

    ;; Blockquotes: > text — marker gets markup face, text gets blockquote
    (,(opencode-session--make-text-matcher "^\\(>[[:blank:]]?\\)\\(.*\\)$")
     (1 'opencode-markdown-markup-face t)
     (2 'opencode-markdown-blockquote-face t))

    ;; Unordered list bullets: - , * , +
    (,(opencode-session--make-text-matcher
       "^\\([[:blank:]]*[-*+]\\)[[:blank:]]")
     (1 'opencode-markdown-list-bullet-face t))

    ;; Ordered list markers: 1. , 2. , etc.
    (,(opencode-session--make-text-matcher
       "^\\([[:blank:]]*[0-9]+\\.\\)[[:blank:]]")
     (1 'opencode-markdown-list-bullet-face t))

    ;; Bold: **text** — delimiters get markup face, content gets bold
    ;; Content must not span newlines; must not be space-adjacent to delimiters.
    (,(opencode-session--make-text-matcher
       "\\(?:^\\|[^\\\\*_]\\)\\(\\*\\*\\)\\([^* \n][^*\n]*?[^\\\\* \n]\\|[^* \n]\\)\\(\\*\\*\\)")
     (1 'opencode-markdown-markup-face t)
     (2 'opencode-markdown-bold-face t)
     (3 'opencode-markdown-markup-face t))
    ;; __text__ requires word boundaries: opening _ not after alnum,
    ;; closing _ not before alnum (matches CommonMark spec for _ delimiters).
    (,(opencode-session--make-text-matcher
       "\\(?:^\\|[^\\\\*_[:alnum:]]\\)\\(__\\)\\([^_ \n][^_\n]*?[^\\\\_  \n]\\|[^_ \n]\\)\\(__\\)\\(?:[^_[:alnum:]]\\|$\\)")
     (1 'opencode-markdown-markup-face t)
     (2 'opencode-markdown-bold-face t)
     (3 'opencode-markdown-markup-face t))

    ;; Italic: *text* or _text_ (not ** or __)
    ;; Delimiters get markup face, content gets italic.
    ;; Content must not span newlines; must not be space-adjacent to delimiters.
    ;; Closing delimiter must not be followed by another * or _ (avoids matching inside **).
    (,(opencode-session--make-text-matcher
       "\\(?:^\\|[^\\\\*]\\)\\(\\*\\)\\([^* \n][^*\n]*?[^\\\\* \n]\\|[^* \n]\\)\\(\\*\\)\\(?:[^*]\\|$\\)")
     (1 'opencode-markdown-markup-face t)
     (2 'opencode-markdown-italic-face t)
     (3 'opencode-markdown-markup-face t))
    ;; _text_ requires word boundaries: opening _ not after alnum,
    ;; closing _ not before alnum (matches CommonMark spec for _ delimiters).
    (,(opencode-session--make-text-matcher
       "\\(?:^\\|[^\\\\_[:alnum:]]\\)\\(_\\)\\([^_ \n][^_\n]*?[^\\\\_  \n]\\|[^_ \n]\\)\\(_\\)\\(?:[^_[:alnum:]]\\|$\\)")
     (1 'opencode-markdown-markup-face t)
     (2 'opencode-markdown-italic-face t)
     (3 'opencode-markdown-markup-face t))

    ;; Inline code: `code` — backticks get markup face, content gets code
    (,(opencode-session--make-text-matcher "\\(`\\)\\([^`\n]+\\)\\(`\\)")
     (1 'opencode-markdown-markup-face t)
     (2 'opencode-markdown-code-face t)
     (3 'opencode-markdown-markup-face t))

    ;; Links: [text](url)
    (,(opencode-session--make-text-matcher
       "\\(\\[\\)\\([^]]+\\)\\(\\]\\)(\\([^)]+\\))")
     (1 'opencode-markdown-markup-face t)
     (2 'opencode-markdown-link-face t)
     (3 'opencode-markdown-markup-face t)
     (4 'opencode-markdown-link-url-face t)))
  "Font-lock keywords for markdown syntax in text part regions.")

;;; Code block fontification

(defun opencode-session--fontify-code-blocks (limit)
  "Font-lock matcher for fenced code blocks up to LIMIT.
Applies `opencode-markdown-code-block-delimiter-face' to the fence
lines, `opencode-markdown-language-face' to the language identifier,
and `opencode-markdown-code-block-face' to the content between them."
  (let (found)
    (while (and (not found)
                (re-search-forward "^\\(```\\)\\([^\n]*\\)$" limit t))
      (when (opencode-session--in-part-p (match-beginning 0)
                                         "user-text" "assistant-text")
        (let ((fence-start (match-beginning 0))
              (backticks-end (match-end 1))
              (lang-start (match-beginning 2))
              (lang-end (match-end 2))
              (content-start (1+ (match-end 0))))
          (if (re-search-forward "^\\(```\\)[[:blank:]]*$" limit t)
              (let ((fence-end (match-end 0))
                    (content-end (match-beginning 0)))
                ;; Opening fence backticks
                (put-text-property fence-start backticks-end
                                  'face
                                  'opencode-markdown-code-block-delimiter-face)
                ;; Language identifier (if any)
                (when (< lang-start lang-end)
                  (put-text-property lang-start lang-end
                                    'face
                                    'opencode-markdown-language-face))
                ;; Newline after opening fence
                (when (< backticks-end content-start)
                  (put-text-property (max backticks-end lang-end) content-start
                                    'face
                                    'opencode-markdown-code-block-delimiter-face))
                ;; Code block content
                (when (< content-start content-end)
                  (put-text-property content-start content-end
                                    'face
                                    'opencode-markdown-code-block-face))
                ;; Closing fence
                (put-text-property (match-beginning 0) fence-end
                                  'face
                                  'opencode-markdown-code-block-delimiter-face)
                (set-match-data (list fence-start fence-end))
                (setq found t))
            ;; No closing fence found — unclosed code block, skip
            (goto-char (min (1+ (match-end 0)) limit))))))
    found))

;;; Diff font-lock keywords

(defvar opencode-session--diff-font-lock-keywords
  (let (result)
    (dolist (kw diff-font-lock-keywords)
      (cond
       ;; Skip function-form entries (the last 3 in diff-font-lock-keywords)
       ((and (listp kw) (symbolp (car kw)) (not (stringp (car kw))))
        nil)
       ;; String regexp with face: (REGEXP . FACE) or (REGEXP FACE)
       ((and (consp kw) (stringp (car kw)) (symbolp (cdr kw)))
        (push (cons (opencode-session--make-diff-matcher (car kw))
                    (cdr kw))
              result))
       ;; (REGEXP (SUBEXP FACE) ...) — most diff keywords
       ((and (consp kw) (stringp (car kw)) (listp (cdr kw)))
        (push (cons (opencode-session--make-diff-matcher (car kw))
                    (cdr kw))
              result))
       ;; (REGEXP QUOTE FACE) — shorthand
       ((and (listp kw) (= (length kw) 3)
             (stringp (nth 0 kw)) (eq (nth 1 kw) 'quote))
        (push (list (opencode-session--make-diff-matcher (nth 0 kw))
                    (list 0 (list 'quote (nth 2 kw))))
              result))))
    (nreverse result))
  "Font-lock keywords for unified diff syntax in diff part regions.
Built from `diff-font-lock-keywords' at load time, with each regexp
wrapped to match only inside regions tagged with `opencode-part-type'
of \"diff\".")

;;; Combined keywords

(defvar opencode-session--font-lock-keywords
  (append opencode-session--base-font-lock-keywords
          opencode-session--markdown-font-lock-keywords
          opencode-session--diff-font-lock-keywords)
  "Font-lock keywords for `opencode-session-mode' buffers.
Combines base role faces, markdown text fontification, and diff
fontification, each restricted to appropriate buffer regions via
`opencode-part-type' text properties.")

(provide 'emacs-opencode-session-fontify)

;;; emacs-opencode-session-fontify.el ends here
