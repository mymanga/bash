qm create 9013 --name ubuntu2604resolute --cores 2 --memory 2048 --net0 virtio,bridge=vmbr1,tag=20 --scsihw virtio-scsi-pci

qm set 9013 --scsi0 simplux_nbo1:0,import-from=/root/resolute-server-cloudimg-amd64.img

qm set 9013 --ide2 simplux_nbo1:cloudinit

qm set 9013 --boot order=scsi0

qm set 9013 --serial0 socket --vga serial0

qm template 9013
