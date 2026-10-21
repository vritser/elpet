;;; elpet-compilation.el --- Local activity adapter -*- lexical-binding: t; -*-

;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Compilation is a registered source, independent of future host adapters.

;;; Code:
(require 'compile)
(require 'elpet-events)
(require 'elpet-render)
(defvar elpet-mode)
(defvar elpet-follow-compilation)
(declare-function elpet--tick "elpet")
(declare-function elpet-set-state "elpet" (state &optional seconds))

(defun elpet--compilation-event (kind process)
  "Submit KIND for tracked compilation PROCESS in the default instance."
  (when (elpet--resolve nil)
    (let ((id (process-get process 'elpet-activity)))
      (when id
        (cl-incf elpet--sequence)
        (elpet-emit
         (list :schema-version 1 :pet-id (elpet-instance-id elpet--default-instance)
               :source-id "compilation" :source-epoch (process-get process 'elpet-epoch) :sequence elpet--sequence
               :event-id (format "compilation-%d" elpet--sequence)
               :activity-id id :kind kind)
         elpet--default-instance)))))

(defun elpet--compilation-start (process)
  "Record compilation PROCESS as an independent activity."
  (elpet--with-default
   (when (and elpet-mode elpet-follow-compilation)
     (unless (memq process elpet--compilations)
       (push process elpet--compilations)
       (when (elpet--resolve nil)
         (unless (gethash "compilation" (elpet-instance-sources elpet--default-instance))
           (elpet-register-source "compilation"))
         (process-put process 'elpet-epoch
                      (plist-get (gethash "compilation"
                                          (elpet-instance-sources elpet--default-instance)) :epoch))
         (process-put process 'elpet-activity
                      (elpet--new-id elpet--default-instance "compile"))
         (elpet--compilation-event 'started process)))
     (elpet--tick))))

(defun elpet--compilation-finish (buffer status)
  "End only the activity associated with compilation BUFFER and STATUS."
  (elpet--with-default
   (when (and elpet-mode elpet-follow-compilation)
     (let ((tracked (cl-find buffer elpet--compilations :key #'process-buffer)))
       (when tracked
         (setq elpet--compilations (delq tracked elpet--compilations))
         (if (elpet--resolve nil)
             (progn
               (elpet--compilation-event
                (cond ((string-match-p "\\`finished" status) 'finished)
                      ((string-match-p "\\`\\(?:interrupt\\|killed\\|terminated\\)" status) 'cancelled)
                      (t 'failed)) tracked)
               (elpet--tick))
           (unless elpet--compilations
             (elpet-set-state (if (string-match-p "\\`finished" status) 'success 'error)))))))))

(defun elpet--reconcile-compilations ()
  "Clear vanished compilation processes and honor a disabled adapter."
  (when (elpet--resolve nil)
    (if (not elpet-follow-compilation)
        (when (gethash "compilation" (elpet-instance-sources elpet--default-instance))
          (elpet-unregister-source "compilation")
          (setq elpet--compilations nil))
      (dolist (process (copy-sequence elpet--compilations))
        (unless (process-live-p process)
          (elpet--compilation-event 'cancelled process)
          (setq elpet--compilations (delq process elpet--compilations)))))))

(provide 'elpet-compilation)
;;; elpet-compilation.el ends here
