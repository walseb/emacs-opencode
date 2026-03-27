;;; emacs-opencode-sse.el --- OpenCode SSE handling  -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'emacs-opencode-connection)
(require 'emacs-opencode-sse-profile)

(defun opencode--json-read ()
  "Read JSON from the current buffer with JSON false mapped to nil."
  (if (fboundp 'json-parse-buffer)
      (json-parse-buffer :object-type 'alist
                         :array-type 'list
                         :null-object nil
                         :false-object nil)
    (let ((json-false nil))
      (json-read))))

(defgroup emacs-opencode nil
  "Emacs client for the OpenCode server."
  :group 'applications)

(defcustom opencode-sse-curl-command "curl"
  "Curl command used for SSE streaming."
  :type 'string
  :group 'emacs-opencode)

(defcustom opencode-sse-log-output nil
  "When non-nil, log raw SSE output to the process buffer."
  :type 'boolean
  :group 'emacs-opencode)

(defcustom opencode-sse-log-max-size (* 1024 1024)
  "Maximum size in bytes for the SSE log buffer.
When the buffer exceeds this size, the oldest content is discarded.
Set to nil to disable truncation."
  :type '(choice (integer :tag "Max bytes")
                 (const :tag "Unlimited" nil))
  :group 'emacs-opencode)

(defvar opencode-sse--handlers nil
  "Alist mapping SSE event names to handler lists.")

(defun opencode-sse--add-handler (event handler)
  "Register HANDLER for SSE EVENT if not already present."
  (let ((current (alist-get event opencode-sse--handlers nil nil #'string=)))
    (unless (memq handler current)
      (setf (alist-get event opencode-sse--handlers nil nil #'string=)
            (cons handler current)))))

(defmacro opencode-sse-define-handler (name event args &rest body)
  "Define and register an SSE handler for EVENT named NAME.

ARGS and BODY are passed to `defun`. EVENT is the SSE event name string.
Returns the created function symbol."
  (declare (indent defun))
  (let ((fn-name (intern (format "opencode-sse--%s-handler" name))))
    `(progn
       (defun ,fn-name ,args
        ,(format "Handle SSE event %s." event)
        ,@body)
       (opencode-sse-register-handler ,event #',fn-name)
       #',fn-name)))

(defun opencode-sse-register-handler (event handler)
  "Register HANDLER for SSE EVENT.

EVENT is a string. HANDLER receives EVENT and DATA."
  (opencode-sse--add-handler event handler))

(defun opencode-sse-unregister-handlers (event)
  "Remove all handlers registered for EVENT."
  (setq opencode-sse--handlers
        (assoc-delete-all event opencode-sse--handlers)))

(defun opencode-sse--dispatch (event data)
  "Dispatch EVENT and DATA to registered handlers."
  (let ((handlers (alist-get event opencode-sse--handlers nil nil #'string=)))
    (dolist (handler handlers)
      (funcall handler event data))))

(defun opencode-sse--decode-data (data)
  "Decode DATA from JSON.

Signals an error when DATA is not valid JSON."
  (condition-case err
      (with-temp-buffer
        (insert data)
        (goto-char (point-min))
        (opencode--json-read))
    (error "OpenCode SSE payload is not valid JSON: %s"
           (error-message-string err))))

(defun opencode-sse--ensure-curl ()
  "Ensure the configured curl executable exists."
  (unless (executable-find opencode-sse-curl-command)
    (error "OpenCode SSE requires curl; ensure `%s` is on PATH" opencode-sse-curl-command)))

(defun opencode-sse--build-url (connection)
  "Build the SSE endpoint URL for CONNECTION."
  (format "%s/event"
          (string-remove-suffix "/" (opencode-connection-base-url connection))))

(defun opencode-sse--auth-header (connection)
  "Return an Authorization header for CONNECTION when needed."
  (when-let ((password (opencode-connection-password connection)))
    (let ((user (or (opencode-connection-username connection) "opencode")))
      (format "Authorization: Basic %s"
              (base64-encode-string (format "%s:%s" user password) t)))))

(defun opencode-sse--build-command (connection)
  "Build curl command for CONNECTION."
  (let ((url (opencode-sse--build-url connection))
        (auth (opencode-sse--auth-header connection)))
    (append
     (list opencode-sse-curl-command "-N" "-s" "-S")
     (when auth (list "-H" auth))
     (list url))))

(defun opencode-sse--initialize-state (connection)
  "Initialize SSE parse state on CONNECTION.
State keys:
  :fragments   — reversed list of raw chunks (including \"data: \" prefix)
  :trailing-nl — non-nil when the last fragment ended with newline"
  (setf (opencode-connection-sse-state connection)
        (list :fragments nil :trailing-nl nil)))

(defun opencode-sse--ensure-state (connection)
  "Return the SSE parser state for CONNECTION."
  (or (opencode-connection-sse-state connection)
      (opencode-sse--initialize-state connection)))

(defun opencode-sse--read-state (connection key)
  "Read KEY from CONNECTION SSE state."
  (plist-get (opencode-sse--ensure-state connection) key))

(defun opencode-sse--write-state (connection key value)
  "Write VALUE for KEY in CONNECTION SSE state."
  (let ((state (opencode-sse--ensure-state connection)))
    (setf (opencode-connection-sse-state connection)
          (plist-put state key value))
    value))

(defun opencode-sse--clear-event (connection)
  "Reset event fields in CONNECTION SSE state."
  (opencode-sse--write-state connection :fragments nil)
  (opencode-sse--write-state connection :trailing-nl nil))

(defun opencode-sse--strip-data-prefix (str)
  "Strip the \"data: \" prefix from STR.
Returns the payload portion, or STR unchanged if no prefix is found."
  (if (string-prefix-p "data: " str)
      (substring str 6)
    str))

(defun opencode-sse--extract-event-type (data)
  "Extract the event type from raw SSE DATA without JSON parsing.
Returns the type string, or nil if it cannot be extracted."
  (when (string-match "\\`{\"type\":\"\\([^\"]+\\)\"" data)
    (match-string 1 data)))

(defun opencode-sse--finalize-event (connection fragments)
  "Finalize and dispatch an event built from FRAGMENTS.
FRAGMENTS is a reversed list of raw chunks (including the
\"data: \" prefix on the first chunk).  Join them, strip the
prefix, extract the event type, JSON-parse, and dispatch.
Resets CONNECTION SSE state afterward."
  (opencode-sse--clear-event connection)
  (when fragments
    ;; Join all fragments into a single string.  The first fragment
    ;; starts with "data: " which we strip.  Trailing newlines from
    ;; the line terminator are trimmed (they are part of the SSE
    ;; framing, not the payload).
    (let* ((raw (apply #'concat (nreverse fragments)))
           (data (string-trim-right
                  (opencode-sse--strip-data-prefix raw)
                  "[\n\r]+"))
           (event (opencode-sse--extract-event-type data))
           (data-bytes (string-bytes data)))
      (unless event
        (error "OpenCode SSE payload missing type field"))
      ;; Only JSON-parse events that have registered handlers.
      (if (null (alist-get event opencode-sse--handlers nil nil #'string=))
          ;; No handler — record skip if profiling.
          (when opencode-sse-profile-enabled
            (opencode-sse-profile--record-skip event data-bytes))
        ;; Has a handler — parse and dispatch.
        (if opencode-sse-profile-enabled
            (let* ((parse-start (opencode-sse-profile--now))
                   (payload (opencode-sse--decode-data data))
                   (parse-ms (opencode-sse-profile--elapsed-ms parse-start))
                   (dispatch-start (opencode-sse-profile--now)))
              (opencode-sse--dispatch event payload)
              (let ((dispatch-ms (opencode-sse-profile--elapsed-ms dispatch-start)))
                (opencode-sse-profile--record-finalize
                 event parse-ms dispatch-ms data-bytes)))
          (let ((payload (opencode-sse--decode-data data)))
            (opencode-sse--dispatch event payload)))))))

(defun opencode-sse--process-chunk (connection chunk)
  "Process SSE CHUNK for CONNECTION.

This is an OpenCode-specific SSE parser optimized for the format
that OpenCode actually emits: each event is a single \"data: \"
line of compact JSON followed by a blank line (\\n\\n).

The parser never does line-splitting or field parsing.  Instead it
accumulates raw chunks in a reversed fragment list (:fragments)
and scans only the current chunk and a one-byte trailing-newline
flag to detect the \\n\\n event boundary in near-constant time
per chunk.

For a large event arriving across N chunks, per-chunk work is
O(1).  The single O(n) cost—joining all fragments—happens once
at finalization."
  (let ((chunk-start
         (and opencode-sse-profile-enabled (opencode-sse-profile--now))))
    (opencode-sse--process-chunk-1 connection chunk)
    (when chunk-start
      (opencode-sse-profile--record-chunk
       (opencode-sse-profile--elapsed-ms chunk-start)
       (string-bytes chunk)))))

(defun opencode-sse--find-boundary (connection chunk)
  "Find \\n\\n boundary in CHUNK, considering CONNECTION trailing-nl state.

Returns a cons (PRE-END . REST-START) where PRE-END is the index
in CHUNK up to which data belongs to the current event and
REST-START is the index where post-boundary content begins.
Returns nil if no boundary is found.

When the boundary is split across chunks (previous chunk ended
with \\n, this one starts with \\n), PRE-END is 0 and REST-START
is 1 (skip the \\n that completes the boundary)."
  (let ((trailing-nl (opencode-sse--read-state connection :trailing-nl)))
    (cond
     ;; Boundary split across chunks: prev ended with \n, this starts with \n.
     ((and trailing-nl (> (length chunk) 0) (= (aref chunk 0) ?\n))
      (cons 0 1))
     ;; Boundary within this chunk.
     (t
      (when-let ((pos (string-search "\n\n" chunk)))
        (cons pos (+ pos 2)))))))

(defun opencode-sse--process-chunk-1 (connection chunk)
  "Internal: process SSE CHUNK for CONNECTION without profiling wrapper.

Accumulates CHUNK into a reversed fragment list.  When the \\n\\n
event boundary is detected (either within CHUNK or split across
CHUNK and the previous one), all accumulated fragments are passed
to `opencode-sse--finalize-event' for joining, type extraction,
and conditional JSON parse + dispatch."
  (let ((boundary (opencode-sse--find-boundary connection chunk)))
    (if (not boundary)
        ;; No boundary — push fragment, update trailing-nl.
        (progn
          (opencode-sse--write-state
           connection :fragments
           (cons chunk (opencode-sse--read-state connection :fragments)))
          (opencode-sse--write-state
           connection :trailing-nl
           (string-suffix-p "\n" chunk)))
      ;; Boundary found — finalize the event.
      (let* ((pre-end (car boundary))
             (pre (if (> pre-end 0) (substring chunk 0 pre-end) nil))
             (fragments (opencode-sse--read-state connection :fragments))
             (all-fragments (if pre (cons pre fragments) fragments))
             (rest (substring chunk (cdr boundary))))
        (opencode-sse--finalize-event connection all-fragments)
        (unless (string-empty-p rest)
          (opencode-sse--process-chunk connection rest))))))

(defun opencode-sse-open (connection)
  "Open an SSE stream for CONNECTION.

Returns the streaming process."
  (opencode-sse--ensure-curl)
  (let* ((buffer (get-buffer-create (format " *opencode-sse<%s>*"
                                            (opencode-connection-directory connection))))
         (command (opencode-sse--build-command connection))
         (process (make-process
                   :name "opencode-sse"
                   :buffer buffer
                   :command command
                   :noquery t
                   :filter (lambda (proc output)
                              (when opencode-sse-log-output
                                (when-let ((buffer (process-buffer proc)))
                                  (when (buffer-live-p buffer)
                                    (with-current-buffer buffer
                                      (let ((inhibit-read-only t)
                                            (inhibit-modification-hooks t)
                                            (inhibit-redisplay t))
                                        (save-excursion
                                          (goto-char (process-mark proc))
                                          (insert output)
                                          (set-marker (process-mark proc) (point)))
                                        (when (and opencode-sse-log-max-size
                                                   (> (buffer-size) opencode-sse-log-max-size))
                                          (let ((target (/ opencode-sse-log-max-size 2)))
                                            (delete-region (point-min)
                                                           (- (point-max) target)))))))))
                              (opencode-sse--process-chunk connection output))
                   :sentinel (lambda (proc _event)
                               (when (memq (process-status proc) '(exit signal))
                                 (when (buffer-live-p buffer)
                                   (with-current-buffer buffer
                                     (let ((inhibit-read-only t)
                                           (inhibit-modification-hooks t))
                                       (goto-char (point-max))
                                       (insert "\n[opencode] SSE stream closed")))))))))
    (with-current-buffer buffer
      (setq-local buffer-read-only t)
      (setq-local buffer-undo-list t)
      (setq-local auto-save-default nil)
      (setq-local truncate-lines t))
    (setf (opencode-connection-sse-process connection) process)
    process))

(defun opencode-sse-close (connection)
  "Stop the SSE stream for CONNECTION."
  (when-let ((process (opencode-connection-sse-process connection)))
    (when (process-live-p process)
      (delete-process process))
    (when-let ((buffer (process-buffer process)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))
    (setf (opencode-connection-sse-process connection) nil)
    (setf (opencode-connection-sse-state connection) nil)))

(provide 'emacs-opencode-sse)

;;; emacs-opencode-sse.el ends here
