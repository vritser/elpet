;;; elpet-gptel-test.el --- Real gptel API contract -*- lexical-binding: t; -*-

;; Add gptel and its dependencies to load-path before loading this file.
;; The real request builder and abort API run; network transports are replaced.
(require 'gptel)
(require 'gptel-openai)
(load (expand-file-name "elpet-test.el"
                        (file-name-directory (or load-file-name buffer-file-name))) nil t)

(ert-deftest elpet-gptel-real-builder-and-scoped-abort ()
  (elpet-test--with-pet
   (let* ((elpet--default-instance pet)
          (elpet-chat--buffer nil) (elpet-chat--buffers nil)
          (gptel-backend (gptel-make-openai
                          "Pet contract test" :host "invalid.test"
                          :endpoint "/v1/chat/completions" :models '(pet-test)
                          :stream t :key "test-placeholder"))
          (gptel-model 'pet-test) (gptel-use-curl t)
          (gptel--request-alist nil)
          (ordinary (generate-new-buffer " *ordinary gptel test*"))
          requests aborted ordinary-aborted)
     (save-window-excursion
       (let ((transport
              (lambda (fsm)
                (push fsm requests)
                (push (cons (gensym "request")
                            (cons fsm (lambda ()
                                        (push (plist-get (gptel-fsm-info fsm) :buffer)
                                              aborted))))
                      gptel--request-alist))))
         (cl-letf (((symbol-function 'gptel-curl-get-response) transport)
                   ((symbol-function 'gptel--url-get-response) transport))
           (unwind-protect
               (progn
                 (with-current-buffer ordinary
                   (gptel-request "Ordinary conversation" :buffer ordinary
                                  :callback (lambda (response _info)
                                              (when (eq response 'abort)
                                                (setq ordinary-aborted t)))))
                 (elpet-chat)
                 (elpet-chat-set-persona "A quiet owl")
                 (insert "Hello") (elpet-chat-send)
                 (let* ((first (car requests)) (info (gptel-fsm-info first))
                        (data (plist-get info :data)))
                   (should (equal (plist-get data :model) "pet-test"))
                   (should (equal (plist-get data :messages)
                                  [(:role "system" :content "A quiet owl")
                                   (:role "user" :content "Hello")]))
                   (should-not (plist-get data :tools))
                   (funcall (plist-get info :callback) "Hello back" info)
                   (when elpet-chat--active
                     (funcall (plist-get info :callback) t info)))
                 (insert "Again") (elpet-chat-send)
                 (let* ((second (car requests)) (info (gptel-fsm-info second)))
                   (should (equal (mapcar (lambda (m) (plist-get m :role))
                                          (append (plist-get (plist-get info :data) :messages) nil))
                                  '("system" "user" "assistant" "user")))
                   (elpet-chat-stop)
                   (should (equal aborted (list elpet-chat--buffer)))
                   (should-not ordinary-aborted)
                   (should (cl-find ordinary gptel--request-alist
                                    :key (lambda (entry)
                                           (plist-get (gptel-fsm-info (cadr entry)) :buffer))))
                   (funcall (plist-get info :callback) "Late response" info)
                   (should (equal elpet-chat--turns '("Hello" "Hello back")))
                   (should (equal (elpet-chat--draft) "Again"))))
             (when (buffer-live-p elpet-chat--buffer)
               (kill-buffer elpet-chat--buffer))
             (kill-buffer ordinary))))))))

;;; elpet-gptel-test.el ends here
