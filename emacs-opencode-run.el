;;; emacs-opencode-run.el --- Async wrapper around `opencode run'  -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'subr-x)
(require 'emacs-opencode-connection)

(defun opencode-run--build-args (prompt &rest args)
  "Build the argument list for `opencode run' with PROMPT.

ARGS is a plist supporting :MODEL, :AGENT, :COMMAND, and
:DANGEROUSLY-SKIP-PERMISSIONS, each mapping to the corresponding CLI flag.
Flags with nil values are omitted.  PROMPT is appended last as the message."
  (let ((model (plist-get args :model))
        (agent (plist-get args :agent))
        (command (plist-get args :command))
        (skip (plist-get args :dangerously-skip-permissions))
        (result (list "run")))
    (when model
      (setq result (append result (list "--model" model))))
    (when agent
      (setq result (append result (list "--agent" agent))))
    (when command
      (setq result (append result (list "--command" command))))
    (when skip
      (setq result (append result (list "--dangerously-skip-permissions"))))
    (append result (list prompt))))

(defun opencode-run--invoke-callback (callback output success-p)
  "Call CALLBACK with OUTPUT, passing SUCCESS-P when it accepts a second arg.

When CALLBACK is nil, do nothing.  Trailing whitespace and newlines are
stripped from OUTPUT before it is passed on.  CALLBACK's arity is inspected
with `func-arity': callbacks that accept two or more arguments receive
\(OUTPUT SUCCESS-P), while single-argument callbacks receive only OUTPUT."
  (when callback
    (let ((output (and output (string-trim-right output)))
          (max-arity (cdr (func-arity callback))))
      (if (or (eq max-arity 'many) (and (integerp max-arity) (>= max-arity 2)))
          (funcall callback output success-p)
        (funcall callback output)))))

(cl-defun opencode-run (prompt callback
                               &key model agent command
                               dangerously-skip-permissions)
  "Run `opencode run' asynchronously with PROMPT and invoke CALLBACK.

CALLBACK is called when the process finishes.  When CALLBACK accepts two or
more arguments it receives (OUTPUT SUCCESS-P); when it accepts a single
argument it receives just OUTPUT.  OUTPUT is the command's standard output
\(the model's plain-text answer); the formatted header and ANSI control
sequences OpenCode writes to standard error are discarded.  SUCCESS-P is
non-nil when the process exited successfully.

MODEL, AGENT, and COMMAND map to the `--model', `--agent', and `--command'
flags.  When DANGEROUSLY-SKIP-PERMISSIONS is non-nil, pass
`--dangerously-skip-permissions'.

The command runs in `default-directory'; bind it to control where OpenCode
runs."
  (let ((executable (executable-find opencode-server-command)))
    (unless executable
      (error "OpenCode executable not found: %s" opencode-server-command))
    (let* ((args (apply #'opencode-run--build-args prompt
                        :model model
                        :agent agent
                        :command command
                        :dangerously-skip-permissions dangerously-skip-permissions
                        nil))
           (buffer (generate-new-buffer
                    (format " *opencode-run<%s>*" default-directory)))
           ;; OpenCode writes a formatted header and ANSI control sequences to
           ;; stderr.  Route it to its own buffer so OUTPUT stays plain text.
           (stderr-buffer (generate-new-buffer
                           (format " *opencode-run-stderr<%s>*" default-directory)))
           (process
            (make-process
             :name "opencode-run"
             :buffer buffer
             :command (cons executable args)
             :connection-type 'pipe
             :noquery t
             :stderr stderr-buffer
             :sentinel
             (lambda (process _event)
               (when (memq (process-status process) '(exit signal))
                 (let ((output (when (buffer-live-p buffer)
                                 (with-current-buffer buffer
                                   (buffer-string))))
                       (success-p (and (eq (process-status process) 'exit)
                                       (= (process-exit-status process) 0))))
                   (when (buffer-live-p buffer)
                     (kill-buffer buffer))
                   (when (buffer-live-p stderr-buffer)
                     (kill-buffer stderr-buffer))
                   (opencode-run--invoke-callback callback output success-p)))))))
      ;; `opencode run' keeps reading stdin and never exits unless it sees
      ;; EOF, so close the input stream immediately.
      (process-send-eof process)
      process)))

(provide 'emacs-opencode-run)

;;; emacs-opencode-run.el ends here
