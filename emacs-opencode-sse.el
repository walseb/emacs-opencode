;;; emacs-opencode-sse.el --- OpenCode SSE handling  -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'emacs-opencode-connection)

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
  "Initialize SSE parse state on CONNECTION."
  (setf (opencode-connection-sse-state connection)
        (list :buffer "" :data nil :skipping nil)))

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
  (opencode-sse--write-state connection :data nil)
  (opencode-sse--write-state connection :skipping nil))

(defun opencode-sse--append-data (connection value)
  "Append VALUE to CONNECTION SSE data field."
  (let ((current (opencode-sse--read-state connection :data)))
    (opencode-sse--write-state connection :data
                               (if current (concat current "\n" value) value))))

(defun opencode-sse--extract-event-type (data)
  "Extract the event type from raw SSE DATA without JSON parsing.
Returns the type string, or nil if it cannot be extracted."
  (when (string-match "\\`{\"type\":\"\\([^\"]+\\)\"" data)
    (match-string 1 data)))

(defun opencode-sse--finalize-event (connection)
  "Finalize and dispatch event from CONNECTION SSE state."
  (if (opencode-sse--read-state connection :skipping)
      ;; We were skipping an unhandled event; just reset state.
      (opencode-sse--clear-event connection)
    (let ((data (opencode-sse--read-state connection :data)))
      (opencode-sse--clear-event connection)
      (when data
        (let ((event (opencode-sse--extract-event-type data)))
          (unless event
            (error "OpenCode SSE payload missing type field"))
          ;; Only JSON-parse events that have registered handlers
          (when (alist-get event opencode-sse--handlers nil nil #'string=)
            (let ((payload (opencode-sse--decode-data data)))
              (opencode-sse--dispatch event payload))))))))

(defun opencode-sse--process-line (connection line)
  "Process LINE in SSE parser CONNECTION state."
  (cond
   ((string-empty-p line)
    (opencode-sse--finalize-event connection))
   ((string-prefix-p ":" line)
    nil)
   (t
    (let* ((colon-pos (string-match ":" line))
           (field (substring line 0 colon-pos))
           (value (substring line (1+ colon-pos))))
      ;; Per SSE spec, strip at most one leading space from the value.
      (when (string-prefix-p " " value)
        (setq value (substring value 1)))
      (pcase field
        ("data"
         (cond
          ;; Already skipping an unhandled event -- do nothing.
          ((opencode-sse--read-state connection :skipping) nil)
          ;; First data line of a new event -- check if we should skip.
          ((null (opencode-sse--read-state connection :data))
           (let ((event-type (opencode-sse--extract-event-type value)))
             (if (and event-type
                      (null (alist-get event-type opencode-sse--handlers
                                       nil nil #'string=)))
                 ;; No handler registered; skip the rest of this event.
                 (opencode-sse--write-state connection :skipping t)
               ;; Has a handler (or type unknown); accumulate normally.
               (opencode-sse--append-data connection value))))
          ;; Subsequent data line of a handled event -- accumulate.
          (t (opencode-sse--append-data connection value))))
        (_ nil))))))

(defun opencode-sse--process-chunk (connection chunk)
  "Process SSE CHUNK for CONNECTION.

When skipping an unhandled event, bypass all line splitting and
string accumulation.  Instead scan the raw CHUNK for the SSE event
boundary (a blank line, i.e. \\n\\n) to detect when the skipped
event ends."
  (if (opencode-sse--read-state connection :skipping)
      ;; Fast path: skip all processing, just scan for event boundary.
      ;; Prepend :buffer (at most a few bytes left over from the
      ;; split-string that detected the skip) so that a boundary
      ;; spanning the transition into skip mode is still found.
      (let* ((pending (opencode-sse--read-state connection :buffer))
             (haystack (if (string-empty-p pending)
                           chunk
                         (concat pending chunk)))
             (boundary (string-match "\n\n" haystack)))
        (if boundary
            ;; Event boundary found -- the skipped event is over.
            ;; Extract everything after the boundary and process it
            ;; through the normal path (it may contain the next event).
            (let ((rest (substring haystack (+ boundary 2))))
              (opencode-sse--clear-event connection)
              (opencode-sse--write-state connection :buffer "")
              (unless (string-empty-p rest)
                (opencode-sse--process-chunk connection rest)))
          ;; No boundary yet -- discard chunk entirely.
          ;; Keep only a trailing "\n" so a boundary split across two
          ;; chunks (...\n | \n...) is detected on the next call.
          (opencode-sse--write-state connection :buffer
                                      (if (string-suffix-p "\n" chunk)
                                          "\n"
                                        ""))))
    ;; Normal path: split into lines and process each.
    (let* ((buffer (concat (opencode-sse--read-state connection :buffer) chunk))
           (lines (split-string buffer "\n"))
           (incomplete (car (last lines)))
           (complete-lines (butlast lines)))
      (opencode-sse--write-state connection :buffer incomplete)
      (dolist (line complete-lines)
        (opencode-sse--process-line connection (string-trim-right line "\r")))
      ;; If :skipping was set during the dolist, seed :buffer with
      ;; "\n" so the fast path can detect a boundary that starts in
      ;; the very next chunk.  split-string consumed the trailing \n
      ;; of the data line that triggered the skip, so we restore it.
      (when (opencode-sse--read-state connection :skipping)
        (opencode-sse--write-state connection :buffer "\n")))))

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
