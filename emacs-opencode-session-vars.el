;;; emacs-opencode-session-vars.el --- Shared session state  -*- lexical-binding: t; -*-

(require 'cl-lib)

(defgroup emacs-opencode nil
  "Emacs client for the OpenCode server."
  :group 'applications)

(defvar opencode-session--buffers (make-hash-table :test 'equal)
  "Registry mapping session IDs to buffers.")

(defvar-local opencode-session--session nil
  "Session object for the current buffer.")

(defvar-local opencode-session--messages nil
  "List of message objects for the current buffer.")

(defvar-local opencode-session--connection nil
  "Connection used for the current session buffer.")

(defvar-local opencode-session--input-start-marker nil
  "Marker indicating the start of the input region.")

(defvar-local opencode-session--input-marker nil
  "Marker indicating the end of the input region.")

(defvar-local opencode-session--agent nil
  "Selected agent name for the current session buffer.")

(defvar-local opencode-session--provider-id nil
  "Selected provider ID for the current session buffer.")

(defvar-local opencode-session--model-id nil
  "Selected model ID for the current session buffer.")

(defvar-local opencode-session--variant nil
  "Selected model variant for the current session buffer.")

(defun opencode-session--buffer-for-session (session-id)
  "Return the session buffer for SESSION-ID, if any."
  (gethash session-id opencode-session--buffers))

(defun opencode-session--normalize-items (items)
  "Normalize ITEMS to a list when vector or list."
  (cond
   ((vectorp items) (append items nil))
   ((listp items) items)
   (t nil)))

(provide 'emacs-opencode-session-vars)

;;; emacs-opencode-session-vars.el ends here
