;;; emacs-opencode-sse-profile-test.el --- Tests for SSE profiling  -*- lexical-binding: t; -*-

(require 'ert)
(require 'emacs-opencode-sse-profile)
(require 'emacs-opencode-sse)

;;; format helpers

(ert-deftest test-opencode-sse-profile/format-ms-sub-millisecond ()
  "Sub-millisecond values use two decimal places."
  (should (equal (opencode-sse-profile--format-ms 0.42) "0.42ms")))

(ert-deftest test-opencode-sse-profile/format-ms-normal ()
  "Normal millisecond values use one decimal place."
  (should (equal (opencode-sse-profile--format-ms 12.3) "12.3ms")))

(ert-deftest test-opencode-sse-profile/format-ms-seconds ()
  "Large values are shown in seconds."
  (should (equal (opencode-sse-profile--format-ms 1500.0) "1.50s")))

(ert-deftest test-opencode-sse-profile/format-bytes-small ()
  "Small byte counts use B suffix."
  (should (equal (opencode-sse-profile--format-bytes 512) "512B")))

(ert-deftest test-opencode-sse-profile/format-bytes-kb ()
  "Kilobyte values use KB suffix."
  (should (equal (opencode-sse-profile--format-bytes 2048) "2.0KB")))

(ert-deftest test-opencode-sse-profile/format-bytes-mb ()
  "Megabyte values use MB suffix."
  (should (equal (opencode-sse-profile--format-bytes (* 2 1024 1024)) "2.0MB")))

;;; safe-div

(ert-deftest test-opencode-sse-profile/safe-div-zero ()
  "Division by zero returns 0.0."
  (should (= (opencode-sse-profile--safe-div 42 0) 0.0)))

(ert-deftest test-opencode-sse-profile/safe-div-normal ()
  "Normal division works correctly."
  (should (= (opencode-sse-profile--safe-div 10 4) 2.5)))

;;; ring buffer

(ert-deftest test-opencode-sse-profile/ring-insertion ()
  "Records are inserted into the ring buffer."
  (let ((opencode-sse-profile--ring nil)
        (opencode-sse-profile-ring-size 5))
    (opencode-sse-profile--ensure-ring)
    (should (ring-empty-p opencode-sse-profile--ring))
    (opencode-sse-profile--record-event '(:event-type "test" :total-ms 1.0))
    (should (= (ring-length opencode-sse-profile--ring) 1))
    (let ((record (ring-ref opencode-sse-profile--ring 0)))
      (should (equal (plist-get record :event-type) "test")))))

(ert-deftest test-opencode-sse-profile/ring-bounded ()
  "Ring buffer does not exceed its configured size."
  (let ((opencode-sse-profile--ring nil)
        (opencode-sse-profile-ring-size 3))
    (opencode-sse-profile--ensure-ring)
    (dotimes (i 10)
      (opencode-sse-profile--record-event
       (list :event-type (format "event-%d" i))))
    (should (= (ring-length opencode-sse-profile--ring) 3))))

;;; aggregates

(ert-deftest test-opencode-sse-profile/aggregate-creation ()
  "A new aggregate is created with zeroed fields."
  (let ((opencode-sse-profile--aggregates (make-hash-table :test 'equal)))
    (let ((agg (opencode-sse-profile--get-aggregate "test.event")))
      (should (= (plist-get agg :count) 0))
      (should (= (plist-get agg :total-ms) 0.0))
      (should (= (plist-get agg :max-ms) 0.0)))))

(ert-deftest test-opencode-sse-profile/aggregate-update ()
  "Aggregates accumulate values correctly."
  (let ((opencode-sse-profile--aggregates (make-hash-table :test 'equal)))
    (opencode-sse-profile--update-aggregate
     "test.event" :total-ms 10.0 :parse-ms 3.0 :dispatch-ms 5.0
     :render-ms 2.0 :bytes 1024)
    (opencode-sse-profile--update-aggregate
     "test.event" :total-ms 20.0 :parse-ms 7.0 :dispatch-ms 10.0
     :render-ms 3.0 :bytes 2048)
    (let ((agg (gethash "test.event" opencode-sse-profile--aggregates)))
      (should (= (plist-get agg :count) 2))
      (should (= (plist-get agg :total-ms) 30.0))
      (should (= (plist-get agg :max-ms) 20.0))
      (should (= (plist-get agg :parse-total-ms) 10.0))
      (should (= (plist-get agg :dispatch-total-ms) 15.0))
      (should (= (plist-get agg :render-total-ms) 5.0))
      (should (= (plist-get agg :bytes-total) 3072)))))

(ert-deftest test-opencode-sse-profile/skip-recording ()
  "Skipped events are recorded in aggregates and ring."
  (let ((opencode-sse-profile--aggregates (make-hash-table :test 'equal))
        (opencode-sse-profile--ring nil)
        (opencode-sse-profile-ring-size 10))
    (opencode-sse-profile--record-skip "session.diff" 50000)
    (let ((agg (gethash "session.diff" opencode-sse-profile--aggregates)))
      (should (= (plist-get agg :skip-count) 1))
      (should (= (plist-get agg :skip-bytes-total) 50000)))
    (let ((record (ring-ref opencode-sse-profile--ring 0)))
      (should (eq (plist-get record :skipped) t))
      (should (= (plist-get record :bytes) 50000)))))

;;; chunk stats

(ert-deftest test-opencode-sse-profile/chunk-recording ()
  "Chunk stats are accumulated correctly."
  (let ((opencode-sse-profile--chunk-stats
         (list :count 0 :total-ms 0.0 :max-ms 0.0
               :bytes-total 0))
        (opencode-sse-profile--last-chunk-time nil)
        (opencode-sse-profile--inter-chunk-max-ms 0.0)
        (opencode-sse-profile--inter-chunk-total-ms 0.0)
        (opencode-sse-profile--inter-chunk-count 0)
        (opencode-sse-profile--slow-gaps nil)
        (opencode-sse-profile-slow-gap-threshold-ms 50.0))
    (opencode-sse-profile--record-chunk 1.5 256)
    (opencode-sse-profile--record-chunk 0.5 128)
    (should (= (plist-get opencode-sse-profile--chunk-stats :count) 2))
    (should (= (plist-get opencode-sse-profile--chunk-stats :max-ms) 1.5))
    (should (= (plist-get opencode-sse-profile--chunk-stats :bytes-total) 384))))

;;; slow gap recording

(ert-deftest test-opencode-sse-profile/slow-gap-recorded ()
  "Gaps above threshold are recorded in the slow gaps ring."
  (let ((opencode-sse-profile--slow-gaps nil)
        (opencode-sse-profile-slow-gap-ring-size 10)
        (opencode-sse-profile-slow-gap-threshold-ms 50.0))
    (opencode-sse-profile--record-slow-gap 200.0)
    (should (= (ring-length opencode-sse-profile--slow-gaps) 1))
    (let ((record (ring-ref opencode-sse-profile--slow-gaps 0)))
      (should (= (plist-get record :gap-ms) 200.0)))))

(ert-deftest test-opencode-sse-profile/slow-gap-below-threshold ()
  "Gaps below threshold are not recorded as slow gaps."
  (let ((opencode-sse-profile--chunk-stats
         (list :count 0 :total-ms 0.0 :max-ms 0.0
               :bytes-total 0))
        (opencode-sse-profile--last-chunk-time (- (float-time) 0.01))
        (opencode-sse-profile--inter-chunk-max-ms 0.0)
        (opencode-sse-profile--inter-chunk-total-ms 0.0)
        (opencode-sse-profile--inter-chunk-count 0)
        (opencode-sse-profile--slow-gaps nil)
        (opencode-sse-profile-slow-gap-threshold-ms 50.0)
        (opencode-sse-profile-slow-gap-ring-size 10))
    ;; 10ms gap — below 50ms threshold
    (opencode-sse-profile--record-chunk 0.1 100)
    (should (or (null opencode-sse-profile--slow-gaps)
                (ring-empty-p opencode-sse-profile--slow-gaps)))))

(ert-deftest test-opencode-sse-profile/slow-gap-between-events ()
  "Slow gap records timestamp and gap duration."
  (let ((opencode-sse-profile--slow-gaps nil)
        (opencode-sse-profile-slow-gap-ring-size 10))
    (opencode-sse-profile--record-slow-gap 500.0)
    (let ((record (ring-ref opencode-sse-profile--slow-gaps 0)))
      (should (= (plist-get record :gap-ms) 500.0))
      (should (numberp (plist-get record :timestamp))))))

;;; render time accumulation

(ert-deftest test-opencode-sse-profile/render-time-accumulation ()
  "Render times accumulate within a dispatch cycle."
  (let ((opencode-sse-profile-enabled t)
        (opencode-sse-profile--current-render-ms nil))
    (opencode-sse-profile-add-render-time 5.0)
    (should (= opencode-sse-profile--current-render-ms 5.0))
    (opencode-sse-profile-add-render-time 3.0)
    (should (= opencode-sse-profile--current-render-ms 8.0))))

(ert-deftest test-opencode-sse-profile/render-time-disabled ()
  "Render time recording is a no-op when profiling is disabled."
  (let ((opencode-sse-profile-enabled nil)
        (opencode-sse-profile--current-render-ms nil))
    (opencode-sse-profile-add-render-time 5.0)
    (should (null opencode-sse-profile--current-render-ms))))

;;; reset

(ert-deftest test-opencode-sse-profile/reset-clears-all ()
  "Reset clears all profiling state."
  (let ((opencode-sse-profile--ring nil)
        (opencode-sse-profile-ring-size 10)
        (opencode-sse-profile--aggregates (make-hash-table :test 'equal))
        (opencode-sse-profile--chunk-stats
         (list :count 5 :total-ms 10.0 :max-ms 3.0
               :bytes-total 999))
        (opencode-sse-profile--last-chunk-time 12345.0)
        (opencode-sse-profile--inter-chunk-max-ms 50.0)
        (opencode-sse-profile--inter-chunk-total-ms 100.0)
        (opencode-sse-profile--inter-chunk-count 10)
        (opencode-sse-profile--slow-gaps nil)
        (opencode-sse-profile-slow-gap-ring-size 10)
        (opencode-sse-profile--current-render-ms 7.0))
    (opencode-sse-profile--record-event '(:test t))
    (opencode-sse-profile--update-aggregate "foo" :total-ms 5.0)
    (opencode-sse-profile--record-slow-gap 200.0)
    (opencode-sse-profile-reset)
    (should (null opencode-sse-profile--ring))
    (should (= (hash-table-count opencode-sse-profile--aggregates) 0))
    (should (= (plist-get opencode-sse-profile--chunk-stats :count) 0))
    (should (null opencode-sse-profile--last-chunk-time))
    (should (= opencode-sse-profile--inter-chunk-max-ms 0.0))
    (should (= opencode-sse-profile--inter-chunk-count 0))
    (should (null opencode-sse-profile--slow-gaps))
    (should (null opencode-sse-profile--current-render-ms))))

;;; integration: profiling through SSE pipeline

(ert-deftest test-opencode-sse-profile/integration-handled-event ()
  "A handled SSE event records profiling data end-to-end."
  (let ((opencode-sse-profile-enabled t)
        (opencode-sse-profile--ring nil)
        (opencode-sse-profile-ring-size 100)
        (opencode-sse-profile--aggregates (make-hash-table :test 'equal))
        (opencode-sse-profile--chunk-stats
         (list :count 0 :total-ms 0.0 :max-ms 0.0
               :bytes-total 0))
        (opencode-sse-profile--last-chunk-time nil)
        (opencode-sse-profile--inter-chunk-max-ms 0.0)
        (opencode-sse-profile--inter-chunk-total-ms 0.0)
        (opencode-sse-profile--inter-chunk-count 0)
        (opencode-sse-profile--slow-gaps nil)
        (opencode-sse-profile-slow-gap-threshold-ms 50.0)
        (opencode-sse-profile-slow-gap-ring-size 100)
        (opencode-sse-profile--current-render-ms nil)
        (opencode-sse--handlers nil)
        (dispatched nil)
        (conn (opencode-connection-create)))
    (opencode-sse--initialize-state conn)
    (opencode-sse-register-handler
     "profile.test"
     (lambda (_event data _meta) (setq dispatched data)))
    (opencode-sse--process-chunk
     conn "data: {\"type\":\"profile.test\",\"v\":1}\n\n")
    ;; Handler was called
    (should dispatched)
    (should (= (alist-get 'v dispatched) 1))
    ;; Chunk stats recorded
    (should (>= (plist-get opencode-sse-profile--chunk-stats :count) 1))
    ;; Event recorded in ring
    (should (not (ring-empty-p opencode-sse-profile--ring)))
    (let ((record (ring-ref opencode-sse-profile--ring 0)))
      (should (equal (plist-get record :event-type) "profile.test"))
      (should (numberp (plist-get record :total-ms)))
      (should (numberp (plist-get record :parse-ms)))
      (should (numberp (plist-get record :dispatch-ms))))
    ;; Aggregate recorded
    (let ((agg (gethash "profile.test" opencode-sse-profile--aggregates)))
      (should agg)
      (should (= (plist-get agg :count) 1)))))

(ert-deftest test-opencode-sse-profile/integration-skipped-event ()
  "A skipped SSE event records skip profiling data."
  (let ((opencode-sse-profile-enabled t)
        (opencode-sse-profile--ring nil)
        (opencode-sse-profile-ring-size 100)
        (opencode-sse-profile--aggregates (make-hash-table :test 'equal))
        (opencode-sse-profile--chunk-stats
         (list :count 0 :total-ms 0.0 :max-ms 0.0
               :bytes-total 0))
        (opencode-sse-profile--last-chunk-time nil)
        (opencode-sse-profile--inter-chunk-max-ms 0.0)
        (opencode-sse-profile--inter-chunk-total-ms 0.0)
        (opencode-sse-profile--inter-chunk-count 0)
        (opencode-sse-profile--slow-gaps nil)
        (opencode-sse-profile-slow-gap-threshold-ms 50.0)
        (opencode-sse-profile-slow-gap-ring-size 100)
        (opencode-sse-profile--current-render-ms nil)
        (opencode-sse--handlers nil)
        (conn (opencode-connection-create)))
    (opencode-sse--initialize-state conn)
    ;; No handler registered — event will be skipped
    (opencode-sse--process-chunk
     conn "data: {\"type\":\"session.diff\",\"big\":\"payload\"}\n\n")
    ;; Skip recorded in aggregates
    (let ((agg (gethash "session.diff" opencode-sse-profile--aggregates)))
      (should agg)
      (should (= (plist-get agg :skip-count) 1))
      (should (> (plist-get agg :skip-bytes-total) 0)))
    ;; Skip recorded in ring
    (should (not (ring-empty-p opencode-sse-profile--ring)))
    (let ((record (ring-ref opencode-sse-profile--ring 0)))
      (should (eq (plist-get record :skipped) t))
      (should (equal (plist-get record :event-type) "session.diff")))))

(ert-deftest test-opencode-sse-profile/integration-disabled ()
  "No profiling data is recorded when profiling is disabled."
  (let ((opencode-sse-profile-enabled nil)
        (opencode-sse-profile--ring nil)
        (opencode-sse-profile-ring-size 100)
        (opencode-sse-profile--aggregates (make-hash-table :test 'equal))
        (opencode-sse-profile--chunk-stats
         (list :count 0 :total-ms 0.0 :max-ms 0.0
               :bytes-total 0))
        (opencode-sse-profile--last-chunk-time nil)
        (opencode-sse-profile--inter-chunk-max-ms 0.0)
        (opencode-sse-profile--inter-chunk-total-ms 0.0)
        (opencode-sse-profile--inter-chunk-count 0)
        (opencode-sse-profile--slow-gaps nil)
        (opencode-sse-profile-slow-gap-threshold-ms 50.0)
        (opencode-sse-profile-slow-gap-ring-size 100)
        (opencode-sse-profile--current-render-ms nil)
        (opencode-sse--handlers nil)
        (dispatched nil)
        (conn (opencode-connection-create)))
    (opencode-sse--initialize-state conn)
    (opencode-sse-register-handler
     "quiet.test"
     (lambda (_event data _meta) (setq dispatched data)))
    (opencode-sse--process-chunk
     conn "data: {\"type\":\"quiet.test\",\"v\":1}\n\n")
    ;; Handler still called
    (should dispatched)
    ;; No profiling data
    (should (null opencode-sse-profile--ring))
    (should (= (hash-table-count opencode-sse-profile--aggregates) 0))
    (should (= (plist-get opencode-sse-profile--chunk-stats :count) 0))))

(ert-deftest test-opencode-sse-profile/report-no-crash ()
  "The report command doesn't error on empty data."
  (let ((opencode-sse-profile-enabled nil)
        (opencode-sse-profile--ring nil)
        (opencode-sse-profile--aggregates (make-hash-table :test 'equal))
        (opencode-sse-profile--chunk-stats
         (list :count 0 :total-ms 0.0 :max-ms 0.0
               :bytes-total 0))
        (opencode-sse-profile--last-chunk-time nil)
        (opencode-sse-profile--inter-chunk-max-ms 0.0)
        (opencode-sse-profile--inter-chunk-total-ms 0.0)
        (opencode-sse-profile--inter-chunk-count 0)
        (opencode-sse-profile--slow-gaps nil)
        (opencode-sse-profile-slow-gap-threshold-ms 50.0)
        (opencode-sse-profile-slow-gap-ring-size 10))
    (save-window-excursion
      (opencode-sse-profile-report)
      (should (get-buffer "*OpenCode SSE Profile*"))
      (kill-buffer "*OpenCode SSE Profile*"))))

(provide 'emacs-opencode-sse-profile-test)

;;; emacs-opencode-sse-profile-test.el ends here
