;;; elpet-render.el --- Instance-owned display context -*- lexical-binding: t; -*-

;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Bind the existing renderer to instance-owned resources.  Bindings are local
;; to one entry point, so nested commands share a view and cleanup is saved.

;;; Code:
(require 'elpet-model)

(cl-defstruct (elpet-view (:constructor elpet--make-view))
	      buffer frame parent window timer refresh-timer image (bubble-height 0)
	      (bubble-max-width 0)
	      (bubble-images (make-hash-table :test #'equal))
	      animation state override (next-action 0) compilations manual-position
	      dragging crop-data image-slice sprite-height sprite-width display-width
	      pack text bubble-action bubble-format (dirty t) hidden bubble-process pending-bubble
	      (bubble-lines nil) (bubble-offset 0) (bubble-follow t) bubble-wrap-key bubble-all-lines
              position-data (sequence 0) unsubscribe last-error)

(defconst elpet--view-fields
  '(buffer frame parent window timer refresh-timer image bubble-height bubble-max-width bubble-images
	   animation state override next-action compilations manual-position
	   dragging crop-data image-slice sprite-height sprite-width display-width
	   pack text bubble-action bubble-format dirty hidden bubble-process pending-bubble bubble-lines
           bubble-offset bubble-follow bubble-wrap-key bubble-all-lines position-data
	   sequence unsubscribe last-error))

;; These special variables form a dynamically bound renderer context only.
;; Runtime ownership lives in `elpet-view', not in global values.
(defvar elpet--buffer nil)
(defvar elpet--frame nil)
(defvar elpet--parent nil)
(defvar elpet--window nil)
(defvar elpet--timer nil)
(defvar elpet--refresh-timer nil)
(defvar elpet--image nil)
(defvar elpet--bubble-height 0)
(defvar elpet--bubble-max-width 0)
(defvar elpet--bubble-images (make-hash-table :test #'equal))
(defvar elpet--animation nil)
(defvar elpet--state nil)
(defvar elpet--override nil)
(defvar elpet--next-action 0)
(defvar elpet--compilations nil)
(defvar elpet--manual-position nil)
(defvar elpet--dragging nil)
(defvar elpet--crop-data nil)
(defvar elpet--image-slice nil)
(defvar elpet--sprite-height nil)
(defvar elpet--sprite-width nil)
(defvar elpet--display-width nil)
(defvar elpet--pack nil)
(defvar elpet--text nil)
(defvar elpet--bubble-action nil)
(defvar elpet--bubble-format nil)
(defvar elpet--dirty t)
(defvar elpet--hidden nil)
(defvar elpet--bubble-process nil)
(defvar elpet--pending-bubble nil)
(defvar elpet--bubble-lines nil)
(defvar elpet--bubble-offset 0)
(defvar elpet--bubble-follow t)
(defvar elpet--bubble-wrap-key nil)
(defvar elpet--bubble-all-lines nil)
(defvar elpet--position-data nil)
(defvar elpet--sequence 0)
(defvar elpet--unsubscribe nil)
(defvar elpet--last-error nil)
(defvar elpet--current-view nil)

(defmacro elpet--with-view (view &rest body)
  "Evaluate BODY with VIEW's renderer resources, saving changes on exit."
  (declare (indent 1) (debug t))
  (let ((handle (gensym "view")))
    `(let* ((,handle ,view)
            (elpet--current-view ,handle)
            ,@(mapcar (lambda (field)
                        `(,(intern (format "elpet--%s" field))
                          (,(intern (format "elpet-view-%s" field)) ,handle)))
                      elpet--view-fields))
       (unwind-protect (progn ,@body)
         ,@(mapcar (lambda (field)
                     `(setf (,(intern (format "elpet-view-%s" field)) ,handle)
                            ,(intern (format "elpet--%s" field))))
                   elpet--view-fields)))))

(defmacro elpet--with-default (&rest body)
  "Evaluate BODY in the default display context, reusing nested bindings."
  (declare (indent 0) (debug t))
  `(if (or elpet--current-view
           (null elpet--default-instance)
           (null (elpet-instance-view elpet--default-instance)))
       (progn ,@body)
     (elpet--with-view (elpet-instance-view elpet--default-instance)
			   ,@body)))

(provide 'elpet-render)
;;; elpet-render.el ends here
