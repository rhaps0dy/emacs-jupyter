;;; jupyter-channels.el --- Jupyter channels -*- lexical-binding: t -*-

;; Copyright (C) 2018 Nathaniel Nicandro

;; Author: Nathaniel Nicandro <nathanielnicandro@gmail.com>
;; Created: 08 Jan 2018
;; Version: 0.0.1

;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation; either version 2, or (at
;; your option) any later version.

;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 59 Temple Place - Suite 330,
;; Boston, MA 02111-1307, USA.

;;; Commentary:

;;; Code:

(require 'jupyter-connection)
(require 'ring)

(defgroup jupyter-channels nil
  "Jupyter channels"
  :group 'jupyter)

;;; Basic channel types

(defclass jupyter-channel (jupyter-connection)
  ((type
    :type keyword
    :initarg :type
    :documentation "The type of this channel. Should be one of
 the keys in `jupyter-channel-socket-types'.")
   (endpoint
    :type string
    :initarg :endpoint
    :documentation "The endpoint this channel is connected to.
 Typical endpoints look like \"tcp://127.0.0.1:5555\"."))
  :abstract t)

(defclass jupyter-sync-channel (jupyter-channel)
  ((socket
    :type (or null zmq-socket)
    :initform nil
    :documentation "The socket used for communicating with the kernel.")))

(defclass jupyter-async-channel (jupyter-channel)
  ((ioloop
    :type (or null process)
    :initform nil
    :documentation "The process responsible for sending and
receiving messages on this channel.")
   (recv-queue
    :type ring
    :initform (make-ring 10))
   (status
    :type symbol
    :initform 'stopped)))

(cl-defgeneric jupyter-start-channel ((channel jupyter-channel) &key identity)
  "Start a Jupyter CHANNEL using IDENTITY as the routing ID.")

(cl-defmethod jupyter-start-channel ((channel jupyter-async-channel) &key identity)
  ;; TODO: In an IOLoop actually start the channel by sending it the endpoint
  ;; and identity. Currently the IOLoop is assumed to have this information.
  ;;
  ;; TODO: Define a mechanism to attach a callback for each type of command in
  ;; an IOLoop so that the IOLoop filter is not responsible for setting the
  ;; status slot of a channel. Look how python implements event loops.
  (unless (jupyter-channel-alive-p channel)
    (zmq-subprocess-send (oref channel ioloop)
      (list 'start-channel (oref channel type)))
    (with-timeout (0.5 (error "Channel not started in ioloop subprocess"))
      (while (not (jupyter-channel-alive-p channel))
        (accept-process-output (oref channel ioloop) 0.1 nil 0)))))

(cl-defmethod jupyter-start-channel ((channel jupyter-sync-channel) &key identity)
  (unless (jupyter-channel-alive-p channel)
    (let ((socket (jupyter-connect-channel
                   (oref channel type) (oref channel endpoint) identity)))
      (oset channel socket socket)
      (cl-case (oref channel type)
        (:iopub
         (zmq-socket-set socket zmq-SUBSCRIBE ""))))))

(cl-defgeneric jupyter-stop-channel ((channel jupyter-channel))
  "Stop a Jupyter CHANNEL.")

(cl-defmethod jupyter-stop-channel ((channel jupyter-sync-channel))
  (when (jupyter-channel-alive-p channel)
    (condition-case nil
        (zmq-close (oref channel socket))
      (zmq-ENOENT nil))
    (oset channel socket nil)))

(cl-defmethod jupyter-stop-channel ((channel jupyter-async-channel))
  (when (jupyter-channel-alive-p channel)
    (zmq-subprocess-send (oref channel ioloop)
      (list 'stop-channel (oref channel type)))))

(cl-defgeneric jupyter-get-message ((channel jupyter-channel) &rest _args)
  "Receive a message on CHANNEL.")

(cl-defmethod jupyter-get-message ((channel jupyter-sync-channel))
  "Block until a message is received on CHANNEL.
Return the received message."
  (cl-destructuring-bind (_idents . msg)
      (jupyter-recv channel)
    msg))

(cl-defmethod jupyter-get-message ((channel jupyter-async-channel) &optional timeout)
  "Get a message from CHANNEL's recv-queue.
If no message is available, return nil. Otherwise return the
oldest message in CHANNEL's recv-queue. If TIMEOUT is non-nil,
wait until TIMEOUT for a message."
  (let ((idents-msg (jupyter-recv channel timeout)))
    (when idents-msg
      (cl-destructuring-bind (_idents . msg)
          idents-msg
        msg))))

(cl-defmethod jupyter-send ((channel jupyter-async-channel) type message)
  (zmq-subprocess-send (oref channel ioloop)
    (list 'send (oref channel type) type message)))

(cl-defmethod jupyter-send ((channel jupyter-sync-channel) type message)
  (jupyter-send (oref channel session) (oref channel socket) type message))

(cl-defmethod jupyter-recv ((channel jupyter-sync-channel))
  (jupyter-recv (oref channel session) (oref channel socket)))

(cl-defmethod jupyter-recv ((channel jupyter-async-channel) &optional timeout)
  (let ((ring (oref channel recv-queue)))
    (when timeout
      (with-timeout (timeout
                     (error "Message not received on channel within timeout"))
        (while (ring-empty-p ring)
          (sleep-for 0.01))))
    (unless (ring-empty-p ring)
      (ring-remove ring))))

(cl-defgeneric jupyter-queue-message ((channel jupyter-async-channel) msg)
  "Queue MSG in CHANNEL's recv-queue.
MSG is a cons pair (IDENTS . MSG) which will be added to the
recv-queue slot of CHANNEL. To receive a message from the channel
call `jupyter-get-message'.")

(cl-defmethod jupyter-queue-message ((channel jupyter-async-channel) msg)
  "Queue MSG in CHANNEL's recv-queue."
  (let ((ring (oref channel recv-queue)))
    (ring-insert+extend ring msg 'grow)))

(cl-defgeneric jupyter-channel-alive-p ((channel jupyter-channel))
  "Determine if a CHANNEL is alive.")

(cl-defmethod jupyter-channel-alive-p ((channel jupyter-sync-channel))
  (not (null (oref channel socket))))

(cl-defmethod jupyter-channel-alive-p ((channel jupyter-async-channel))
  (and (oref channel ioloop) (not (eq (oref channel status) 'stopped))))

;;; Heartbeat channel

(defclass jupyter-hb-channel (jupyter-sync-channel)
  ((type
    :type keyword
    :initform :hb
    :documentation "The type of this channel is `:hb'.")
   (time-to-dead
    :type integer
    :initform 1
    :documentation "The time in seconds to wait for a response
 from the kernel until the connection is assumed to be dead. Note
 that this slot only takes effect when starting the channel.")
   (beating
    :type (or boolean symbol)
    :initform t
    :documentation "A flag variable indicating that the heartbeat
 channel is communicating with the kernel.")
   (paused
    :type boolean
    :initform t
    :documentation "A flag variable indicating that the heartbeat
 channel is paused and not communicating with the kernel. To
 pause the heartbeat channel use `jupyter-hb-pause', to unpause
 use `jupyter-hb-unpause'.")
   (timer
    :type (or null timer)
    :initform nil
    :documentation "The timer which sends/receives heartbeat
 messages to/from the kernel."))
  :documentation "A base class for heartbeat channels.")

(cl-defmethod jupyter-channel-alive-p ((channel jupyter-hb-channel))
  "Return non-nil if CHANNEL is alive."
  (and (oref channel timer) (memq (oref channel timer) timer-list)))

(cl-defmethod jupyter-hb-beating-p ((channel jupyter-hb-channel))
  "Return non-nil if the kernel associated with CHANNEL is still
connected."
  (unless (jupyter-channel-alive-p channel)
    (error "Heartbeat channel not alive"))
  (oref channel beating))

(cl-defmethod jupyter-hb-pause ((channel jupyter-hb-channel))
  "Pause checking for heartbeat events on CHANNEL."
  (unless (jupyter-channel-alive-p channel)
    (error "Heartbeat channel not alive"))
  (oset channel paused t))

(cl-defmethod jupyter-hb-unpause ((channel jupyter-hb-channel))
  "Unpause checking for heatbeat events on CHANNEL."
  (unless (jupyter-channel-alive-p channel)
    (error "Heartbeat channel not alive"))
  (oset channel paused nil))

(cl-defmethod jupyter-stop-channel ((channel jupyter-hb-channel))
  "Stop the heartbeat CHANNEL.
Stop the timer of the heartbeat channel."
  (when (jupyter-channel-alive-p channel)
    (cancel-timer (oref channel timer))
    (zmq-socket-set (oref channel socket) zmq-LINGER 0)
    (zmq-close (oref channel socket))
    (oset channel socket nil)
    (oset channel timer nil)))

(cl-defmethod jupyter-start-channel ((channel jupyter-hb-channel) &key identity)
  "Start a heartbeat CHANNEL.
IDENTITY has the same meaning as in `jupyter-connect-channel'. A
heartbeat channel is handled specially in that it is implemented
with a timer in the current Emacs session. Starting a heartbeat
channel, starts the timer."
  (unless (jupyter-channel-alive-p channel)
    (oset channel socket (jupyter-connect-channel
                          :hb (oref channel endpoint) identity))
    ;; TODO: Do something when the kernel is for sure dead, i.e. when a message
    ;; has not been received for a certain number of time-to-dead periods. For
    ;; example run a hook and pause the channel.
    (oset channel timer
          (run-with-timer
           0 (oref channel time-to-dead)
           (let ((sent nil))
             (lambda (channel)
               (let ((sock (oref channel socket)))
                 (when sent
                   (setq sent nil)
                   (if (condition-case nil
                           (zmq-recv sock zmq-NOBLOCK)
                         ((zmq-EINTR zmq-EAGAIN) nil))
                       (oset channel beating t)
                     (oset channel beating nil)
                     (zmq-socket-set sock zmq-LINGER 0)
                     (zmq-close sock)
                     (setq sock (jupyter-connect-channel
                                 :hb (oref channel endpoint) identity))
                     (oset channel socket sock)))
                 (unless (oref channel paused)
                   (zmq-send sock "ping")
                   (setq sent t)))))
           channel))))

(provide 'jupyter-channels)

;;; jupyter-channels.el ends here
