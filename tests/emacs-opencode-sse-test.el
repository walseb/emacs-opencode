;;; emacs-opencode-sse-test.el --- Tests for SSE handling  -*- lexical-binding: t; -*-

(require 'ert)
(require 'emacs-opencode-sse)

;;; extract-event-type

(ert-deftest test-opencode-sse/extract-event-type-simple ()
  "Extract type from a well-formed JSON string."
  (should (equal (opencode-sse--extract-event-type
                  "{\"type\":\"session.created\",\"data\":{}}")
                 "session.created")))

(ert-deftest test-opencode-sse/extract-event-type-missing ()
  "Return nil when type field is absent."
  (should (null (opencode-sse--extract-event-type "{\"data\":{}}"))))

(ert-deftest test-opencode-sse/extract-event-type-not-first ()
  "Return nil when type is not the first key."
  (should (null (opencode-sse--extract-event-type
                 "{\"data\":{},\"type\":\"foo\"}"))))

(ert-deftest test-opencode-sse/extract-event-type-empty-string ()
  "Return nil for empty input."
  (should (null (opencode-sse--extract-event-type ""))))

;;; build-url

(ert-deftest test-opencode-sse/build-url ()
  "Build the /event URL from a connection."
  (let ((conn (opencode-connection-create
               :base-url "http://localhost:4096")))
    (should (equal (opencode-sse--build-url conn)
                   "http://localhost:4096/event"))))

(ert-deftest test-opencode-sse/build-url-trailing-slash ()
  "Strip trailing slash from base URL before appending /event."
  (let ((conn (opencode-connection-create
               :base-url "http://localhost:4096/")))
    (should (equal (opencode-sse--build-url conn)
                   "http://localhost:4096/event"))))

;;; auth-header

(ert-deftest test-opencode-sse/auth-header-with-credentials ()
  "Build Basic auth header when password is set."
  (let ((conn (opencode-connection-create
               :username "user"
               :password "pass")))
    (should (string-prefix-p "Authorization: Basic "
                             (opencode-sse--auth-header conn)))))

(ert-deftest test-opencode-sse/auth-header-no-password ()
  "Return nil when no password is set."
  (let ((conn (opencode-connection-create)))
    (should (null (opencode-sse--auth-header conn)))))

(ert-deftest test-opencode-sse/auth-header-default-username ()
  "Default username to \"opencode\" when only password is set."
  (let* ((conn (opencode-connection-create :password "secret"))
         (header (opencode-sse--auth-header conn)))
    (should (stringp header))
    ;; Decode to verify default username
    (string-match "Basic \\(.+\\)" header)
    (let ((decoded (base64-decode-string (match-string 1 header))))
      (should (string-prefix-p "opencode:" decoded)))))

;;; SSE state helpers

(ert-deftest test-opencode-sse/state-read-write ()
  "Read and write SSE parse state."
  (let ((conn (opencode-connection-create)))
    (opencode-sse--initialize-state conn)
    (should (equal (opencode-sse--read-state conn :buffer) ""))
    (opencode-sse--write-state conn :buffer "partial")
    (should (equal (opencode-sse--read-state conn :buffer) "partial"))))

(ert-deftest test-opencode-sse/append-data ()
  "Append data lines with newline separator."
  (let ((conn (opencode-connection-create)))
    (opencode-sse--initialize-state conn)
    (opencode-sse--append-data conn "line1")
    (should (equal (opencode-sse--read-state conn :data) "line1"))
    (opencode-sse--append-data conn "line2")
    (should (equal (opencode-sse--read-state conn :data) "line1\nline2"))))

(ert-deftest test-opencode-sse/clear-event ()
  "Clear event resets data and skipping."
  (let ((conn (opencode-connection-create)))
    (opencode-sse--initialize-state conn)
    (opencode-sse--write-state conn :data "some data")
    (opencode-sse--write-state conn :skipping t)
    (opencode-sse--clear-event conn)
    (should (null (opencode-sse--read-state conn :data)))
    (should (null (opencode-sse--read-state conn :skipping)))))

;;; process-line and process-chunk

(ert-deftest test-opencode-sse/process-line-comment ()
  "Comment lines (starting with ':') are ignored."
  (let ((conn (opencode-connection-create)))
    (opencode-sse--initialize-state conn)
    (opencode-sse--process-line conn ":keep-alive")
    (should (null (opencode-sse--read-state conn :data)))))

(ert-deftest test-opencode-sse/process-line-data-accumulates ()
  "Data lines accumulate in state."
  (let ((conn (opencode-connection-create))
        (opencode-sse--handlers nil))
    (opencode-sse--initialize-state conn)
    ;; Register a handler so data is not skipped
    (opencode-sse-register-handler "test.event" (lambda (_e _d)))
    (opencode-sse--process-line conn "data: {\"type\":\"test.event\",\"a\":1}")
    (should (equal (opencode-sse--read-state conn :data)
                   "{\"type\":\"test.event\",\"a\":1}"))))

(ert-deftest test-opencode-sse/process-chunk-complete-event ()
  "A complete SSE event dispatches to the handler."
  (let ((opencode-sse--handlers nil)
        (dispatched nil)
        (conn (opencode-connection-create)))
    (opencode-sse--initialize-state conn)
    (opencode-sse-register-handler
     "session.created"
     (lambda (_event data)
       (setq dispatched data)))
    (opencode-sse--process-chunk
     conn
     "data: {\"type\":\"session.created\",\"value\":42}\n\n")
    (should dispatched)
    (should (equal (alist-get 'value dispatched) 42))))

(ert-deftest test-opencode-sse/process-chunk-split-across-chunks ()
  "An event split across two chunks is assembled correctly."
  (let ((opencode-sse--handlers nil)
        (dispatched nil)
        (conn (opencode-connection-create)))
    (opencode-sse--initialize-state conn)
    (opencode-sse-register-handler
     "msg.update"
     (lambda (_event data)
       (setq dispatched data)))
    (opencode-sse--process-chunk conn "data: {\"type\":\"msg.up")
    (should (null dispatched))
    (opencode-sse--process-chunk conn "date\",\"x\":1}\n\n")
    (should dispatched)
    (should (equal (alist-get 'x dispatched) 1))))

(ert-deftest test-opencode-sse/process-chunk-skips-unhandled-events ()
  "Events without registered handlers are skipped efficiently."
  (let ((opencode-sse--handlers nil)
        (dispatched nil)
        (conn (opencode-connection-create)))
    (opencode-sse--initialize-state conn)
    ;; No handler registered for "unknown.event"
    (opencode-sse--process-chunk
     conn
     "data: {\"type\":\"unknown.event\",\"data\":\"large payload\"}\n\n")
    ;; State should be clean after the event
    (should (null (opencode-sse--read-state conn :data)))
    (should (null (opencode-sse--read-state conn :skipping)))))

(ert-deftest test-opencode-sse/skip-fast-path-discards-subsequent-chunks ()
  "Subsequent chunks of a skipped event are discarded without splitting."
  (let ((opencode-sse--handlers nil)
        (conn (opencode-connection-create)))
    (opencode-sse--initialize-state conn)
    ;; First chunk: triggers skip on an unhandled event type.
    ;; No terminating \n\n -- the event continues.
    (opencode-sse--process-chunk
     conn
     "data: {\"type\":\"session.diff\",\"patch\":[{\"op\":\"replace\"\n")
    (should (opencode-sse--read-state conn :skipping))
    ;; :buffer is "\n" (seeded so the fast path can detect a boundary
    ;; that starts at the beginning of the very next chunk).
    (should (equal (opencode-sse--read-state conn :buffer) "\n"))
    ;; Subsequent chunks are discarded entirely by the fast path.
    (opencode-sse--process-chunk conn ",\"path\":\"/files\",\"value\":\"")
    (should (opencode-sse--read-state conn :skipping))
    (should (null (opencode-sse--read-state conn :data)))
    (opencode-sse--process-chunk conn "...more huge diff data...")
    (should (opencode-sse--read-state conn :skipping))))

(ert-deftest test-opencode-sse/skip-fast-path-resumes-on-boundary ()
  "Fast path detects event boundary and processes the next event."
  (let ((opencode-sse--handlers nil)
        (dispatched nil)
        (conn (opencode-connection-create)))
    (opencode-sse--initialize-state conn)
    (opencode-sse-register-handler
     "message.created"
     (lambda (_event data)
       (setq dispatched data)))
    ;; First chunk: triggers skip.
    (opencode-sse--process-chunk
     conn
     "data: {\"type\":\"session.diff\",\"big\":true}\n")
    (should (opencode-sse--read-state conn :skipping))
    ;; Second chunk: contains the boundary (\n\n) ending the skipped
    ;; event, followed by the start of a handled event.
    (opencode-sse--process-chunk
     conn
     "\ndata: {\"type\":\"message.created\",\"id\":7}\n\n")
    (should-not (opencode-sse--read-state conn :skipping))
    (should dispatched)
    (should (equal (alist-get 'id dispatched) 7))))

(ert-deftest test-opencode-sse/skip-fast-path-boundary-only-chunk ()
  "A chunk containing just the event boundary correctly ends skip."
  (let ((opencode-sse--handlers nil)
        (conn (opencode-connection-create)))
    (opencode-sse--initialize-state conn)
    ;; Enter skip mode.
    (opencode-sse--process-chunk
     conn
     "data: {\"type\":\"session.diff\",\"x\":1}\n")
    (should (opencode-sse--read-state conn :skipping))
    ;; Chunk with just the boundary.
    (opencode-sse--process-chunk conn "\n")
    ;; Skip should be cleared.
    (should-not (opencode-sse--read-state conn :skipping))
    (should (null (opencode-sse--read-state conn :data)))))

(ert-deftest test-opencode-sse/process-chunk-strips-cr ()
  "Carriage returns in SSE lines are stripped."
  (let ((opencode-sse--handlers nil)
        (dispatched nil)
        (conn (opencode-connection-create)))
    (opencode-sse--initialize-state conn)
    (opencode-sse-register-handler
     "cr.test"
     (lambda (_event data)
       (setq dispatched data)))
    (opencode-sse--process-chunk
     conn
     "data: {\"type\":\"cr.test\",\"ok\":true}\r\n\r\n")
    (should dispatched)))

(ert-deftest test-opencode-sse/process-line-strips-leading-space ()
  "Per SSE spec, strip at most one leading space from data value."
  (let ((conn (opencode-connection-create))
        (opencode-sse--handlers nil))
    (opencode-sse--initialize-state conn)
    (opencode-sse-register-handler "sp.test" (lambda (_e _d)))
    (opencode-sse--process-line conn "data:  {\"type\":\"sp.test\"}")
    ;; One leading space stripped, one remains
    (should (equal (opencode-sse--read-state conn :data)
                   " {\"type\":\"sp.test\"}"))))

;;; handler registration

(ert-deftest test-opencode-sse/register-and-dispatch ()
  "Register a handler and dispatch to it."
  (let ((opencode-sse--handlers nil)
        (result nil))
    (opencode-sse-register-handler
     "test.event"
     (lambda (_event data) (setq result data)))
    (opencode-sse--dispatch "test.event" '((key . "value")))
    (should (equal (alist-get 'key result) "value"))))

(ert-deftest test-opencode-sse/unregister-handlers ()
  "Unregister removes all handlers for an event."
  (let ((opencode-sse--handlers nil)
        (called nil))
    (opencode-sse-register-handler
     "remove.me"
     (lambda (_event _data) (setq called t)))
    (opencode-sse-unregister-handlers "remove.me")
    (opencode-sse--dispatch "remove.me" nil)
    (should (null called))))

(ert-deftest test-opencode-sse/duplicate-handler-not-added ()
  "Registering the same handler twice does not duplicate it."
  (let ((opencode-sse--handlers nil)
        (count 0))
    (let ((handler (lambda (_event _data) (setq count (1+ count)))))
      (opencode-sse-register-handler "dup.test" handler)
      (opencode-sse-register-handler "dup.test" handler)
      (opencode-sse--dispatch "dup.test" nil)
      (should (= count 1)))))

(provide 'emacs-opencode-sse-test)

;;; emacs-opencode-sse-test.el ends here
