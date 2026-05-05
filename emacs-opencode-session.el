;;; emacs-opencode-session.el --- OpenCode session model  -*- lexical-binding: t; -*-

(require 'cl-lib)

(cl-defstruct (opencode-session (:constructor opencode-session-create))
  "Structured representation of an OpenCode session."
  id
  slug
  version
  project-id
  directory
  title
  time-created
  time-updated
  status
  summary
  diff
  info)

(cl-defstruct (opencode-status (:constructor opencode-status-create))
  "Structured representation of an OpenCode session status.

The TYPE field is a string matching the server's status type:
\"idle\", \"busy\", or \"retry\".  When TYPE is \"retry\", the
ATTEMPT, MESSAGE, and NEXT fields carry the retry payload from the
session.status SSE event."
  type
  attempt
  message
  next)

(defun opencode-status-busy-p (status)
  "Return non-nil when STATUS represents a non-idle session.

STATUS may be an `opencode-status' struct, a string status type
\(legacy callers), or nil.  Nil and \"idle\" are considered idle."
  (let ((type (cond
               ((opencode-status-p status) (opencode-status-type status))
               ((stringp status) status)
               (t nil))))
    (and type (not (string= type "idle")))))

(provide 'emacs-opencode-session)

;;; emacs-opencode-session.el ends here
