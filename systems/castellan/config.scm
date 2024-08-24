(use-modules (gnu))
(use-service-modules networking ssh nfs)
(use-package-modules screen ssh)

(operating-system
 (host-name "castellan")
 (timezone "America/Chicago")
 (locale "en_US.utf8")

 (bootloader (bootloader-configuration
              (bootloader grub-bootloader)
              (targets '("/dev/disk/by-id/scsi-SNVMe_KINGSTON_SFYRSK50000_0000_0000_0000_0026_B728_345F_CB85."))))

 (kernel-arguments (list "console=ttyS0,115200"))
 (file-systems (append
                (list (file-system
                       (device (file-system-label "root"))
                       (mount-point "/")
                       (type "ext4"))
                      (file-system
                       (device (file-system-label "data"))
                       (mount-point "/srv/data")
                       (type "ext4")))
                      %base-file-systems))

 (initrd-modules (append   (list "hv_storvsc" "hv_vmbus")
                           %base-initrd-modules))

 (groups
  (cons
   (user-group
    (name "sudo"))
   %base-groups))
 (users (cons (user-account
               (name "dragon")
               (uid 1000)
               (group "users")

               ;; Adding the account to the "wheel" group
               ;; makes it a sudoer.  Adding it to "audio"
               ;; and "video" allows the user to play sound
               ;; and access the webcam.
               (supplementary-groups '("wheel"  "sudo"  "audio" "video")))
              %base-user-accounts))

 ;; Globally-installed packages.
 (packages
  (append
   (map specification->package
        `("screen" "htop" "git" "curl" "unzip"))
   %base-packages))

 (services
  (cons*
   (service static-networking-service-type
            (list (static-networking
                   (addresses
                    (list (network-address
                           (device "eth0")
                           (value "192.168.1.101/20"))))
                   (routes
                    (list (network-route
                           (destination "default")
                           (gateway "192.168.0.1"))))
                   (name-servers '("192.168.0.1")))))
   ;   (service nftables-service-type)

   (service openssh-service-type
            (openssh-configuration
             (port-number 22)))

   (service nfs-service-type
            (nfs-configuration
             (nfs-versions (list "4.2" "4.1" "4.0" "3.0"))
             (exports
              '(("/srv/data 192.168.0.0/255.255.240.0(rw,no_root_squash,no_subtree_check)")))))


   %base-services))


 (sudoers-file
  (plain-file "sudoers"
              (string-append (plain-file-content %sudoers-specification)
                             (format #f "~a ALL=NOPASSWD: ALL~%" "%sudo"))))
 )
