(defsystem "lem-sdl2"
  :depends-on ("sdl2"
               "sdl2-ttf"
               "sdl2-image"
               "lem"
               "lem/extensions"
               ;; Include the system when it's ready and tested:
               ;; "lem/legit"
               )
  :serial t
  :components ((:file "resource")
               (:file "platform")
               (:file "keyboard")
               (:file "font")
               (:file "icon")
               (:file "main")
               (:file "image-buffer")
               (:file "tree")))
