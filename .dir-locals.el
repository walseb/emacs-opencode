((emacs-lisp-mode
  . ((eval . (let ((root (expand-file-name (locate-dominating-file default-directory ".dir-locals.el"))))
               (add-to-list 'load-path root)
               (add-to-list 'load-path (expand-file-name "tests" root))
               (unless (fboundp 'run-opencode-tests)
                 (defun run-opencode-tests ()
                   "Load and run all OpenCode ERT tests interactively."
                   (interactive)
                   (require 'run-tests)
                   (ert t))))))))
