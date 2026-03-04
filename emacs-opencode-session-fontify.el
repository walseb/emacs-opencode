;;; emacs-opencode-session-fontify.el --- Font-lock for session buffers  -*- lexical-binding: t; -*-

;;; Commentary:

;; Font-lock keywords and faces for OpenCode session buffers.
;; Provides markdown fontification for human/AI text parts and diff
;; fontification for edit/patch tool output.  Face definitions are
;; modeled after `markdown-mode' for visual consistency.
;;
;; Inline code, bold, and italic matching logic is adapted from
;; markdown-mode (https://jblevins.org/projects/markdown-mode/) by
;; Jason R. Blevins and contributors, licensed under the GNU GPL.

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

;;; Agent mention face

(defface opencode-agent-mention-face
  '((t :inherit font-lock-type-face :weight bold))
  "Face used for @agent mentions in session messages."
  :group 'emacs-opencode)

;;; Markdown regexes (adapted from markdown-mode)

(defconst opencode-session--regex-code
  "\\(?:\\`\\|[^\\]\\)\\(?1:\\(?2:`+\\)\\(?3:\\(?:.\\|\n[^\n]\\)*?[^`]\\)\\(?4:\\2\\)\\)\\(?:[^`]\\|\\'\\)"
  "Regular expression for matching inline code fragments.
Group 1 matches the entire code fragment including the backquotes.
Group 2 matches the opening backquotes.
Group 3 matches the code fragment itself, without backquotes.
Group 4 matches the closing backquotes.
Adapted from `markdown-regex-code'.")

(defconst opencode-session--regex-bold
  "\\(?1:^\\|[^\\]\\)\\(?2:\\(?3:\\*\\*\\|__\\)\\(?4:[^ \n\t\\]\\|[^ \n\t]\\(?:.\\|\n[^\n]\\)*?[^\\ ]\\)\\(?5:\\3\\)\\)"
  "Regular expression for matching bold text.
Group 1 matches the character before the opening delimiter.
Group 2 matches the entire expression, including delimiters.
Groups 3 and 5 match the opening and closing delimiters.
Group 4 matches the text inside the delimiters.
Adapted from `markdown-regex-bold'.")

(defconst opencode-session--regex-italic
  "\\(?:^\\|[^\\]\\)\\(?1:\\(?2:[*_]\\)\\(?3:[^ \\]\\2\\|[^ ]\\(?:.\\|\n[^\n]\\)*?\\)\\(?4:\\2\\)\\)"
  "Regular expression for matching italic text.
Group 1 matches the entire expression, including delimiters.
Groups 2 and 4 match the opening and closing delimiters.
Group 3 matches the text inside the delimiters.
Uses the GFM variant for better underscore handling.
Adapted from `markdown-regex-gfm-italic'.")

(defconst opencode-session--regex-block-separator
  "\n[\n\t\f ]*\n"
  "Regular expression for matching block boundaries.
Adapted from `markdown-regex-block-separator'.")

;;; Part-type dispatch helpers

(defun opencode-session--in-part-p (pos &rest types)
  "Return non-nil when POS has an `opencode-part-type' matching one of TYPES."
  (member (get-text-property pos 'opencode-part-type) types))

(defun opencode-session--in-text-part-p (pos)
  "Return non-nil when POS is in a user-text or assistant-text region."
  (opencode-session--in-part-p pos "user-text" "assistant-text"))

(defun opencode-session--make-text-matcher (regexp)
  "Return a font-lock matcher for REGEXP in text part regions.
The matcher searches forward for REGEXP but only succeeds when the
match lies inside a region with `opencode-part-type' of
\"user-text\" or \"assistant-text\"."
  (lambda (limit)
    (let (found)
      (while (and (not found) (re-search-forward regexp limit t))
        (when (opencode-session--in-text-part-p (match-beginning 0))
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

;;; Context-checking helpers (adapted from markdown-mode)

(defun opencode-session--face-p (pos faces)
  "Return non-nil if the face at POS is one of FACES.
FACES is a list of face symbols.  Handles both single faces and
lists of faces at POS.
Adapted from `markdown--face-p'."
  (let ((face-prop (get-text-property pos 'face)))
    (if (listp face-prop)
        (cl-loop for face in face-prop
                 thereis (memq face faces))
      (memq face-prop faces))))

(defun opencode-session--range-property-any (begin end prop prop-values)
  "Return non-nil if PROP between BEGIN and END matches one of PROP-VALUES.
Adapted from `markdown-range-property-any'."
  (let (props)
    (catch 'found
      (dolist (loc (number-sequence begin end))
        (when (setq props (get-text-property loc prop))
          (cond ((listp props)
                 (dolist (val prop-values)
                   (when (memq val props) (throw 'found loc))))
                (t
                 (dolist (val prop-values)
                   (when (eq val props) (throw 'found loc))))))))))

(defun opencode-session--in-code-block-p (pos)
  "Return non-nil if POS is inside a fenced code block.
Checks for code block faces set by the code block font-lock matcher
which runs earlier in the keyword list."
  (opencode-session--face-p
   pos '(opencode-markdown-code-block-face
         opencode-markdown-code-block-delimiter-face)))

(defun opencode-session--gfm-markup-underscore-p (begin end)
  "Return non-nil if underscore markup between BEGIN and END is valid.
For GFM, underscore delimiters require word boundaries: they must be
preceded by blank/punctuation and followed by blank/punctuation.
Returns t for non-underscore delimiters (asterisks).
Adapted from `markdown--gfm-markup-underscore-p'."
  (let ((is-underscore (eql (char-after begin) ?_)))
    (if (not is-underscore)
        t
      (save-excursion
        (save-match-data
          (goto-char begin)
          (and (looking-back "\\(?:^\\|[[:blank:][:punct:]]\\)" (1- begin))
               (progn
                 (goto-char end)
                 (looking-at-p "\\(?:[[:blank:][:punct:]]\\|$\\)"))))))))

;;; Inline code matching (adapted from markdown-mode)

(defun opencode-session--beginning-of-text-block ()
  "Move backward to the previous beginning of a plain text block.
Adapted from `markdown-beginning-of-text-block'."
  (let ((start (point)))
    (if (re-search-backward opencode-session--regex-block-separator nil t)
        (goto-char (match-end 0))
      (goto-char (point-min)))
    (when (and (= start (point)) (not (bobp)))
      (forward-line -1)
      (if (re-search-backward opencode-session--regex-block-separator nil t)
          (goto-char (match-end 0))
        (goto-char (point-min))))))

(defun opencode-session--end-of-text-block ()
  "Move forward to the next end of a plain text block.
Adapted from `markdown-end-of-text-block'."
  (beginning-of-line)
  (skip-chars-forward " \t\n")
  (when (= (point) (point-min))
    (forward-char))
  (if (re-search-forward opencode-session--regex-block-separator nil t)
      (goto-char (match-end 0))
    (goto-char (point-max)))
  (skip-chars-backward " \t\n")
  (forward-line))

(defun opencode-session--match-code (last)
  "Match inline code fragments from point to LAST.
Sets match data with groups 1 (opening backticks), 2 (code content),
and 3 (closing backticks).
Adapted from `markdown-match-code'."
  (unless (bobp)
    (backward-char 1))
  (let (found)
    (while (and (not found)
                (re-search-forward opencode-session--regex-code last t))
      (let ((begin (match-beginning 1)))
        (cond
         ;; Not in a text part — skip
         ((not (opencode-session--in-text-part-p begin))
          (goto-char (min (1+ begin) last)))
         ;; Inside a fenced code block — skip
         ((opencode-session--in-code-block-p begin)
          (goto-char (min (1+ begin) last)))
         ;; Valid match
         (t
          (set-match-data (list (match-beginning 1) (match-end 1)
                                (match-beginning 2) (match-end 2)
                                (match-beginning 3) (match-end 3)
                                (match-beginning 4) (match-end 4)))
          (goto-char (min (1+ (match-end 0)) last (point-max)))
          (setq found t)))))
    found))

(defun opencode-session--inline-code-at-pos (pos &optional from)
  "Return non-nil if POS is inside an inline code fragment.
Searches from FROM (or the beginning of the text block) using
`opencode-session--match-code'.  Sets match data on success.
Adapted from `markdown-inline-code-at-pos'."
  (save-excursion
    (goto-char pos)
    (let ((old-point (point))
          (end-of-block (progn (opencode-session--end-of-text-block) (point)))
          found)
      (if from
          (goto-char from)
        (opencode-session--beginning-of-text-block))
      (while (and (opencode-session--match-code end-of-block)
                  (setq found t)
                  (< (match-end 0) old-point)))
      (let ((match-group (if (eq (char-after (match-beginning 0)) ?`) 0 1)))
        (and found
             (<= (match-beginning match-group) old-point)
             (> (match-end 0) old-point))))))

(defun opencode-session--inline-code-at-pos-p (pos)
  "Return non-nil if POS is inside an inline code fragment.
Like `opencode-session--inline-code-at-pos' but preserves match data.
Adapted from `markdown-inline-code-at-pos-p'."
  (save-match-data (opencode-session--inline-code-at-pos pos)))

;;; Inline generic matching (adapted from markdown-mode)

(defun opencode-session--match-inline-generic (regex last)
  "Match inline REGEX from the point to LAST.
Skips matches inside fenced code blocks.
Adapted from `markdown-match-inline-generic'."
  (when (re-search-forward regex last t)
    (let ((begin (match-beginning 1)))
      (cond
       ;; Inside fenced code block — skip past and retry
       ((opencode-session--in-code-block-p begin)
        ;; Find end of code block region and retry from there
        (let ((code-end (next-single-property-change begin 'face nil last)))
          (when (and code-end (< (goto-char code-end) last))
            (opencode-session--match-inline-generic regex last))))
       ;; Valid match
       (t
        (<= (match-end 0) last))))))

;;; Bold matching (adapted from markdown-mode)

(defun opencode-session--match-bold (last)
  "Match bold markup from point to LAST.
Adapted from `markdown-match-bold'."
  (let (done retval last-inline-code)
    (while (not done)
      (if (opencode-session--match-inline-generic
           opencode-session--regex-bold last)
          (let ((begin (match-beginning 2))
                (end (match-end 2)))
            (if (or
                 ;; Not in a text part
                 (not (opencode-session--in-text-part-p begin))
                 ;; Inside cached inline code range
                 (and last-inline-code
                      (>= begin (car last-inline-code))
                      (< begin (cdr last-inline-code)))
                 ;; Inside inline code (search and cache)
                 (save-match-data
                   (when (opencode-session--inline-code-at-pos
                          begin (cdr last-inline-code))
                     (setq last-inline-code
                           `(,(match-beginning 0) . ,(match-end 0)))))
                 ;; End is inside inline code
                 (opencode-session--inline-code-at-pos-p end)
                 ;; Overlaps with HR face
                 (opencode-session--range-property-any
                  begin end 'face '(opencode-markdown-hr-face))
                 ;; Underscore word-boundary check
                 (not (opencode-session--gfm-markup-underscore-p begin end)))
                (progn (goto-char (min (1+ begin) last))
                       (unless (< (point) last)
                         (setq done t)))
              (set-match-data (list (match-beginning 2) (match-end 2)
                                    (match-beginning 3) (match-end 3)
                                    (match-beginning 4) (match-end 4)
                                    (match-beginning 5) (match-end 5)))
              (setq done t retval t)))
        (setq done t)))
    retval))

;;; Italic matching (adapted from markdown-mode)

(defun opencode-session--match-italic (last)
  "Match italic markup from point to LAST.
Adapted from `markdown-match-italic'."
  (let (done retval last-inline-code)
    (while (not done)
      (if (opencode-session--match-inline-generic
           opencode-session--regex-italic last)
          (let ((begin (match-beginning 1))
                (end (match-end 1))
                (close-end (match-end 4)))
            (if (or
                 ;; Not in a text part
                 (not (opencode-session--in-text-part-p begin))
                 ;; Opening delimiter is same as next char (actually bold)
                 (eql (char-before begin) (char-after begin))
                 ;; Inside cached inline code range
                 (and last-inline-code
                      (>= begin (car last-inline-code))
                      (< begin (cdr last-inline-code)))
                 ;; Inside inline code (search and cache)
                 (save-match-data
                   (when (opencode-session--inline-code-at-pos
                          begin (cdr last-inline-code))
                     (setq last-inline-code
                           `(,(match-beginning 0) . ,(match-end 0)))))
                 ;; End is inside inline code
                 (opencode-session--inline-code-at-pos-p (1- end))
                 ;; Overlaps with bold or HR face
                 (opencode-session--range-property-any
                  begin end 'face '(opencode-markdown-bold-face
                                    opencode-markdown-hr-face))
                 ;; Underscore word-boundary check
                 (not (opencode-session--gfm-markup-underscore-p
                       begin close-end)))
                (progn (goto-char (min (1+ begin) last))
                       (unless (< (point) last)
                         (setq done t)))
              (set-match-data (list (match-beginning 1) (match-end 1)
                                    (match-beginning 2) (match-end 2)
                                    (match-beginning 3) (match-end 3)
                                    (match-beginning 4) (match-end 4)))
              (setq done t retval t)))
        (setq done t)))
    retval))

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
              (setq end (or (next-single-property-change
                             (point) 'opencode-part-type nil limit)
                            limit))
              (set-match-data (list start end))
              (goto-char end)
              (setq found t))
          (goto-char (or (next-single-property-change
                          (point) 'opencode-part-type nil limit)
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

    ;; Blockquotes: > text
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

    ;; Inline code — must come before bold/italic so they can check
    ;; for code spans and skip them.
    (opencode-session--match-code
     (1 'opencode-markdown-markup-face prepend)
     (2 'opencode-markdown-code-face prepend)
     (3 'opencode-markdown-markup-face prepend))

    ;; Links: [text](url)
    (,(opencode-session--make-text-matcher
       "\\(\\[\\)\\([^]]+\\)\\(\\]\\)(\\([^)]+\\))")
     (1 'opencode-markdown-markup-face t)
     (2 'opencode-markdown-link-face t)
     (3 'opencode-markdown-markup-face t)
     (4 'opencode-markdown-link-url-face t))

    ;; Bold: **text** or __text__
    (opencode-session--match-bold
     (1 'opencode-markdown-markup-face prepend)
     (2 'opencode-markdown-bold-face append)
     (3 'opencode-markdown-markup-face prepend))

    ;; Italic: *text* or _text_
    (opencode-session--match-italic
     (1 'opencode-markdown-markup-face prepend)
     (2 'opencode-markdown-italic-face append)
     (3 'opencode-markdown-markup-face prepend))

    ;; @agent mentions: @name preceded by whitespace or start of line
    (,(opencode-session--make-text-matcher
       "\\(?:^\\|[[:space:]]\\)\\(@[a-zA-Z0-9_-]+\\)")
     (1 'opencode-agent-mention-face prepend)))
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
      (when (opencode-session--in-text-part-p (match-beginning 0))
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
