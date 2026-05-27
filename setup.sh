#!/bin/bash

# Install the application
sudo apt-get update
sudo apt-get upgrade -y
chmod +x install.sh
sed -i -e 's/\r$//' install.sh
./install.sh
