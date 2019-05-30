#!/bin/bash
MPIVERSION="3.2.1"

sudo apt update
sudo apt install make g++ gfortran nfs-kernel-server -y

wget http://www.mpich.org/static/downloads/$MPIVERSION/mpich-$MPIVERSION.tar.gz

tar -xzf mpich-$MPIVERSION.tar.gz

cd mpich-$MPIVERSION && ./configure && make && make install
cd ..
rm -r mpich-$MPIVERSION
rm mpich-$MPIVERSION.tar.gz

echo 
echo 
echo
