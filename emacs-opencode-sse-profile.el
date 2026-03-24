;;; emacs-opencode-sse-profile.el --- SSE performance profiling  -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'ring)

(defcustom opencode-sse-profile-enabled nil
  "When non-nil, collect SSE performance timing data."
  :type 'boolean
  :group 'emacs-opencode)

(defcustom opencode-sse-profile-ring-size 1000
  "Maximum number of event records to keep in the profile ring."
  :type 'integer
  :group 'emacs-opencode)

(defcustom opencode-sse-profile-slow-gap-threshold-ms 50.0
  "Inter-chunk gaps above this threshold are recorded as slow gaps."
  :type 'number
  :group 'emacs-opencode)

(defcustom opencode-sse-profile-slow-gap-ring-size 200
  "Maximum number of slow gap records to keep."
  :type 'integer
  :group 'emacs-opencode)

;;; Storage

(defvar opencode-sse-profile--ring nil
  "Ring buffer of recent event profile records.
Each record is a plist with timing and metadata.")

(defvar opencode-sse-profile--aggregates (make-hash-table :test 'equal)
  "Hash-table of aggregate stats keyed by event type.
Each value is a plist (:count :total-ms :max-ms :parse-total-ms
:parse-max-ms :dispatch-total-ms :dispatch-max-ms :render-total-ms
:render-max-ms :bytes-total :skip-count :skip-bytes-total).")

(defvar opencode-sse-profile--chunk-stats
  (list :count 0 :total-ms 0.0 :max-ms 0.0
        :bytes-total 0 :skip-chunks 0)
  "Aggregate stats for process-chunk calls.")

(defvar opencode-sse-profile--last-chunk-time nil
  "Wall-clock time of the last chunk arrival.")

(defvar opencode-sse-profile--inter-chunk-max-ms 0.0
  "Maximum inter-chunk gap observed in milliseconds.")

(defvar opencode-sse-profile--inter-chunk-total-ms 0.0
  "Total inter-chunk gap time in milliseconds.")

(defvar opencode-sse-profile--inter-chunk-count 0
  "Number of inter-chunk gap measurements.")

(defvar opencode-sse-profile--slow-gaps nil
  "Ring buffer of slow inter-chunk gap records.
Each record is a plist with :timestamp, :gap-ms, :in-flight-event,
:in-flight-bytes, and :skipping.")

;;; Time helper

(defsubst opencode-sse-profile--now ()
  "Return current wall-clock time as a float in seconds."
  (float-time))

(defsubst opencode-sse-profile--elapsed-ms (start)
  "Return milliseconds elapsed since START."
  (* 1000.0 (- (opencode-sse-profile--now) start)))

;;; Ring buffer

(defun opencode-sse-profile--ensure-ring ()
  "Ensure the profile ring buffer exists."
  (unless opencode-sse-profile--ring
    (setq opencode-sse-profile--ring
          (make-ring opencode-sse-profile-ring-size))))

(defun opencode-sse-profile--record-event (record)
  "Insert RECORD into the profile ring."
  (opencode-sse-profile--ensure-ring)
  (ring-insert opencode-sse-profile--ring record))

(defun opencode-sse-profile--ensure-slow-gaps-ring ()
  "Ensure the slow gaps ring buffer exists."
  (unless opencode-sse-profile--slow-gaps
    (setq opencode-sse-profile--slow-gaps
          (make-ring opencode-sse-profile-slow-gap-ring-size))))

(defun opencode-sse-profile--record-slow-gap (gap-ms in-flight-event
                                                      in-flight-bytes skipping)
  "Record a slow gap of GAP-MS with IN-FLIGHT-EVENT context.
IN-FLIGHT-BYTES is bytes received for the current event so far.
SKIPPING indicates whether the event is being skipped."
  (opencode-sse-profile--ensure-slow-gaps-ring)
  (ring-insert opencode-sse-profile--slow-gaps
               (list :timestamp (opencode-sse-profile--now)
                     :gap-ms gap-ms
                     :in-flight-event (or in-flight-event "(between events)")
                     :in-flight-bytes (or in-flight-bytes 0)
                     :skipping skipping)))

;;; Aggregate helpers

(defun opencode-sse-profile--get-aggregate (event-type)
  "Return the aggregate plist for EVENT-TYPE, creating if needed."
  (or (gethash event-type opencode-sse-profile--aggregates)
      (let ((agg (list :count 0
                       :total-ms 0.0 :max-ms 0.0
                       :parse-total-ms 0.0 :parse-max-ms 0.0
                       :dispatch-total-ms 0.0 :dispatch-max-ms 0.0
                       :render-total-ms 0.0 :render-max-ms 0.0
                       :bytes-total 0
                       :skip-count 0 :skip-bytes-total 0)))
        (puthash event-type agg opencode-sse-profile--aggregates)
        agg)))

(defun opencode-sse-profile--update-aggregate (event-type
                                               &rest props)
  "Update aggregate for EVENT-TYPE with PROPS.
PROPS is a plist of (:total-ms :parse-ms :dispatch-ms :render-ms :bytes)."
  (let ((agg (opencode-sse-profile--get-aggregate event-type))
        (total-ms (or (plist-get props :total-ms) 0.0))
        (parse-ms (or (plist-get props :parse-ms) 0.0))
        (dispatch-ms (or (plist-get props :dispatch-ms) 0.0))
        (render-ms (or (plist-get props :render-ms) 0.0))
        (bytes (or (plist-get props :bytes) 0)))
    (plist-put agg :count (1+ (plist-get agg :count)))
    (plist-put agg :total-ms (+ (plist-get agg :total-ms) total-ms))
    (plist-put agg :max-ms (max (plist-get agg :max-ms) total-ms))
    (plist-put agg :parse-total-ms (+ (plist-get agg :parse-total-ms) parse-ms))
    (plist-put agg :parse-max-ms (max (plist-get agg :parse-max-ms) parse-ms))
    (plist-put agg :dispatch-total-ms (+ (plist-get agg :dispatch-total-ms) dispatch-ms))
    (plist-put agg :dispatch-max-ms (max (plist-get agg :dispatch-max-ms) dispatch-ms))
    (plist-put agg :render-total-ms (+ (plist-get agg :render-total-ms) render-ms))
    (plist-put agg :render-max-ms (max (plist-get agg :render-max-ms) render-ms))
    (plist-put agg :bytes-total (+ (plist-get agg :bytes-total) bytes))
    (puthash event-type agg opencode-sse-profile--aggregates)))

(defun opencode-sse-profile--record-skip (event-type bytes)
  "Record a skipped EVENT-TYPE with BYTES payload size."
  (let ((agg (opencode-sse-profile--get-aggregate event-type)))
    (plist-put agg :skip-count (1+ (plist-get agg :skip-count)))
    (plist-put agg :skip-bytes-total (+ (plist-get agg :skip-bytes-total) bytes))
    (puthash event-type agg opencode-sse-profile--aggregates))
  (opencode-sse-profile--record-event
   (list :timestamp (opencode-sse-profile--now)
         :event-type event-type
         :skipped t
         :bytes bytes)))

;;; Chunk-level profiling

(defun opencode-sse-profile--record-chunk (elapsed-ms bytes skipping
                                                     in-flight-event
                                                     in-flight-bytes)
  "Record a chunk processing with ELAPSED-MS, BYTES, and SKIPPING flag.
IN-FLIGHT-EVENT is the event type currently being assembled (or nil).
IN-FLIGHT-BYTES is the bytes received for that event so far."
  (let ((now (opencode-sse-profile--now)))
    ;; Inter-chunk gap
    (when opencode-sse-profile--last-chunk-time
      (let ((gap-ms (* 1000.0 (- now opencode-sse-profile--last-chunk-time))))
        (setq opencode-sse-profile--inter-chunk-total-ms
              (+ opencode-sse-profile--inter-chunk-total-ms gap-ms))
        (setq opencode-sse-profile--inter-chunk-max-ms
              (max opencode-sse-profile--inter-chunk-max-ms gap-ms))
        (setq opencode-sse-profile--inter-chunk-count
              (1+ opencode-sse-profile--inter-chunk-count))
        ;; Record slow gaps with context
        (when (>= gap-ms opencode-sse-profile-slow-gap-threshold-ms)
          (opencode-sse-profile--record-slow-gap
           gap-ms in-flight-event in-flight-bytes skipping))))
    (setq opencode-sse-profile--last-chunk-time now)
    ;; Chunk stats
    (plist-put opencode-sse-profile--chunk-stats :count
               (1+ (plist-get opencode-sse-profile--chunk-stats :count)))
    (plist-put opencode-sse-profile--chunk-stats :total-ms
               (+ (plist-get opencode-sse-profile--chunk-stats :total-ms) elapsed-ms))
    (plist-put opencode-sse-profile--chunk-stats :max-ms
               (max (plist-get opencode-sse-profile--chunk-stats :max-ms) elapsed-ms))
    (plist-put opencode-sse-profile--chunk-stats :bytes-total
               (+ (plist-get opencode-sse-profile--chunk-stats :bytes-total) bytes))
    (when skipping
      (plist-put opencode-sse-profile--chunk-stats :skip-chunks
                 (1+ (plist-get opencode-sse-profile--chunk-stats :skip-chunks))))))

;;; Handler-level render timing (set by session render instrumentation)

(defvar opencode-sse-profile--current-render-ms nil
  "Render time in ms for the current dispatch cycle.
Set by instrumented render functions, consumed by finalize-event.")

(defun opencode-sse-profile-add-render-time (ms)
  "Accumulate MS of render time into the current dispatch cycle."
  (when opencode-sse-profile-enabled
    (setq opencode-sse-profile--current-render-ms
          (+ (or opencode-sse-profile--current-render-ms 0.0) ms))))

;;; Finalize-event profiling (called from SSE layer)

(defun opencode-sse-profile--record-finalize (event-type parse-ms dispatch-ms bytes)
  "Record a finalized event with EVENT-TYPE, PARSE-MS, DISPATCH-MS, and BYTES."
  (let ((render-ms (or opencode-sse-profile--current-render-ms 0.0))
        (total-ms (+ parse-ms dispatch-ms
                     (or opencode-sse-profile--current-render-ms 0.0))))
    (setq opencode-sse-profile--current-render-ms nil)
    (opencode-sse-profile--update-aggregate
     event-type
     :total-ms total-ms
     :parse-ms parse-ms
     :dispatch-ms dispatch-ms
     :render-ms render-ms
     :bytes bytes)
    (opencode-sse-profile--record-event
     (list :timestamp (opencode-sse-profile--now)
           :event-type event-type
           :total-ms total-ms
           :parse-ms parse-ms
           :dispatch-ms dispatch-ms
           :render-ms render-ms
           :bytes bytes))))

;;; Reset

(defun opencode-sse-profile-reset ()
  "Clear all collected profiling data."
  (interactive)
  (setq opencode-sse-profile--ring nil)
  (clrhash opencode-sse-profile--aggregates)
  (setq opencode-sse-profile--chunk-stats
        (list :count 0 :total-ms 0.0 :max-ms 0.0
              :bytes-total 0 :skip-chunks 0))
  (setq opencode-sse-profile--last-chunk-time nil)
  (setq opencode-sse-profile--inter-chunk-max-ms 0.0)
  (setq opencode-sse-profile--inter-chunk-total-ms 0.0)
  (setq opencode-sse-profile--inter-chunk-count 0)
  (setq opencode-sse-profile--slow-gaps nil)
  (setq opencode-sse-profile--current-render-ms nil)
  (message "OpenCode SSE profile data cleared"))

;;; Report

(defun opencode-sse-profile--format-ms (ms)
  "Format MS as a human-readable duration string."
  (cond
   ((< ms 1.0) (format "%.2fms" ms))
   ((< ms 1000.0) (format "%.1fms" ms))
   (t (format "%.2fs" (/ ms 1000.0)))))

(defun opencode-sse-profile--format-bytes (bytes)
  "Format BYTES as a human-readable size string."
  (cond
   ((< bytes 1024) (format "%dB" bytes))
   ((< bytes (* 1024 1024)) (format "%.1fKB" (/ bytes 1024.0)))
   (t (format "%.1fMB" (/ bytes (* 1024.0 1024.0))))))

(defun opencode-sse-profile--safe-div (a b)
  "Divide A by B, returning 0.0 when B is zero."
  (if (zerop b) 0.0 (/ (float a) b)))

(defun opencode-sse-profile-report ()
  "Display an SSE performance profile report."
  (interactive)
  (let ((buf (get-buffer-create "*OpenCode SSE Profile*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "═══════════════════════════════════════════\n")
        (insert "  OpenCode SSE Performance Profile Report\n")
        (insert "═══════════════════════════════════════════\n\n")

        ;; Profiling status
        (insert (format "Profiling: %s\n\n"
                        (if opencode-sse-profile-enabled "ENABLED" "DISABLED")))

        ;; Chunk stats
        (let* ((stats opencode-sse-profile--chunk-stats)
               (count (plist-get stats :count))
               (total (plist-get stats :total-ms))
               (max-ms (plist-get stats :max-ms))
               (bytes (plist-get stats :bytes-total))
               (skip-chunks (plist-get stats :skip-chunks)))
          (insert "── Chunk Processing ──────────────────────\n")
          (insert (format "  Chunks processed:  %d\n" count))
          (insert (format "  Total time:        %s\n"
                          (opencode-sse-profile--format-ms total)))
          (insert (format "  Avg per chunk:     %s\n"
                          (opencode-sse-profile--format-ms
                           (opencode-sse-profile--safe-div total count))))
          (insert (format "  Max chunk time:    %s\n"
                          (opencode-sse-profile--format-ms max-ms)))
          (insert (format "  Total bytes:       %s\n"
                          (opencode-sse-profile--format-bytes bytes)))
          (insert (format "  Skip-path chunks:  %d\n\n" skip-chunks)))

        ;; Inter-chunk gaps
        (let ((count opencode-sse-profile--inter-chunk-count)
              (total opencode-sse-profile--inter-chunk-total-ms)
              (max-ms opencode-sse-profile--inter-chunk-max-ms))
          (insert "── Inter-Chunk Gaps (network latency) ────\n")
          (insert (format "  Measurements:      %d\n" count))
          (insert (format "  Avg gap:           %s\n"
                          (opencode-sse-profile--format-ms
                           (opencode-sse-profile--safe-div total count))))
          (insert (format "  Max gap:           %s\n\n"
                          (opencode-sse-profile--format-ms max-ms))))

        ;; Slow gaps
        (insert "── Slow Gaps (>")
        (insert (opencode-sse-profile--format-ms
                 opencode-sse-profile-slow-gap-threshold-ms))
        (insert ") ────────────────────────\n")
        (if (or (null opencode-sse-profile--slow-gaps)
                (ring-empty-p opencode-sse-profile--slow-gaps))
            (insert "  (none recorded)\n\n")
          (let* ((len (ring-length opencode-sse-profile--slow-gaps))
                 (show (min len 30)))
            (insert (format "  %d slow gaps recorded (showing %d largest)\n\n"
                            len show))
            (insert (format "  %-12s %10s  %-28s %12s %s\n"
                            "Time" "Gap" "In-flight event"
                            "Bytes so far" ""))
            (insert (format "  %-12s %10s  %-28s %12s\n"
                            (make-string 12 ?─)
                            (make-string 10 ?─)
                            (make-string 28 ?─)
                            (make-string 12 ?─)))
            ;; Collect all entries and sort by gap size descending
            (let ((entries nil))
              (dotimes (i len)
                (push (ring-ref opencode-sse-profile--slow-gaps i) entries))
              (setq entries (sort entries
                                  (lambda (a b)
                                    (> (plist-get a :gap-ms)
                                       (plist-get b :gap-ms)))))
              (cl-loop for record in entries
                       for idx from 0 below show
                       do
                       (let* ((ts (plist-get record :timestamp))
                              (time-str (format-time-string "%H:%M:%S" ts))
                              (gap-ms (plist-get record :gap-ms))
                              (event (plist-get record :in-flight-event))
                              (bytes (plist-get record :in-flight-bytes))
                              (skipping (plist-get record :skipping))
                              (label (if skipping
                                         (concat event " [SKIP]")
                                       event)))
                         (insert (format "  %-12s %10s  %-28s %12s\n"
                                         time-str
                                         (opencode-sse-profile--format-ms gap-ms)
                                         label
                                         (opencode-sse-profile--format-bytes bytes))))))
            (insert "\n")))

        ;; Per-event-type table
        (insert "── Event Type Breakdown ──────────────────\n")
        (insert "  (Render time is a subset of Dispatch time)\n\n")
        (let ((types nil))
          (maphash (lambda (k _v) (push k types))
                   opencode-sse-profile--aggregates)
          (setq types (sort types #'string<))
          (if (null types)
              (insert "  (no events recorded)\n\n")
            (insert (format "  %-28s %6s %8s %8s %8s %8s %8s %10s\n"
                            "Event" "Count" "Avg" "Max"
                            "Parse" "Dispatch" "Render" "Bytes"))
            (insert (format "  %-28s %6s %8s %8s %8s %8s %8s %10s\n"
                            (make-string 28 ?─)
                            (make-string 6 ?─)
                            (make-string 8 ?─)
                            (make-string 8 ?─)
                            (make-string 8 ?─)
                            (make-string 8 ?─)
                            (make-string 8 ?─)
                            (make-string 10 ?─)))
            (dolist (type types)
              (let* ((agg (gethash type opencode-sse-profile--aggregates))
                     (count (plist-get agg :count))
                     (total (plist-get agg :total-ms))
                     (max-ms (plist-get agg :max-ms))
                     (parse-avg (opencode-sse-profile--safe-div
                                 (plist-get agg :parse-total-ms) count))
                     (dispatch-avg (opencode-sse-profile--safe-div
                                    (plist-get agg :dispatch-total-ms) count))
                     (render-avg (opencode-sse-profile--safe-div
                                  (plist-get agg :render-total-ms) count))
                     (bytes (plist-get agg :bytes-total))
                     (skip-count (plist-get agg :skip-count))
                     (skip-bytes (plist-get agg :skip-bytes-total)))
                (insert (format "  %-28s %6d %8s %8s %8s %8s %8s %10s\n"
                                type
                                count
                                (opencode-sse-profile--format-ms
                                 (opencode-sse-profile--safe-div total count))
                                (opencode-sse-profile--format-ms max-ms)
                                (opencode-sse-profile--format-ms parse-avg)
                                (opencode-sse-profile--format-ms dispatch-avg)
                                (opencode-sse-profile--format-ms render-avg)
                                (opencode-sse-profile--format-bytes bytes)))
                (when (> skip-count 0)
                  (insert (format "  %28s  skipped: %d events, %s\n"
                                  "" skip-count
                                  (opencode-sse-profile--format-bytes skip-bytes))))))
            (insert "\n")))

        ;; Recent event timeline
        (insert "── Recent Events (newest first) ──────────\n")
        (if (or (null opencode-sse-profile--ring)
                (ring-empty-p opencode-sse-profile--ring))
            (insert "  (no events recorded)\n")
          (let* ((len (ring-length opencode-sse-profile--ring))
                 (show (min len 50)))
            (insert (format "  Showing %d of %d recorded events\n\n" show len))
            (insert (format "  %-12s %-28s %8s %8s %8s %8s %10s\n"
                            "Time" "Event" "Total" "Parse" "Dispatch" "Render" "Bytes"))
            (insert (format "  %-12s %-28s %8s %8s %8s %8s %10s\n"
                            (make-string 12 ?─)
                            (make-string 28 ?─)
                            (make-string 8 ?─)
                            (make-string 8 ?─)
                            (make-string 8 ?─)
                            (make-string 8 ?─)
                            (make-string 10 ?─)))
            (dotimes (i show)
              (let* ((record (ring-ref opencode-sse-profile--ring i))
                     (ts (plist-get record :timestamp))
                     (time-str (format-time-string "%H:%M:%S" ts))
                     (event-type (or (plist-get record :event-type) "?"))
                     (skipped (plist-get record :skipped))
                     (bytes (or (plist-get record :bytes) 0)))
                (if skipped
                    (insert (format "  %-12s %-28s %8s %8s %8s %8s %10s\n"
                                    time-str
                                    (concat event-type " [SKIP]")
                                    "-" "-" "-" "-"
                                    (opencode-sse-profile--format-bytes bytes)))
                  (insert (format "  %-12s %-28s %8s %8s %8s %8s %10s\n"
                                  time-str
                                  event-type
                                  (opencode-sse-profile--format-ms
                                   (or (plist-get record :total-ms) 0.0))
                                  (opencode-sse-profile--format-ms
                                   (or (plist-get record :parse-ms) 0.0))
                                  (opencode-sse-profile--format-ms
                                   (or (plist-get record :dispatch-ms) 0.0))
                                  (opencode-sse-profile--format-ms
                                   (or (plist-get record :render-ms) 0.0))
                                  (opencode-sse-profile--format-bytes bytes))))))))

        (insert "\n")
        (special-mode)))
    (pop-to-buffer buf)))

(provide 'emacs-opencode-sse-profile)

;;; emacs-opencode-sse-profile.el ends here
