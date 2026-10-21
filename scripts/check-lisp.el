;;; check-lisp.el --- Read-level syntax check for elpet -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: MIT

;;; Commentary:

;; The syntax gate for `scripts/verify.sh'.  It never loads the package and
;; never rewrites a file.  Three checks run per production file:
;;
;;   1. A lexical-binding cookie is present in the first two lines.
;;   2. Every top-level form is balanced and readable.  The first phase walks
;;      with `forward-sexp' so an unbalanced closer or a missing closer is
;;      reported before `read' can turn it into a confusing end-of-file.
;;   3. The header declares Version and Package-Requires, and the file ends
;;      with `(provide ...)'.
;;
;; Usage:
;;   emacs -Q --batch -l scripts/check-lisp.el            ; default file list
;;   emacs -Q --batch -l scripts/check-lisp.el -- FILE... ; explicit files
;;
;; Exit status: 0 all files pass, 1 at least one failure, 2 usage error.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defconst elpet-check--default-files
  (sort (directory-files default-directory nil "\\`elpet.*\\.el\\'") #'string<)
  "Production files checked when no file arguments are supplied.")

(defconst elpet-check--baseline "30.1"
  "Minimum Emacs version required in every production header.")

(defun elpet-check--position (position)
  "Format POSITION as FILE:LINE:COL."
  (save-excursion
    (goto-char position)
    (format "%d:%d" (line-number-at-pos) (current-column))))

(defun elpet-check--report (file position format-string &rest arguments)
  "Report a diagnostic for FILE at POSITION using FORMAT-STRING and ARGUMENTS."
  (princ (format "%s:%s: %s\n"
                 file (elpet-check--position position)
                 (apply #'format format-string arguments))))

(defun elpet-check--header (file)
  "Check FILE's package header and return non-nil when it is valid."
  (let ((ok t))
    (goto-char (point-min))
    (unless (and (re-search-forward "-\\*-.*lexical-binding: t.*-\\*-"
                                    (line-end-position 2) t))
      (elpet-check--report file (point-min)
                               "Missing lexical-binding cookie")
      (setq ok nil))
    (save-excursion
      (goto-char (point-min))
      (unless (re-search-forward "^;; Version: [0-9]" nil t)
        (elpet-check--report file (point-min) "Missing Version header")
        (setq ok nil)))
    (save-excursion
      (goto-char (point-min))
      (unless (re-search-forward
               (format "^;; Package-Requires: .*emacs \"%s\""
                       (regexp-quote elpet-check--baseline))
               nil t)
        (elpet-check--report
         file (point-min)
         "Missing Package-Requires with Emacs %s" elpet-check--baseline)
        (setq ok nil)))
    (save-excursion
      (goto-char (point-max))
      (unless (re-search-backward "^(provide '[^ )]+)" nil t)
        (elpet-check--report file (point-max) "Missing (provide ...)")
        (setq ok nil)))
    ok))

(defun elpet-check--forms (file)
  "Walk and read every top-level form in FILE; return non-nil when readable."
  (let ((ok t))
    ;; Phase 1: balanced delimiters and terminated strings.
    (goto-char (point-min))
    (condition-case err
        (while (progn (forward-comment (point-max)) (not (eobp)))
          (forward-sexp 1))
      (scan-error
       (let ((position (if (integer-or-marker-p (nth 2 err))
                           (nth 2 err) (point))))
         (elpet-check--report file position "Unbalanced form: %s"
                                  (error-message-string err)))
       (setq ok nil))
      (error
       (elpet-check--report file (point) "Cannot walk form: %s"
                                (error-message-string err))
       (setq ok nil)))
    ;; Phase 2: the reader accepts every form, including stray closers and
    ;; invalid read syntax that `forward-sexp' may tolerate.
    (when ok
      (goto-char (point-min))
      (condition-case err
          (while (progn (forward-comment (point-max)) (not (eobp)))
            (read (current-buffer)))
        (end-of-file
         (unless (eobp)
           (elpet-check--report file (point) "Incomplete form at end of file")
           (setq ok nil)))
        (error
         (elpet-check--report file (point) "Read error: %s"
                                  (error-message-string err))
         (setq ok nil))))
    ok))

(defun elpet-check-file (file)
  "Check one production FILE and return non-nil when it passes."
  (with-temp-buffer
    (insert-file-contents file)
    (unless (derived-mode-p 'emacs-lisp-mode) (emacs-lisp-mode))
    (let ((header (elpet-check--header file))
          (forms (elpet-check--forms file)))
      (and header forms))))

(defun elpet-check-batch ()
  "Run the checker over the file arguments or the default production list."
  (let* ((arguments (cdr command-line-args-left))
         (files (if arguments arguments elpet-check--default-files))
         (failed 0))
    (when (null files)
      (princ "check-lisp: no files found\n" #'external-debugging-output)
      (kill-emacs 2))
    (if arguments
        nil
      (princ "check-lisp: using the default elpet*.el list\n"))
    (dolist (file files)
      (if (elpet-check-file file)
          (princ (format "ok   %s\n" file))
        (setq failed (1+ failed))))
    (if (> failed 0)
        (progn (princ (format "check-lisp: %d file(s) failed\n" failed))
               (kill-emacs 1))
      (kill-emacs 0))))

(elpet-check-batch)

;;; check-lisp.el ends here
