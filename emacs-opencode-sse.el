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
  "Initialize SSE parse state on CONNECTION."
  (setf (opencode-connection-sse-state connection)
        (list :buffer nil :data nil :skipping nil)))

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
  (opencode-sse--write-state connection :skipping nil)
  (opencode-sse--write-state connection :skip-event-type nil)
  (opencode-sse--write-state connection :skip-bytes nil)
  (opencode-sse--write-state connection :in-flight-event nil)
  (opencode-sse--write-state connection :in-flight-bytes 0))

(defun opencode-sse--append-data (connection value)
  "Append VALUE to the CONNECTION SSE data list.
Each call pushes VALUE onto a list stored in reverse order.
Use `opencode-sse--join-data' to retrieve the final string."
  (let ((current (opencode-sse--read-state connection :data)))
    (opencode-sse--write-state connection :data (cons value current))))

(defun opencode-sse--join-data (connection)
  "Return the accumulated SSE data for CONNECTION as a single string.
Data lines are joined with newlines per the SSE spec."
  (let ((parts (opencode-sse--read-state connection :data)))
    (when parts
      (mapconcat #'identity (nreverse parts) "\n"))))

(defun opencode-sse--join-buffer (connection)
  "Return the accumulated buffer fragments for CONNECTION as a single string.
Buffer fragments are stored in reverse order and joined with `nreverse'."
  (let ((parts (opencode-sse--read-state connection :buffer)))
    (if parts
        (apply #'concat (reverse parts))
      "")))

(defun opencode-sse--extract-event-type (data)
  "Extract the event type from raw SSE DATA without JSON parsing.
Returns the type string, or nil if it cannot be extracted."
  (when (string-match "\\`{\"type\":\"\\([^\"]+\\)\"" data)
    (match-string 1 data)))

(defun opencode-sse--finalize-event (connection)
  "Finalize and dispatch event from CONNECTION SSE state."
  (if (opencode-sse--read-state connection :skipping)
      ;; We were skipping an unhandled event; just reset state.
      (progn
        (when opencode-sse-profile-enabled
          (let ((skip-bytes (opencode-sse--read-state connection :skip-bytes)))
            (when-let ((event-type (opencode-sse--read-state connection :skip-event-type)))
              (opencode-sse-profile--record-skip event-type (or skip-bytes 0)))))
        (opencode-sse--clear-event connection))
    (let ((parts (opencode-sse--read-state connection :data)))
      (opencode-sse--clear-event connection)
      (when parts
        ;; Join the accumulated data lines into a single string.
        (let* ((data (mapconcat #'identity (nreverse parts) "\n"))
               (event (opencode-sse--extract-event-type data))
               (data-bytes (string-bytes data)))
          (unless event
            (error "OpenCode SSE payload missing type field"))
          ;; Only JSON-parse events that have registered handlers
          (when (alist-get event opencode-sse--handlers nil nil #'string=)
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
                (opencode-sse--dispatch event payload)))))))))

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
                  (progn
                    (opencode-sse--write-state connection :skipping t)
                    (when opencode-sse-profile-enabled
                      (opencode-sse--write-state connection :skip-event-type event-type)
                      (opencode-sse--write-state connection :skip-bytes
                                                  (string-bytes value))))
                ;; Has a handler (or type unknown); accumulate normally.
                (when opencode-sse-profile-enabled
                  (opencode-sse--write-state connection :in-flight-event
                                              (or event-type "(unknown)"))
                  (opencode-sse--write-state connection :in-flight-bytes
                                              (string-bytes value)))
                (opencode-sse--append-data connection value))))
          ;; Subsequent data line of a handled event -- accumulate.
          (t
           (when opencode-sse-profile-enabled
             (let ((prev (or (opencode-sse--read-state connection :in-flight-bytes) 0)))
               (opencode-sse--write-state connection :in-flight-bytes
                                           (+ prev (string-bytes value)))))
           (opencode-sse--append-data connection value))))
        (_ nil))))))

(defun opencode-sse--process-chunk (connection chunk)
  "Process SSE CHUNK for CONNECTION.

The parser accumulates incomplete line fragments in :buffer as a
list of string chunks (in order) to avoid O(n²) re-concatenation
when a single SSE data line is very large.  A full concat + split
only happens when CHUNK actually contains a newline.

When skipping an unhandled event, bypass all line splitting and
string accumulation.  Instead scan the raw CHUNK for the SSE event
boundary (a blank line, i.e. \\n\\n) to detect when the skipped
event ends."
  (let ((sse-profile--chunk-start
         (and opencode-sse-profile-enabled (opencode-sse-profile--now)))
        (sse-profile--chunk-skipping
         (opencode-sse--read-state connection :skipping))
        (sse-profile--in-flight-event
         (and opencode-sse-profile-enabled
              (or (opencode-sse--read-state connection :skip-event-type)
                  (opencode-sse--read-state connection :in-flight-event))))
        (sse-profile--in-flight-bytes
         (and opencode-sse-profile-enabled
              (or (opencode-sse--read-state connection :skip-bytes)
                  (opencode-sse--read-state connection :in-flight-bytes)))))
    (opencode-sse--process-chunk-1 connection chunk)
    (when sse-profile--chunk-start
      (opencode-sse-profile--record-chunk
       (opencode-sse-profile--elapsed-ms sse-profile--chunk-start)
       (string-bytes chunk)
       sse-profile--chunk-skipping
       sse-profile--in-flight-event
       (or sse-profile--in-flight-bytes 0)))))

(defun opencode-sse--process-chunk-1 (connection chunk)
  "Internal: process SSE CHUNK for CONNECTION without profiling wrapper."
  (if (opencode-sse--read-state connection :skipping)
      ;; Fast path: skip all processing, just scan for event boundary.
      ;; :buffer in skip mode is a short string (at most "\n") stored
      ;; as a one-element list, so flatten it cheaply.
      (let* ((pending (car (opencode-sse--read-state connection :buffer)))
             (haystack (if (or (null pending) (string-empty-p pending))
                           chunk
                         (concat pending chunk)))
             (boundary (string-match "\n\n" haystack)))
        ;; Accumulate skip bytes for profiling
        (when opencode-sse-profile-enabled
          (let ((prev (or (opencode-sse--read-state connection :skip-bytes) 0)))
            (opencode-sse--write-state connection :skip-bytes
                                        (+ prev (string-bytes chunk)))))
        (if boundary
            ;; Event boundary found -- the skipped event is over.
            ;; Extract everything after the boundary and process it
            ;; through the normal path (it may contain the next event).
            (let ((rest (substring haystack (+ boundary 2))))
              (opencode-sse--clear-event connection)
              (opencode-sse--write-state connection :buffer nil)
              (unless (string-empty-p rest)
                (opencode-sse--process-chunk connection rest)))
          ;; No boundary yet -- discard chunk entirely.
          ;; Keep only a trailing "\n" so a boundary split across two
          ;; chunks (...\n | \n...) is detected on the next call.
          (opencode-sse--write-state connection :buffer
                                      (if (string-suffix-p "\n" chunk)
                                          '("\n")
                                        nil))))
    ;; Normal path: accumulate chunks and process complete lines.
    (if (not (string-search "\n" chunk))
        ;; No newline in this chunk -- just accumulate the fragment.
        ;; Fragments are stored in reverse order (push to front) so
        ;; accumulation is always O(1).  They are reversed when joined.
        (let ((parts (opencode-sse--read-state connection :buffer)))
          (if parts
              (opencode-sse--write-state connection :buffer (cons chunk parts))
            ;; First fragment of a potential new event.  If it starts
            ;; with "data: " we can peek at the event type and enter
            ;; skip mode immediately, avoiding accumulation of large
            ;; payloads that have no registered handler.
            (let ((value nil)
                  (event-type nil))
              (when (string-prefix-p "data: " chunk)
                (setq value (substring chunk 6))
                (setq event-type (opencode-sse--extract-event-type value)))
              (if (and event-type
                       (null (alist-get event-type opencode-sse--handlers
                                        nil nil #'string=)))
                  ;; No handler -- enter skip mode, discard chunk.
                  (progn
                    (opencode-sse--write-state connection :skipping t)
                    (opencode-sse--write-state connection :buffer nil)
                    (when opencode-sse-profile-enabled
                      (opencode-sse--write-state connection :skip-event-type event-type)
                      (opencode-sse--write-state connection :skip-bytes
                                                  (string-bytes chunk))))
                ;; Has a handler, unknown type, or not a data line --
                ;; accumulate normally.
                (opencode-sse--write-state connection :buffer (list chunk))
                (when (and opencode-sse-profile-enabled event-type)
                  (opencode-sse--write-state connection :in-flight-event event-type)
                  (opencode-sse--write-state connection :in-flight-bytes
                                              (string-bytes chunk)))))))
      ;; Newline found -- join all accumulated fragments with this
      ;; chunk, split into lines, and process the complete ones.
      ;; Fragments are in reverse order, so reverse before joining.
      (let* ((parts (opencode-sse--read-state connection :buffer))
             (full (if parts
                       (apply #'concat (nreverse (cons chunk parts)))
                     chunk))
             (lines (split-string full "\n"))
             (incomplete (car (last lines)))
             (complete-lines (butlast lines)))
        (opencode-sse--write-state connection :buffer
                                    (if (string-empty-p incomplete)
                                        nil
                                      (list incomplete)))
        (dolist (line complete-lines)
          (opencode-sse--process-line
           connection (string-trim-right line "\r")))
        ;; If :skipping was set during the dolist, seed :buffer with
        ;; "\n" so the fast path can detect a boundary that starts in
        ;; the very next chunk.  split-string consumed the trailing \n
        ;; of the data line that triggered the skip, so we restore it.
        (when (opencode-sse--read-state connection :skipping)
          (opencode-sse--write-state connection :buffer '("\n")))))))

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
