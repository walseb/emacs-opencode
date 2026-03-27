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

;;; strip-data-prefix

(ert-deftest test-opencode-sse/strip-data-prefix ()
  "Strip \"data: \" prefix from a string."
  (should (equal (opencode-sse--strip-data-prefix
                  "data: {\"type\":\"foo\"}")
                 "{\"type\":\"foo\"}"))
  ;; No prefix — return unchanged.
  (should (equal (opencode-sse--strip-data-prefix "{\"type\":\"foo\"}")
                 "{\"type\":\"foo\"}")))

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
    (should (null (opencode-sse--read-state conn :fragments)))
    (opencode-sse--write-state conn :fragments '("partial"))
    (should (equal (opencode-sse--read-state conn :fragments) '("partial")))))

(ert-deftest test-opencode-sse/clear-event ()
  "Clear event resets fragments and trailing-nl."
  (let ((conn (opencode-connection-create)))
    (opencode-sse--initialize-state conn)
    (opencode-sse--write-state conn :fragments '("some data"))
    (opencode-sse--write-state conn :trailing-nl t)
    (opencode-sse--clear-event conn)
    (should (null (opencode-sse--read-state conn :fragments)))
    (should (null (opencode-sse--read-state conn :trailing-nl)))))

;;; find-boundary

(ert-deftest test-opencode-sse/find-boundary-within-chunk ()
  "Find boundary within a single chunk."
  (let ((conn (opencode-connection-create)))
    (opencode-sse--initialize-state conn)
    ;; Returns (PRE-END . REST-START) cons.
    (should (equal (opencode-sse--find-boundary conn "data: {}\n\n") '(8 . 10)))
    (should (null (opencode-sse--find-boundary conn "data: {}\n")))))

(ert-deftest test-opencode-sse/find-boundary-split-across-chunks ()
  "Detect boundary split across two chunks via trailing-nl flag."
  (let ((conn (opencode-connection-create)))
    (opencode-sse--initialize-state conn)
    ;; Previous chunk ended with \n.
    (opencode-sse--write-state conn :trailing-nl t)
    ;; This chunk starts with \n — split boundary: (0 . 1).
    (should (equal (opencode-sse--find-boundary conn "\nrest") '(0 . 1)))
    ;; No trailing-nl — no boundary even though chunk starts with \n.
    (opencode-sse--write-state conn :trailing-nl nil)
    (should (null (opencode-sse--find-boundary conn "\nrest")))))

(ert-deftest test-opencode-sse/find-boundary-empty-chunk ()
  "Empty chunk returns nil."
  (let ((conn (opencode-connection-create)))
    (opencode-sse--initialize-state conn)
    (should (null (opencode-sse--find-boundary conn "")))))

;;; process-chunk — complete events

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

(ert-deftest test-opencode-sse/process-chunk-boundary-split-across-chunks ()
  "Event boundary \\n\\n split across two chunks is detected."
  (let ((opencode-sse--handlers nil)
        (dispatched nil)
        (conn (opencode-connection-create)))
    (opencode-sse--initialize-state conn)
    (opencode-sse-register-handler
     "split.test"
     (lambda (_event data)
       (setq dispatched data)))
    ;; First chunk: data line ending with \n (first \n of boundary).
    (opencode-sse--process-chunk
     conn "data: {\"type\":\"split.test\",\"ok\":true}\n")
    (should (null dispatched))
    ;; Second chunk starts with \n (second \n of boundary).
    (opencode-sse--process-chunk conn "\n")
    (should dispatched)
    (should (equal (alist-get 'ok dispatched) t))))

(ert-deftest test-opencode-sse/process-chunk-two-events-one-chunk ()
  "Two complete events in a single chunk both dispatch."
  (let ((opencode-sse--handlers nil)
        (results nil)
        (conn (opencode-connection-create)))
    (opencode-sse--initialize-state conn)
    (opencode-sse-register-handler
     "ev.one"
     (lambda (_event data) (push (cons 'one data) results)))
    (opencode-sse-register-handler
     "ev.two"
     (lambda (_event data) (push (cons 'two data) results)))
    (opencode-sse--process-chunk
     conn
     (concat "data: {\"type\":\"ev.one\",\"n\":1}\n\n"
             "data: {\"type\":\"ev.two\",\"n\":2}\n\n"))
    (should (= (length results) 2))
    ;; Results are pushed, so newest first.
    (should (equal (alist-get 'n (cdr (nth 0 results))) 2))
    (should (equal (alist-get 'n (cdr (nth 1 results))) 1))))

;;; process-chunk — unhandled events

(ert-deftest test-opencode-sse/unhandled-event-not-dispatched ()
  "Events without registered handlers are not dispatched."
  (let ((opencode-sse--handlers nil)
        (conn (opencode-connection-create)))
    (opencode-sse--initialize-state conn)
    ;; No handler registered for "unknown.event"
    (opencode-sse--process-chunk
     conn
     "data: {\"type\":\"unknown.event\",\"data\":\"large payload\"}\n\n")
    ;; State should be clean after the event.
    (should (null (opencode-sse--read-state conn :fragments)))))

(ert-deftest test-opencode-sse/unhandled-event-multi-chunk ()
  "An unhandled event split across chunks accumulates and is discarded."
  (let ((opencode-sse--handlers nil)
        (conn (opencode-connection-create)))
    (opencode-sse--initialize-state conn)
    ;; No handler registered for "session.diff".
    (opencode-sse--process-chunk
     conn "data: {\"type\":\"session.diff\",\"patch\":[{\"op\":\"replace\"")
    ;; Fragments accumulate (no skip mode to discard them).
    (should (opencode-sse--read-state conn :fragments))
    ;; More chunks.
    (opencode-sse--process-chunk conn ",\"path\":\"/files\",\"value\":\"")
    (opencode-sse--process-chunk conn "...more data...")
    ;; Boundary ends it — fragments cleared, no dispatch.
    (opencode-sse--process-chunk conn "\"}\n\n")
    (should (null (opencode-sse--read-state conn :fragments)))))

(ert-deftest test-opencode-sse/unhandled-event-then-handled ()
  "After an unhandled event, subsequent handled events dispatch correctly."
  (let ((opencode-sse--handlers nil)
        (dispatched nil)
        (conn (opencode-connection-create)))
    (opencode-sse--initialize-state conn)
    (opencode-sse-register-handler
     "message.created"
     (lambda (_event data)
       (setq dispatched data)))
    ;; Unhandled event with split boundary.
    (opencode-sse--process-chunk
     conn "data: {\"type\":\"session.diff\",\"big\":true}\n")
    ;; Boundary for unhandled event + start of handled event.
    (opencode-sse--process-chunk
     conn "\ndata: {\"type\":\"message.created\",\"id\":7}\n\n")
    (should dispatched)
    (should (equal (alist-get 'id dispatched) 7))))

(ert-deftest test-opencode-sse/unhandled-event-large-payload ()
  "A large unhandled event with many chunks is discarded at finalization."
  (let ((opencode-sse--handlers nil)
        (conn (opencode-connection-create)))
    (opencode-sse--initialize-state conn)
    ;; Simulate many chunks for an unhandled event.
    (opencode-sse--process-chunk conn "data: {\"type\":\"session.diff\",\"data\":\"")
    (dotimes (_ 100)
      (opencode-sse--process-chunk conn (make-string 1024 ?x)))
    ;; Boundary ends it.
    (opencode-sse--process-chunk conn "\"}\n\n")
    ;; State is clean.
    (should (null (opencode-sse--read-state conn :fragments)))))

(ert-deftest test-opencode-sse/multiple-events-after-unhandled ()
  "After an unhandled event, multiple subsequent events dispatch correctly."
  (let ((opencode-sse--handlers nil)
        (results nil)
        (conn (opencode-connection-create)))
    (opencode-sse--initialize-state conn)
    (opencode-sse-register-handler
     "good.event"
     (lambda (_event data) (push data results)))
    ;; Unhandled event, then two handled events in one chunk.
    (opencode-sse--process-chunk
     conn
     (concat "data: {\"type\":\"skip.me\"}\n\n"
             "data: {\"type\":\"good.event\",\"n\":1}\n\n"
             "data: {\"type\":\"good.event\",\"n\":2}\n\n"))
    (should (= (length results) 2))
    (should (equal (alist-get 'n (nth 0 results)) 2))
    (should (equal (alist-get 'n (nth 1 results)) 1))))

;;; process-chunk — fragment accumulation

(ert-deftest test-opencode-sse/chunk-accumulation-no-newline ()
  "Chunks without newlines accumulate as a reversed fragment list."
  (let ((opencode-sse--handlers nil)
        (conn (opencode-connection-create)))
    (opencode-sse--initialize-state conn)
    (opencode-sse-register-handler "msg.updated" (lambda (_e _d)))
    ;; Simulate a large data line arriving in multiple chunks.
    (opencode-sse--process-chunk conn "data: {\"type\":\"msg")
    (should (equal (opencode-sse--read-state conn :fragments)
                   '("data: {\"type\":\"msg")))
    (opencode-sse--process-chunk conn ".updated\",\"big\":\"")
    (should (equal (opencode-sse--read-state conn :fragments)
                   '(".updated\",\"big\":\"" "data: {\"type\":\"msg")))
    (opencode-sse--process-chunk conn "payload\"}")
    (should (equal (opencode-sse--read-state conn :fragments)
                   '("payload\"}" ".updated\",\"big\":\"" "data: {\"type\":\"msg")))))

(ert-deftest test-opencode-sse/chunk-accumulation-then-boundary ()
  "Accumulated chunks are joined and dispatched when boundary arrives."
  (let ((opencode-sse--handlers nil)
        (dispatched nil)
        (conn (opencode-connection-create)))
    (opencode-sse--initialize-state conn)
    (opencode-sse-register-handler
     "msg.updated"
     (lambda (_event data) (setq dispatched data)))
    ;; Three chunks without newlines.
    (opencode-sse--process-chunk conn "data: {\"type\":\"msg")
    (opencode-sse--process-chunk conn ".updated\",\"x\":")
    (opencode-sse--process-chunk conn "99}")
    (should (null dispatched))
    ;; Boundary to finalize the event.
    (opencode-sse--process-chunk conn "\n\n")
    (should dispatched)
    (should (equal (alist-get 'x dispatched) 99))))

(ert-deftest test-opencode-sse/chunk-accumulation-many-chunks ()
  "A large number of small chunks accumulate correctly."
  (let ((opencode-sse--handlers nil)
        (dispatched nil)
        (conn (opencode-connection-create)))
    (opencode-sse--initialize-state conn)
    (opencode-sse-register-handler
     "big.event"
     (lambda (_event data) (setq dispatched data)))
    (opencode-sse--process-chunk conn "data: {\"type\":\"big.event\",\"v\":\"")
    (dotimes (_ 100)
      (opencode-sse--process-chunk conn "x"))
    (opencode-sse--process-chunk conn "\"}\n\n")
    (should dispatched)
    (should (= (length (alist-get 'v dispatched)) 100))))

(ert-deftest test-opencode-sse/chunk-boundary-in-middle-of-chunk ()
  "A chunk containing the boundary in the middle correctly splits."
  (let ((opencode-sse--handlers nil)
        (dispatched nil)
        (conn (opencode-connection-create)))
    (opencode-sse--initialize-state conn)
    (opencode-sse-register-handler
     "mid.test"
     (lambda (_event data) (setq dispatched data)))
    ;; First chunk has no newline.
    (opencode-sse--process-chunk conn "data: {\"type\":\"mid.t")
    (should (equal (opencode-sse--read-state conn :fragments)
                   '("data: {\"type\":\"mid.t")))
    ;; Second chunk contains boundary mid-chunk, plus start of next data.
    (opencode-sse--process-chunk conn "est\",\"a\":1}\n\ndata: {\"type\":\"mid.t")
    ;; The first event should have dispatched.
    (should dispatched)
    (should (equal (alist-get 'a dispatched) 1))
    ;; The remainder after the boundary should start accumulating.
    (should (equal (opencode-sse--read-state conn :fragments)
                   '("data: {\"type\":\"mid.t")))))

(ert-deftest test-opencode-sse/chunk-boundary-exactly-at-end ()
  "State is clean when a chunk ends exactly at the boundary."
  (let ((opencode-sse--handlers nil)
        (conn (opencode-connection-create)))
    (opencode-sse--initialize-state conn)
    (opencode-sse-register-handler "exact.test" (lambda (_e _d)))
    (opencode-sse--process-chunk conn "data: {\"type\":\"exact.test\"}\n\n")
    (should (null (opencode-sse--read-state conn :fragments)))
    (should (null (opencode-sse--read-state conn :trailing-nl)))))

;;; trailing-nl flag

(ert-deftest test-opencode-sse/trailing-nl-flag-set-correctly ()
  "The trailing-nl flag tracks whether the last chunk ended with newline."
  (let ((opencode-sse--handlers nil)
        (conn (opencode-connection-create)))
    (opencode-sse--initialize-state conn)
    (opencode-sse-register-handler "trail.test" (lambda (_e _d)))
    ;; Chunk without trailing newline.
    (opencode-sse--process-chunk conn "data: {\"type\":\"trail.test\"")
    (should-not (opencode-sse--read-state conn :trailing-nl))
    ;; Chunk with trailing newline but no boundary.
    (opencode-sse--process-chunk conn ",\"x\":1}\n")
    (should (opencode-sse--read-state conn :trailing-nl))))

(ert-deftest test-opencode-sse/trailing-nl-not-false-positive ()
  "A chunk that does not end with \\n has trailing-nl unset."
  (let ((opencode-sse--handlers nil)
        (conn (opencode-connection-create)))
    (opencode-sse--initialize-state conn)
    (opencode-sse-register-handler "fp.test" (lambda (_e _d)))
    (opencode-sse--process-chunk conn "data: {\"type\":\"fp.test\",\"x\":1}")
    (should-not (opencode-sse--read-state conn :trailing-nl))))

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

;;; Edge cases

(ert-deftest test-opencode-sse/event-with-no-handler-not-parsed ()
  "Events with no handler are not JSON-parsed at finalize."
  (let ((opencode-sse--handlers nil)
        (conn (opencode-connection-create)))
    (opencode-sse--initialize-state conn)
    (opencode-sse-register-handler "other.event" (lambda (_e _d)))
    ;; Feed an event whose type is "no.handler" — no handler registered.
    (opencode-sse--process-chunk
     conn
     "data: {\"type\":\"no.handler\",\"x\":1}\n\n")
    ;; State is clean and no error was thrown.
    (should (null (opencode-sse--read-state conn :fragments)))))

(ert-deftest test-opencode-sse/boundary-no-trailing-nl ()
  "Boundary in chunk when prev chunk had no trailing newline."
  (let ((opencode-sse--handlers nil)
        (conn (opencode-connection-create)))
    (opencode-sse--initialize-state conn)
    (opencode-sse-register-handler "bn.test" (lambda (_e _d)))
    ;; Chunk does not end with \n.
    (opencode-sse--process-chunk conn "data: {\"type\":\"bn.test\",\"x\":1}")
    (should-not (opencode-sse--read-state conn :trailing-nl))
    ;; Next chunk has the full boundary.
    (opencode-sse--process-chunk conn "\n\n")
    (should (null (opencode-sse--read-state conn :fragments)))))

(ert-deftest test-opencode-sse/handled-event-multi-chunk-no-newlines ()
  "A handled event arriving without newlines accumulates and dispatches."
  (let ((opencode-sse--handlers nil)
        (dispatched nil)
        (conn (opencode-connection-create)))
    (opencode-sse--initialize-state conn)
    (opencode-sse-register-handler
     "msg.updated"
     (lambda (_event data) (setq dispatched data)))
    (opencode-sse--process-chunk conn "data: {\"type\":\"msg.updated\",\"x\":")
    (should (opencode-sse--read-state conn :fragments))
    (opencode-sse--process-chunk conn "42}")
    (opencode-sse--process-chunk conn "\n\n")
    (should dispatched)
    (should (= (alist-get 'x dispatched) 42))))

(provide 'emacs-opencode-sse-test)

;;; emacs-opencode-sse-test.el ends here
