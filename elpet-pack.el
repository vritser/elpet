;;; elpet-pack.el --- Character-pack installation -*- lexical-binding: t; -*-

;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Install a character pack that the user downloaded from the elpet releases
;; page.  The full pack is deliberately not tracked in git: this module only
;; touches a local archive or directory, and never downloads anything.

;;; Code:

(require 'tar-mode)
(require 'elpet)

(declare-function elpet--save-preferences "elpet" ())

(defconst elpet-pack--official-sha256
  "337babf472082d4b187fdb24876df0a6d1abcf67833dd76e54d5df11fdb60f25"
  "SHA-256 of the full character pack archive published with elpet.")

(defcustom elpet-pack-install-directory
  (locate-user-emacs-file "elpet/packs/")
  "Directory where installed character packs are unpacked."
  :type 'directory :group 'elpet)

(defun elpet-pack--sha256 (file)
  "Return the SHA-256 of FILE as a lowercase hex string."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (secure-hash 'sha256 (current-buffer))))

(defun elpet-pack--safe-entry-p (name)
  "Return non-nil when archive entry NAME stays inside the extraction root."
  (and (stringp name)
       (> (length name) 0)
       (not (file-name-absolute-p name))
       (not (string-match-p "\\`[~/]" name))
       (not (string-match-p "\\\\" name))
       (not (member ".." (split-string name "/")))))

(defun elpet-pack--extract (archive destination)
  "Validate and extract ARCHIVE into DESTINATION.
The caller is responsible for the checksum; this function refuses entries
that could escape DESTINATION."
  (make-directory destination t)
  (with-temp-buffer
    (condition-case err
        (insert-file-contents archive)
      (error (user-error "Cannot read pack archive: %s"
                         (error-message-string err))))
    (tar-mode)
    (dolist (entry tar-parse-info)
      (let ((name (tar-header-name entry)))
        (unless (elpet-pack--safe-entry-p name)
          (user-error "Unsafe path in pack archive: %s" name))))
    (let ((default-directory (file-name-as-directory destination)))
      (tar-untar-buffer))))

(defun elpet-pack--manifest (directory)
  "Return the single pack.json below DIRECTORY."
  (let ((files (directory-files-recursively directory "\\`pack\\.json\\'")))
    (cond ((null files) (user-error "No pack.json in the installed files"))
          ((cdr files) (user-error "Multiple pack.json files in the installed files"))
          (t (car files)))))

(defun elpet-pack--copy-contents (root target)
  "Copy the contents of pack ROOT into TARGET."
  (make-directory target t)
  (copy-directory (file-name-as-directory root) target nil t t))

;;;###autoload
(defun elpet-install-pack (source)
  "Install the character pack at SOURCE and return its manifest path.
SOURCE is a pack directory or a .tar.gz archive downloaded from the elpet
releases page.  The official full pack checksum is verified; a different
archive requires confirmation.  The command extracts into
`elpet-pack-install-directory', points `elpet-pack-file' at the installed
manifest, and restarts `elpet-mode' when it is active."
  (interactive "fCharacter pack archive or directory: ")
  (let* ((source (expand-file-name source))
         (archive (not (file-directory-p source))))
    (unless (file-exists-p source)
      (user-error "Character pack not found: %s" source))
    (when (and archive
               (file-regular-p source)
               (not (equal (elpet-pack--sha256 source)
                           elpet-pack--official-sha256))
               (not (yes-or-no-p
                     "Archive checksum differs from the official full pack; install anyway? ")))
      (user-error "Character pack installation cancelled"))
    (let ((temporary (and archive (make-temp-file "elpet-pack-extract-" t))))
      (unwind-protect
          (let* ((root (if archive
                           (progn
                             (elpet-pack--extract source temporary)
                             temporary)
                         source))
                 (manifest (elpet-pack--manifest root))
                 (pack (elpet-load-pack manifest))
                 (id (elpet-pack-id pack))
                 (target (expand-file-name id elpet-pack-install-directory))
                 (installed-manifest (expand-file-name "pack.json" target))
                 (active (and (boundp 'elpet-mode) elpet-mode)))
            (unless (string-match-p "\\`[a-zA-Z0-9_-]+\\'" id)
              (user-error "Invalid pack id: %s" id))
            (when (file-in-directory-p (file-name-directory manifest) target)
              (user-error "Pack is already installed at %s" target))
            (when (file-exists-p target)
              (unless (yes-or-no-p (format "Replace installed pack %s? " target))
                (user-error "Character pack installation cancelled"))
              (delete-directory target t))
            (elpet-pack--copy-contents (file-name-directory manifest) target)
            (when active (elpet-mode -1))
            (setq elpet-pack-file installed-manifest)
            (when active
              (elpet-mode 1)
              (elpet--save-preferences))
            (message "Installed %s; character pack is now %s" id installed-manifest)
            installed-manifest)
        (when (and temporary (file-exists-p temporary))
          (delete-directory temporary t))))))

(provide 'elpet-pack)
;;; elpet-pack.el ends here
