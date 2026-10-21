;;; elpet-model.el --- Companion instances -*- lexical-binding: t; -*-

;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Instance-local facts and lifecycle.  This module does not create windows.

;;; Code:

(require 'cl-lib)

(cl-defstruct (elpet-instance (:constructor elpet--make-instance))
	      id (generation 0) (alive t) (revision 0) view pack
	      (sources (make-hash-table :test #'equal))
	      (epochs (make-hash-table :test #'equal))
	      (activities (make-hash-table :test #'equal))
	      (requests (make-hash-table :test #'equal))
	      messages history subscribers (serial 0))

(defvar elpet--instances (make-hash-table :test #'equal))
(defvar elpet--default-instance nil)
(defvar elpet--destroy-functions nil
  "Functions called with an invalidated instance to release its resources.")
(defvar elpet--clock #'float-time
  "Function returning the current time in seconds; replaceable in tests.")

(defun elpet--now ()
  "Return the current time through the configurable clock."
  (funcall elpet--clock))

(defun elpet--resolve (pet)
  "Resolve PET, an instance, ID, or nil for the default, to a live instance."
  (let ((instance (cond ((elpet-instance-p pet) pet)
                        ((null pet) elpet--default-instance)
                        (t (gethash pet elpet--instances)))))
    (and instance (elpet-instance-alive instance) instance)))

(defun elpet-create (&optional id)
  "Create a model instance named ID and return its handle.
This does not open a window.  `elpet-mode' attaches the default display.
An omitted ID generates a unique name; duplicate live IDs are rejected."
  (setq id (or id (symbol-name (gensym "pet-"))))
  (unless (and (stringp id) (> (length id) 0))
    (user-error "Pet ID must be a nonempty string"))
  (when (elpet--resolve id) (user-error "Pet already exists: %s" id))
  (let ((pet (elpet--make-instance :id (copy-sequence id))))
    (puthash (elpet-instance-id pet) pet elpet--instances)
    pet))

(defun elpet-destroy (&optional pet)
  "Invalidate PET and release its resources.  Repeated calls are harmless."
  (when-let* ((instance (elpet--resolve pet)))
    ;; Invalidate before cleanup so late callbacks cannot revive the instance.
    (setf (elpet-instance-alive instance) nil)
    (cl-incf (elpet-instance-generation instance))
    (remhash (elpet-instance-id instance) elpet--instances)
    (run-hook-with-args 'elpet--destroy-functions instance)
    (clrhash (elpet-instance-sources instance))
    (clrhash (elpet-instance-epochs instance))
    (clrhash (elpet-instance-activities instance))
    (clrhash (elpet-instance-requests instance))
    (setf (elpet-instance-subscribers instance) nil
          (elpet-instance-messages instance) nil)
    (when (eq instance elpet--default-instance)
      (setq elpet--default-instance nil))
    t))

(defun elpet--new-id (pet prefix)
  "Return a unique request ID for PET using PREFIX."
  (format "%s-%s-%d" (elpet-instance-id pet) prefix
          (cl-incf (elpet-instance-serial pet))))

(defun elpet--copy-data (value)
  "Copy data VALUE, including mutable strings, for API boundaries."
  (cond ((consp value) (cons (elpet--copy-data (car value))
                             (elpet--copy-data (cdr value))))
        ((stringp value) (copy-sequence value))
        ((vectorp value) (vconcat (mapcar #'elpet--copy-data value)))
        (t value)))

(defun elpet--publish (pet event)
  "Notify PET's subscribers of EVENT, isolating errors and mutable data."
  (cl-incf (elpet-instance-revision pet))
  (dolist (callback (copy-sequence (elpet-instance-subscribers pet)))
    (condition-case err
        (funcall callback (elpet--copy-data event))
      (error (message "elpet subscriber: %s" (error-message-string err))))))

(defun elpet-subscribe (callback &optional pet)
  "Subscribe CALLBACK to PET's changes; return an unsubscribe function."
  (let ((instance (or (elpet--resolve pet) (user-error "Pet is not active"))))
    (unless (functionp callback) (user-error "Subscriber must be a function"))
    (push callback (elpet-instance-subscribers instance))
    (lambda ()
      (setf (elpet-instance-subscribers instance)
            (remq callback (elpet-instance-subscribers instance))))))

(provide 'elpet-model)
;;; elpet-model.el ends here
