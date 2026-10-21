;;; run-gui.el --- Run tests in an isolated graphical Emacs -*- lexical-binding: t; -*-

;; Usage: scripts/run-gui.sh (passes an absolute path).  Loading this file with
;; a relative path is unreliable because GUI Emacs may not inherit the shell's
;; working directory.
;; This runner exits its Emacs process.  Do not load it in a working session.
(let* ((directory (file-name-directory
                   (expand-file-name (or load-file-name buffer-file-name))))
       (root (file-name-directory (directory-file-name directory))))
  (add-to-list 'load-path root)
  (setq load-prefer-newer t)
  (load (expand-file-name "elpet-test.el" directory) nil t))

(run-at-time
 0.5 nil
 (lambda ()
   (unless (display-graphic-p) (error "Run this runner in graphical Emacs"))
   (let* ((stats (ert-run-tests-batch t))
          (report (expand-file-name "elpet-gui-results.txt" temporary-file-directory)))
     (with-temp-file report
       (insert (format "Emacs %s (%s)\nTotal: %d; passed: %d; failed: %d; skipped: %d\n\n"
                       emacs-version system-configuration (ert-stats-total stats)
                       (ert-stats-completed-expected stats) (ert-stats-completed-unexpected stats)
                       (ert-stats-skipped stats)))
       (insert (with-current-buffer "*Messages*" (buffer-string))))
     (kill-emacs (if (zerop (ert-stats-completed-unexpected stats)) 0 1)))))
;;; run-gui.el ends here
