;;; elpet-persist.el --- Portable display preferences -*- lexical-binding: t; -*-

;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Persist a small JSON preference record, never live resources or task facts.

;;; Code:
(require 'json)
(require 'cl-lib)

(defvar elpet-state-file)

(defun elpet--position-record (position area width height)
  "Normalize POSITION within text AREA for a pet of WIDTH and HEIGHT."
  (when (and position area)
    (pcase-let ((`(,left ,top ,right ,bottom) area))
      (list :anchor "text-area" :x (max 0.0 (min 1.0 (/ (float (- (car position) left))
							(max 1 (- right left width)))))
            :y (max 0.0 (min 1.0 (/ (float (- (cdr position) top))
                                    (max 1 (- bottom top height)))))))))

(defun elpet--restore-position (record areas width height)
  "Restore normalized RECORD in AREAS, clamping for WIDTH and HEIGHT."
  (when record
    (let* ((pane (plist-get record :pane))
           (area (or (and (integerp pane) (nth pane areas)) (car areas))))
      (when area
        (pcase-let ((`(,left ,top ,right ,bottom) area))
          (cons (+ left (round (* (plist-get record :x) (max 0 (- right left width)))))
                (+ top (round (* (plist-get record :y) (max 0 (- bottom top height)))))))))))

(defun elpet--read-preferences ()
  "Read validated preferences, ignoring missing or damaged files."
  (condition-case nil
      (when (and elpet-state-file (file-readable-p elpet-state-file))
        (let* ((data (with-temp-buffer
                       (insert-file-contents elpet-state-file)
                       (json-parse-buffer :object-type 'plist :array-type 'list
                                          :false-object nil :null-object nil)))
               (position (plist-get data :position)))
          (when (and (eq (plist-get data :schema-version) 1)
                     (or (null position)
                         (and (equal (plist-get position :anchor) "text-area")
                              (cl-every (lambda (key)
                                          (let ((n (plist-get position key)))
                                            (and (numberp n) (<= 0 n 1)))) '(:x :y))
                              (natnump (plist-get position :pane)))))
            data)))
    (error nil)))

(defun elpet--write-preferences (preferences)
  "Atomically save PREFERENCES, or report a nonfatal write failure."
  (when elpet-state-file
    (let* ((target (expand-file-name elpet-state-file))
           (directory (file-name-directory target)) temporary)
      (condition-case err
          (progn
            (make-directory directory t)
            (setq temporary (make-temp-file (expand-file-name ".pet-" directory)))
            (with-temp-file temporary
              (insert (json-serialize preferences :null-object nil :false-object :false)))
            (rename-file temporary target t))
        (error (message "elpet preferences: %s" (error-message-string err))))
      (when (and temporary (file-exists-p temporary)) (delete-file temporary)))))

(provide 'elpet-persist)
;;; elpet-persist.el ends here
