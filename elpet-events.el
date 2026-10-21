;;; elpet-events.el --- Ordered activity sources -*- lexical-binding: t; -*-

;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; In-process semantic events.  No host protocol or network dependency.

;;; Code:
(require 'elpet-state)

(defun elpet-register-source (id &optional options pet)
  "Register source ID in PET, returning its epoch.
OPTIONS accepts :epoch (an automatically incremented integer by default),
:kinds, and :priority (0..60).
Re-registration removes the previous source's facts and invalidates its epoch."
  (when-let* ((instance (elpet--resolve pet)))
    (let* ((record (gethash id (elpet-instance-epochs instance)))
           (previous (plist-get record :epoch))
           (counter (if record (1+ (plist-get record :counter)) 0))
           (epoch (if (plist-member options :epoch) (plist-get options :epoch)
                    counter))
           (kinds (or (plist-get options :kinds) elpet--activity-phases))
           (priority (or (plist-get options :priority) 40)))
      (unless (and (stringp id) (> (length id) 0) (not (member id '("manual" "local")))
                   (or (stringp epoch) (integerp epoch))
                   (listp kinds) (cl-every (lambda (k) (memq k elpet--source-kinds)) kinds)
                   (numberp priority) (<= 0 priority 60))
        (user-error "Invalid pet source registration"))
      (when (equal previous epoch) (user-error "A reconnected source needs a new epoch"))
      (puthash (copy-sequence id) (list :epoch (elpet--copy-data epoch) :counter counter)
               (elpet-instance-epochs instance))
      (setq id (copy-sequence id) epoch (elpet--copy-data epoch))
      (elpet-unregister-source id instance)
      (puthash id (list :epoch epoch :sequence -1 :kinds (copy-sequence kinds)
                        :priority priority :seen nil :closed nil)
               (elpet-instance-sources instance))
      (elpet--copy-data epoch))))

(defun elpet-unregister-source (id &optional pet)
  "Remove source ID and all its outstanding facts from PET."
  (when-let* ((instance (elpet--resolve pet)))
    (remhash id (elpet-instance-sources instance))
    (let (keys)
      (maphash (lambda (key activity)
                 (when (equal id (plist-get activity :source)) (push key keys)))
               (elpet-instance-activities instance))
      (dolist (key keys) (remhash key (elpet-instance-activities instance))))
    (maphash (lambda (_ request)
               (when (equal id (plist-get request :source))
                 (elpet--transition instance request 'cancelled)))
             (elpet-instance-requests instance))
    (setf (elpet-instance-messages instance)
          (cl-remove id (elpet-instance-messages instance)
                     :key (lambda (m) (plist-get m :source)) :test #'equal))
    (elpet--publish instance (list :kind 'source-removed :source-id id))
    t))

(defun elpet-emit (event &optional pet)
  "Submit an EVENT plist to PET and return (:ok BOOL :reason SYMBOL).
Required fields: :schema-version 1, :pet-id, :event-id, :source-id,
:source-epoch, :sequence, and :kind.  Activity events need :activity-id.
Register a new epoch explicitly on reconnect.  :baseline suppresses historical
completion feedback on the first event after registration.  Invalid, stale,
or duplicate events never replay feedback and never open a pet."
  (if (not (proper-list-p event)) '(:ok nil :reason invalid)
    (setq event (elpet--copy-data event))
    (let* ((instance (elpet--resolve pet))
           (source (and instance (listp event)
			(gethash (plist-get event :source-id)
				 (elpet-instance-sources instance))))
           (kind (and (listp event) (plist-get event :kind)))
           (sequence (and (listp event) (plist-get event :sequence)))
           (id (and (listp event) (plist-get event :event-id))))
      (cond
       ((null instance) '(:ok nil :reason inactive))
       ((or (null source)
            (not (eq (plist-get event :schema-version) 1))
            (not (equal (plist-get event :pet-id) (elpet-instance-id instance)))
            (not (and (stringp id) (> (length id) 0)))
            (not (and (integerp sequence) (>= sequence 0)))
            (not (memq kind (plist-get source :kinds)))
            (and (memq kind elpet--activity-phases)
		 (not (and (stringp (plist-get event :activity-id))
                           (> (length (plist-get event :activity-id)) 0))))
            (and (eq kind 'state) (not (memq (plist-get event :state) elpet--states)))
            (and (memq kind '(say state))
		 (let ((seconds (or (plist-get event :seconds) 10)))
                   (not (and (numberp seconds) (> seconds 0)))))
            (and (eq kind 'say)
		 (not (and (stringp (plist-get event :text))
                           (> (length (plist-get event :text)) 0)))))
	'(:ok nil :reason invalid))
       ((not (equal (plist-get event :source-epoch) (plist-get source :epoch)))
	'(:ok nil :reason stale-epoch))
       ((member id (plist-get source :seen)) '(:ok t :reason duplicate))
       ((<= sequence (plist-get source :sequence)) '(:ok nil :reason stale))
       (t
	(let* ((first (= (plist-get source :sequence) -1))
               (source-id (plist-get event :source-id))
               (now (elpet--now)))
          (setf (plist-get source :sequence) sequence
		(plist-get source :seen) (cons id (plist-get source :seen)))
          (when (> (length (plist-get source :seen)) 128)
            (setcdr (nthcdr 127 (plist-get source :seen)) nil))
          (cond
           ((eq kind 'say)
            (elpet-say (plist-get event :text)
                           (list :source source-id :priority (plist-get source :priority)
				 :seconds (or (plist-get event :seconds) 10)
				 :replace-key (plist-get event :replace-key)) instance))
           ((eq kind 'state)
            (elpet--request instance (plist-get event :state)
				(or (plist-get event :seconds) 10) nil source-id))
           (t
            (let* ((key (cons source-id (plist-get event :activity-id)))
                   (old (gethash key (elpet-instance-activities instance))))
              ;; Terminal activities cannot restart within an epoch.
              (unless (or (member (plist-get event :activity-id) (plist-get source :closed))
                          (and old (memq (plist-get old :phase) '(finished failed cancelled))))
		(when (memq kind '(finished failed cancelled))
                  (setf (plist-get source :closed)
			(seq-take (cons (plist-get event :activity-id) (plist-get source :closed)) 128)))
		(puthash key
			 (list :source source-id :activity-id (plist-get event :activity-id)
                               :phase kind :state (plist-get event :state) :time now
                               :expires (if (and first (plist-get event :baseline))
                                            now (+ now 10)))
			 (elpet-instance-activities instance))))))
          (elpet--publish instance (list :kind kind :source-id source-id :event-id id))
          '(:ok t :reason accepted)))))))

(provide 'elpet-events)
;;; elpet-events.el ends here
