;;; arduino-cli.el --- arduino-cli command wrapper -*- lexical-binding: t -*-

;; Copyright © 2019

;; Author: Love Lagerkvist
;; URL: https://github.com/motform/arduino-cli-mode
;; Version: 0.2.0
;; Package-Requires: ((emacs "25"))
;; Created: 2019-11-16
;; Keywords: extensions processes arduino

;; This file is NOT part of GNU Emacs.

;;; License:

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; For a full copy of the GNU General Public License
;; see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; This package contains a wrapper for the official Arduino command line utility.
;; It aims to be as simple as possible, while still providing useful conveniences.
;;
;; The structure of this package was inspired by ZachMassia's PlatformIO-Mode:
;; https://github.com/ZachMassia/PlatformIO-Mode/
;; 
;; Most of the fns consist of hairy imperative let*s that check/get
;; something from the cli.  Mostly parsing json or getting things from
;; maps that are structured in semi-coherent ways.
;; 
;; For more information on the wrapper, see the readme at https://github.com/motform/emacs-arduino-cli
;; For more information on arduino-cli itself, see https://github.com/arduino/arduino-cli

;;; Code:

(require 'compile)
(require 'json)
(require 'map)
(require 'seq)
(require 'subr-x)

;;; Customization
(defgroup arduino-cli nil
  "Arduino-cli functions and settings."
  :group 'tools
  :prefix "arduino-cli-")

(defcustom arduino-cli-mode-keymap-prefix (kbd "C-c C-a")
  "Arduino-cli keymap prefix."
  :group 'arduino-cli
  :type 'string)

(defcustom arduino-cli-mode-verify nil
  "Verify uploaded binary after the upload."
  :group 'arduino-cli
  :type 'boolean)


;;; Internal functions
(define-compilation-mode arduino-cli-compilation-mode "arduino-cli-compilation"
  "Arduino-cli specific `compilation-mode' derivative."
  (setq-local compilation-scroll-output t)
  (require 'ansi-color))

(defun arduino-cli--compile (cmd)
  "Run arduino-cli CMD in 'arduino-cli-compilation-mode."
  (let ((cmd (concat "arduino-cli " cmd " " default-directory)))
    (save-some-buffers (not compilation-ask-about-save)
                       (lambda () default-directory))
    (compilation-start cmd 'arduino-cli-compilation-mode)))

(defun arduino-cli--message (cmd &rest path)
  "Run arduino-cli CMD in PATH (if provided) and print as message."
  (let* ((default-directory (if path (car path) default-directory))
         (cmd (concat "arduino-cli " cmd))
         (out (shell-command-to-string cmd)))
    (message out)))

(defun arduino-cli--arduino? (usb-device)
  "Return USB-DEVICE it is an Arduino, nil otherwise."
  (assoc 'boards usb-device))

(defun arduino-cli--selected-board? (board selected-board)
  "Return BOARD if it is the SELECTED-BOARD."
  (string= (cdr (assoc 'address board))
           selected-board))

(defun arduino-cli--cmd-json (cmd)
  "Get the result of CMD as JSON-style alist."
  (let* ((cmmd (concat "arduino-cli " cmd " --format json")))
    (thread-first cmmd shell-command-to-string json-read-from-string)))

;; NOTE This leaves 'boards in final map, causing
;; insignificant, but ugly, duplication
(defun arduino-cli--board ()
  "Get connected Arduino board."
  (let* ((usb-devices (arduino-cli--cmd-json "board list"))
         (boards (seq-filter #'arduino-cli--arduino? usb-devices))
         (boards-info (seq-map (lambda (m) (thread-first (assoc 'boards m) cdr (seq-elt 0))) boards))
         (informed-boards (mapcar* (lambda (m n) (map-merge 'list m n)) boards boards-info))
         (selected-board (arduino-cli--dispatch-board informed-boards)))
    (if selected-board selected-board
      (error "ERROR: No board connected"))))

;; TODO add support for compiling to known cores when no boards are connected
(defun arduino-cli--dispatch-board (boards)
  "Correctly dispatch on the amount of BOARDS connected."
  (pcase (length boards)
    (`1 (car boards))
    ((pred (< 1)) (arduino-cli--select-board boards))
    (_ (error "ERROR: No board connected"))))

(defun arduino-cli--board-name (board)
  "Get name of BOARD in (name @ port) format."
  (concat (cdr (assoc 'name board)) " @ " (cdr (assoc 'address board))))

(defun arduino-cli--select-board (boards)
  "Prompt user to select an Arduino from BOARDS."
  (let* ((board-names (mapcar* #'arduino-cli--board-name boards))
         (selection (thread-first board-names (arduino-cli--select "Board ") (split-string "@") cadr string-trim)))
    (car (seq-filter #'(lambda (m) (arduino-cli--selected-board? m selection)) boards))))

(defun arduino-cli--cores ()
  "Get installed Arduino cores."
  (let* ((cores (arduino-cli--cmd-json "core list"))
         (id-pairs (seq-map (lambda (m) (assoc 'ID m)) cores))
         (ids (seq-map #'cdr id-pairs)))
    (if ids ids
      (error "ERROR: No cores installed"))))

(defun arduino-cli--search-cores ()
  "Search from list of cores."
  (let* ((cores (arduino-cli--cmd-json "core search")) ; search without parameters gets all cores
         (id-pairs (seq-map (lambda (m) (assoc 'ID m)) cores))
         (ids (seq-map #'cdr id-pairs)))
    (arduino-cli--select ids "Core ")))

(defun arduino-cli--libs ()
  "Get installed Arduino libraries."
  (let* ((libs (arduino-cli--cmd-json "lib list"))
         (lib-names (seq-map (lambda (lib) (cdr (assoc 'name (assoc 'library lib)))) libs)))
    (if lib-names lib-names
      (error "ERROR: No libraries installed"))))

(defun arduino-cli--search-libs ()
  "Get installed Arduino libraries."
  (let* ((libs (cdr (assoc 'libraries (arduino-cli--cmd-json "lib search"))))
         (lib-names (seq-map (lambda (lib) (cdr (assoc 'name lib))) libs)))
    (if lib-names lib-names
      (error "ERROR: Unable to find libraries"))))

(defun arduino-cli--select (xs msg)
  "Select option from XS, prompted by MSG."
  (completing-read msg xs))


;;; User commands
(defun arduino-cli-compile ()
  "Compile Arduino project."
  (interactive)
  (let* ((board (arduino-cli--board))
         (fqbn (cdr (assoc 'FQBN board)))
         (cmd (concat "compile --fqbn " fqbn)))
    (arduino-cli--compile cmd)))

(defun arduino-cli-compile-and-upload ()
  "Compile and upload Arduino project."
  (interactive)
  (let* ((board (arduino-cli--board))
         (fqbn (cdr (assoc 'FQBN board)))
         (port (cdr (assoc 'address board)))
         (cmd (concat "compile --fqbn " fqbn " --port " port " --upload")))
    (arduino-cli--compile cmd)))

(defun arduino-cli-upload ()
  "Upload Arduino project."
  (interactive)
  (let* ((board (arduino-cli--board))
         (fqbn (cdr (assoc 'FQBN board)))
         (port (cdr (assoc 'address board)))
         (cmd (concat "upload --fqbn " fqbn " --port " port)))
    (arduino-cli--compile cmd)))

(defun arduino-cli-board-list ()
  "Show list of connected Arduino boards."
  (interactive)
  (arduino-cli--message "board list"))

(defun arduino-cli-core-list ()
  "Show list of installed Arduino cores."
  (interactive)
  (arduino-cli--message "core list"))

(defun arduino-cli-core-upgrade ()
  "Update-index and upgrade all installed Arduino cores."
  (interactive)
  (let* ((cores (arduino-cli--cores))
         (selection (arduino-cli--select cores "Core "))
         (cmd (concat "core upgrade " selection)))
    (shell-command-to-string "arduino-cli core update-index")
    (arduino-cli--message cmd)))

(defun arduino-cli-core-upgrade-all ()
  "Update-index and upgrade all installed Arduino cores."
  (interactive)
  (shell-command-to-string "arduino-cli core update-index")
  (arduino-cli--message "core upgrade"))

;; TODO change from compilation mode into other,non blocking mini-buffer display
(defun arduino-cli-core-install ()
  "Find and install Arduino cores."
  (interactive)
  (let* ((core (arduino-cli--search-cores))
         (cmd (concat "arduino-cli core install " core)))
    (shell-command-to-string "arduino-cli core update-index")
    (compilation-start cmd 'arduino-cli-compilation-mode)))

(defun arduino-cli-core-uninstall ()
  "Find and uninstall Arduino cores."
  (interactive)
  (let* ((cores (arduino-cli--cores))
         (selection (arduino-cli--select cores "Core "))
         (cmd (concat "core uninstall " selection)))
    (arduino-cli--message cmd)))

(defun arduino-cli-lib-list ()
  "Show list of installed Arduino libraries."
  (interactive)
  (arduino-cli--message "lib list"))

(defun arduino-cli-lib-upgrade ()
  "Upgrade Arduino libraries."
  (interactive)
  (shell-command-to-string "arduino-cli lib update-index")
  (arduino-cli--message "lib upgrade"))

;; TODO change from compilation mode into other,non blocking mini-buffer display
(defun arduino-cli-lib-install ()
  "Find and install Arduino libraries."
  (interactive)
  (let* ((libs (arduino-cli--search-libs))
         (selection (arduino-cli--select libs "Library "))
         (cmd (concat "arduino-cli lib install " (shell-quote-argument selection))))
    (shell-command-to-string "arduino-cli lib update-index")
    (compilation-start cmd 'arduino-cli-compilation-mode)))

(defun arduino-cli-lib-uninstall ()
  "Find and uninstall Arduino libraries."
  (interactive)
  (let* ((libs (arduino-cli--libs))
         (selection (arduino-cli--select libs "Library "))
         (cmd (concat "lib uninstall " (shell-quote-argument selection))))
    (arduino-cli--message cmd)))

(defun arduino-cli-new-sketch ()
  "Create a new Arduino sketch."
  (interactive)
  (let* ((name (read-string "Sketch name: "))
         (path (read-directory-name "Sketch path: "))
         (cmd (concat "sketch new " name)))
    (arduino-cli--message cmd path)))

;; TODO add y-n check for when there is already a config
(defun arduino-cli-config-init ()
  "Create a new Arduino config."
  (when (y-or-n-p "Init will override any existing config files, are you sure? ")
    (arduino-cli--message "config init")))

(defun arduino-cli-config-dump ()
  "Dump the current Arduino config."
  (arduino-cli--message "config dump"))


;;; Minor mode
(defvar arduino-cli-command-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "c") #'arduino-cli-compile)
    (define-key map (kbd "b") #'arduino-cli-compile-and-upload)
    (define-key map (kbd "u") #'arduino-cli-upload)
    (define-key map (kbd "n") #'arduino-cli-new-sketch)
    (define-key map (kbd "l") #'arduino-cli-board-list)
    (define-key map (kbd "i") #'arduino-cli-lib-install)
    (define-key map (kbd "u") #'arduino-cli-lib-uninstall)
    map)
  "Keymap for arduino-cli mode commands after `arduino-cli-mode-keymap-prefix'.")
(fset 'arduino-cli-command-map arduino-cli-command-map)

(defvar arduino-cli-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map arduino-cli-mode-keymap-prefix 'arduino-cli-command-map)
    map)
  "Keymap for arduino-cli mode.")

(easy-menu-change
 '("Tools") "arduino-cli"
 '("--"
   ["New sketch" arduino-cli-new-sketch]
   "--"
   ["Compile Project" arduino-cli-build]
   ["Upload Project" arduino-cli-compile-and-upload]
   ["Compile and Upload Project" arduino-cli-upload]
   "--"
   ["Board list" arduino-cli-board-list]
   ["Core list" arduino-cli-core-list]
   ["Core install" arduino-cli-core-install]
   ["Core uninstall" arduino-cli-core-uninstall]
   "--"
   ["Library list" arduino-cli-lib-list]
   ["Library install" arduino-cli-lib-install]
   ["Library uninstall" arduino-cli-lib-uninstall]
   "--"
   ["Core list" arduino-cli-core-list]
   ["Core install" arduino-cli-core-install]
   ["Core uninstall" arduino-cli-core-uninstall]
   ["Core upgrade" arduino-cli-core-upgrade]
   "--"
   ["Config init" arduino-cli-config-init]
   ["Config dump" arduino-cli-config-dump]))

;;;###autoload
(define-minor-mode arduino-cli-mode
  "arduino-cli integration for Emacs."
  :lighter " arduino-cli"
  :keymap arduino-cli-mode-map
  :group 'arduino-cli
  :require 'arduino-cli)

(provide 'arduino-cli-mode)
;;; arduino-cli.el ends here
