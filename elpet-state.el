;;; elpet-state.el --- State and message arbitration -*- lexical-binding: t; -*-

;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Resolve facts without touching a window, timer, or process.

;;; Code:
(require 'elpet-model)
(require 'seq)

(defconst elpet--states '(idle sleeping thinking working waiting success error happy))
(defconst elpet--activity-phases '(started updated waiting finished failed cancelled))
(defconst elpet--source-kinds '(started updated waiting finished failed cancelled say state))
(defvar elpet-history-limit 100)

(defun elpet--remember (pet message)
  "Append MESSAGE to PET's bounded history."
  (push (elpet--copy-data message) (elpet-instance-history pet))
  (when (> (length (elpet-instance-history pet)) elpet-history-limit)
    (setcdr (nthcdr (1- elpet-history-limit)
                    (elpet-instance-history pet)) nil)))

(defun elpet--transition (pet request status)
  "Move a live REQUEST in PET to STATUS and publish its receipt once."
  (when (and (memq (plist-get request :status) '(accepted playing))
             (not (eq status (plist-get request :status))))
    (setf (plist-get request :status) status)
    (elpet--publish pet (list :kind 'playback :id (plist-get request :id) :status status))
    t))

(defun elpet--expire (pet now)
  "Expire temporary messages and requests in PET at NOW."
  (setf (elpet-instance-messages pet)
        (cl-remove-if (lambda (m) (<= (plist-get m :expires) now))
                      (elpet-instance-messages pet)))
  (let (expired)
    (maphash
     (lambda (id request)
       (when (and (memq (plist-get request :status) '(accepted playing))
                  (<= (plist-get request :expires) now))
         (elpet--transition
          pet request (if (eq (plist-get request :status) 'playing) 'finished 'cancelled)))
       (when (<= (+ (plist-get request :expires) 60) now) (push id expired)))
     (elpet-instance-requests pet))
    (dolist (id expired) (remhash id (elpet-instance-requests pet))))
  (let (expired)
    (maphash (lambda (key activity)
               (when (and (memq (plist-get activity :phase) '(finished failed cancelled))
                          (<= (plist-get activity :expires) now))
                 (push key expired)))
             (elpet-instance-activities pet))
    (dolist (key expired) (remhash key (elpet-instance-activities pet)))))

(defun elpet--best-request (pet)
  "Return PET's highest priority live playback request."
  (let (best)
    (maphash (lambda (_ request)
               (when (and (memq (plist-get request :status) '(accepted playing))
                          (or (null best)
                              (> (plist-get request :priority) (plist-get best :priority))
                              (and (= (plist-get request :priority) (plist-get best :priority))
                                   (> (plist-get request :serial) (plist-get best :serial)))))
                 (setq best request)))
             (elpet-instance-requests pet))
    best))

(defun elpet--best-message (pet now)
  "Return PET's highest priority unexpired message at NOW."
  (let (best)
    (dolist (message (elpet-instance-messages pet) best)
      (when (and (> (plist-get message :expires) now)
                 (or (null best)
                     (> (plist-get message :priority)
                        (plist-get best :priority))))
        (setq best message)))))

(defun elpet--reduce (pet now idle sleep-delay)
  "Return PET's display state at NOW with IDLE seconds and SLEEP-DELAY."
  (elpet--expire pet now)
  (let (manual waiting failed working thinking result)
    (setq manual (elpet--best-request pet))
    (maphash
     (lambda (_ activity)
       (pcase (plist-get activity :phase)
         ('waiting (setq waiting t))
         ((or 'started 'updated)
          (if (eq (plist-get activity :state) 'thinking)
              (setq thinking t) (setq working t)))
         ('failed (when (> (plist-get activity :expires) now) (setq failed t)))
         ('finished (when (> (plist-get activity :expires) now) (setq result t)))))
     (elpet-instance-activities pet))
    (cond ((and manual (>= (plist-get manual :priority) 80)) (plist-get manual :state))
          (waiting 'waiting) (failed 'error)
          (manual (plist-get manual :state)) (working 'working)
          (thinking 'thinking) (result 'success)
          ((>= idle sleep-delay) 'sleeping) (t 'idle))))

(defun elpet-say (text &optional options pet)
  "Submit TEXT to PET with OPTIONS and return its message ID.
OPTIONS accepts :source (registered ID), :priority (0..source limit),
:seconds (positive lifetime, default 10), :replace-key, :action (a command),
:format (nil for plain text, or markdown for styled bubble text),
and :history (nil to omit transient previews, defaults to t).
Long messages remain complete in history, independent of the bubble preview."
  (when-let* ((instance (elpet--resolve pet)))
    (let* ((source (or (plist-get options :source) "local"))
           (registration (gethash source (elpet-instance-sources instance)))
           (priority (or (plist-get options :priority) 20))
           (seconds (or (plist-get options :seconds) 10))
           (key (plist-get options :replace-key))
           (action (plist-get options :action))
           (format (plist-get options :format)))
      (unless (and (stringp text) (> (length text) 0)
                   (numberp seconds) (> seconds 0)
                   (numberp priority) (<= 0 priority 100)
                   (memq format '(nil markdown))
                   (or (null action) (and (symbolp action) (commandp action)))
                   (or (equal source "local")
                       (and registration (memq 'say (plist-get registration :kinds))
                            (<= priority (plist-get registration :priority)))))
        (user-error "Invalid pet message or source permissions"))
      (let ((message (list :id (elpet--new-id instance "message")
                           :source source :text (substring-no-properties text)
                           :priority priority :replace-key key :action action :format format
                           :time (elpet--now)
                           :expires (+ (elpet--now) seconds))))
        (setf (elpet-instance-messages instance)
              (seq-take (cons message
			      (cl-remove-if
			       (lambda (old)
				 (and key (equal source (plist-get old :source))
				      (equal key (plist-get old :replace-key))))
			       (elpet-instance-messages instance))) elpet-history-limit))
        (unless (and (plist-member options :history) (null (plist-get options :history)))
          (elpet--remember instance message))
        (elpet--publish instance (list :kind 'message :id (plist-get message :id)))
        (plist-get message :id)))))

(defun elpet--request (pet state seconds &optional animation source)
  "Request STATE in PET for SECONDS, optionally ANIMATION and SOURCE."
  (unless (and (memq state elpet--states) (numberp seconds) (> seconds 0))
    (user-error "Invalid pet state or duration"))
  (let* ((id (elpet--new-id pet "play"))
         (request (list :id id :source (or source "manual") :state state
                        :animation animation :status 'accepted
                        :priority (if (null source) 80
                                    (or (plist-get (gethash source (elpet-instance-sources pet))
                                                   :priority) 40))
                        :serial (elpet-instance-serial pet)
                        :expires (+ (elpet--now) seconds))))
    ;; Manual actions supersede earlier requests from the same source.
    (maphash (lambda (_ old)
               (when (and (equal (plist-get old :source) (plist-get request :source))
                          (memq (plist-get old :status) '(accepted playing)))
                 (elpet--transition pet old 'cancelled)))
             (elpet-instance-requests pet))
    (puthash id request (elpet-instance-requests pet))
    (elpet--publish pet (list :kind 'playback :id id :status 'accepted))
    id))

(defun elpet-cancel (id &optional pet)
  "Cancel message or playback ID in PET.  Repeated cancellation is harmless."
  (when-let* ((instance (elpet--resolve pet)))
    (let* ((request (gethash id (elpet-instance-requests instance)))
           (messages (elpet-instance-messages instance))
           (remaining (cl-remove id messages :key (lambda (m) (plist-get m :id)) :test #'equal)))
      (when request (elpet--transition instance request 'cancelled))
      (when (< (length remaining) (length messages))
        (setf (elpet-instance-messages instance) remaining)
        (elpet--publish instance (list :kind 'cancelled :id id)))
      t)))

(defun elpet-snapshot (&optional pet)
  "Return a detached snapshot of PET, without mutable internal tables."
  (when-let* ((instance (elpet--resolve pet)))
    (let ((now (elpet--now)) activities requests)
      (elpet--expire instance now)
      (maphash (lambda (_ a) (push (elpet--copy-data a) activities))
               (elpet-instance-activities instance))
      (maphash (lambda (_ r) (push (elpet--copy-data r) requests))
               (elpet-instance-requests instance))
      (list :id (copy-sequence (elpet-instance-id instance))
            :generation (elpet-instance-generation instance)
            :revision (elpet-instance-revision instance)
            :state (elpet--reduce instance now 0 most-positive-fixnum)
            :activities activities :playback requests
            :messages (elpet--copy-data (elpet-instance-messages instance))
            :history (elpet--copy-data (elpet-instance-history instance))))))

(provide 'elpet-state)
;;; elpet-state.el ends here
