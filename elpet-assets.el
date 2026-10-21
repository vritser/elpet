;;; elpet-assets.el --- Data-only character packs -*- lexical-binding: t; -*-

;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Validate local pack metadata and choose weighted, available actions.

;;; Code:
(require 'cl-lib)
(require 'json)
(require 'elpet-state)

(cl-defstruct (elpet-pack (:constructor elpet--make-pack))
	      id root author license source fallback crops states catalog index)

(defconst elpet--animations
  '((idle . ("daiji-huxi-xiuxian"))
    (sleeping . ("da-keshui-bei-jingxing"))
    (thinking . ("gongzuozhuangtai-sikao-maopao"))
    (working . ("gongzuozhuangtai-manglu-dianan"))
    (waiting . ("gongzuozhuangtai-yuandi-duobu-zhangwang"))
    (success . ("gongzuozhuangtai-queyue-qingzhu"))
    (error . ("gongzuozhuangtai-chuitou-tanqi-maohan"))
    (happy . ("yuandi-qiaoji-zhuomian-hudong")))
  "Default state mapping, also used for legacy asset-directory configuration.")

(defun elpet--pack-path (root relative)
  "Resolve RELATIVE inside ROOT, rejecting absolute paths and escaping links."
  (unless (and (stringp relative) (> (length relative) 0)
               (not (file-name-absolute-p relative)))
    (user-error "Pack paths must be relative: %s" relative))
  (let ((file (expand-file-name relative root))
        (base (file-name-as-directory (file-truename root))))
    (unless (string-prefix-p base (file-truename file))
      (user-error "Pack path escapes its root: %s" relative))
    file))

(defun elpet-load-pack (file)
  "Read and validate data-only character pack FILE, returning its handle.
All asset paths, including symlinks, must stay inside the manifest directory.
Missing individual animations are allowed and fall back to idle or a still."
  (let* ((root (file-name-directory (expand-file-name file)))
         (data (with-temp-buffer
                 (insert-file-contents file)
                 (json-parse-buffer :object-type 'alist :array-type 'list
                                    :null-object nil :false-object nil)))
         (states (alist-get 'states data))
         parsed)
    (unless (and (eq (alist-get 'schema-version data) 1)
                 (cl-every (lambda (key)
                             (let ((value (alist-get key data)))
                               (and (stringp value) (> (length value) 0))))
                           '(pack-id author license source))
                 states)
      (user-error "Invalid character pack metadata: %s" file))
    (dolist (state states)
      (unless (memq (car state) elpet--states)
        (user-error "Unknown character state: %s" (car state)))
      (let (entries names)
        (dolist (action (cdr state))
          (let ((name (alist-get 'name action))
                (weight (or (alist-get 'weight action) 1))
                (asset (elpet--pack-path root (alist-get 'file action))))
            (unless (and (stringp name) (string-match-p "\\`[a-zA-Z0-9_-]+\\'" name)
                         (not (equal name "__fallback__"))
                         (not (member name names))
                         (integerp weight) (> weight 0) (<= weight 10000)
                         (equal (downcase (or (file-name-extension asset) "")) "gif"))
              (user-error "Invalid character action: %s" action))
            (push name names)
            (push (list :name name :file asset :weight weight
                        :loop (if (assq 'loop action) (alist-get 'loop action) t)) entries)))
        (push (cons (car state) (nreverse entries)) parsed)))
    (let ((catalog nil) (definitions (make-hash-table :test #'equal)))
      (dolist (state parsed)
        (dolist (action (cdr state))
          (let* ((name (plist-get action :name))
                 (definition (cons (plist-get action :file) (plist-get action :loop)))
                 (previous (gethash name definitions)))
            (when (and previous (not (equal previous definition)))
              (user-error "Conflicting definitions for action: %s" name))
            (puthash name definition definitions))))
      (dolist (action (alist-get 'animations data))
        (let ((name (alist-get 'name action))
              (asset (elpet--pack-path root (alist-get 'file action))))
          (unless (and (stringp name) (string-match-p "\\`[a-zA-Z0-9_-]+\\'" name)
                       (not (equal name "__fallback__"))
                       (not (assoc name catalog))
                       (equal (downcase (or (file-name-extension asset) "")) "gif"))
            (user-error "Invalid catalog action: %s" action))
          (when (and (gethash name definitions)
                     (not (equal asset (car (gethash name definitions)))))
            (user-error "Catalog conflicts with state action: %s" name))
          (push (cons name asset) catalog)))
      ;; One lookup table serves asset resolution, loop rules, and completion.
      ;; Rebuilding it from the validated definitions avoids rescanning the
      ;; nested state lists on every redraw.
      (let ((index (make-hash-table :test #'equal)))
        (maphash (lambda (name definition)
                   (puthash name (list :name name :file (car definition)
                                       :loop (cdr definition) :weight 1)
                            index))
                 definitions)
        (dolist (entry catalog)
          (unless (gethash (car entry) index)
            (puthash (car entry) (list :name (car entry) :file (cdr entry)
                                       :loop t :weight 1)
                     index)))
        (let ((fallback (elpet--pack-path root (alist-get 'fallback data))))
          (unless (and (file-regular-p fallback) (file-readable-p fallback)
                       (member (downcase (or (file-name-extension fallback) ""))
                               '("png" "gif" "xpm" "pbm")))
            (user-error "Missing or unsupported pack fallback: %s" fallback))
          (elpet--make-pack
           :id (alist-get 'pack-id data) :root root
           :author (alist-get 'author data) :license (alist-get 'license data)
           :source (alist-get 'source data) :fallback fallback
           :crops (when (alist-get 'crops data)
                    (elpet--pack-path root (alist-get 'crops data)))
           :states (nreverse parsed) :catalog catalog :index index))))))

(defun elpet--pack-actions (pack state)
  "Return available PACK actions for STATE, falling back to idle."
  (let ((available (lambda (actions)
                     (cl-remove-if-not (lambda (a) (and (file-regular-p (plist-get a :file))
                                                        (file-readable-p (plist-get a :file))))
                                       actions))))
    (or (funcall available (alist-get state (elpet-pack-states pack)))
        (funcall available (alist-get 'idle (elpet-pack-states pack))))))

(defun elpet--weighted-choice (actions previous &optional random-function)
  "Choose from ACTIONS, avoiding PREVIOUS; use RANDOM-FUNCTION if supplied."
  (let* ((choices (or (cl-remove previous actions :key (lambda (a) (plist-get a :name))
                                 :test #'equal) actions))
         (total (apply #'+ (mapcar (lambda (a) (plist-get a :weight)) choices)))
         (draw (and (> total 0) (funcall (or random-function #'random) total)))
         chosen)
    (dolist (action choices chosen)
      (when (and (not chosen) draw)
        (setq draw (- draw (plist-get action :weight)))
        (when (< draw 0) (setq chosen action))))))

(defun elpet--read-crops (file)
  "Read optional crop FILE; malformed metadata safely disables trimming."
  (condition-case nil
      (if (and file (file-readable-p file))
          (with-temp-buffer
            (insert-file-contents file)
            (let ((data (json-parse-buffer :array-type 'list)))
              (if (hash-table-p data) data (make-hash-table :test #'equal))))
        (make-hash-table :test #'equal))
    (error (make-hash-table :test #'equal))))

(provide 'elpet-assets)
;;; elpet-assets.el ends here
